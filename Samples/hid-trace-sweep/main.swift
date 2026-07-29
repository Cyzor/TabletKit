// SPDX-License-Identifier: MPL-2.0
//
// hid-trace-sweep — replays a JSON-exported real HID capture through TabletKit's
// decoders and reports which decode hypothesis actually fits the device.
//
// Input is NOT vendored: this tool reads a JSON file from stdin (or a path
// argument), produced by `tools/hid_trace_parser.py --export-json PID` from
// a trace file the caller has fetched separately. No device data ships with
// this repo or with TabletKit — the source trace archive carries no license.
//
// ---
//
// **Why this tests more than the assigned parser.** The first version of this
// tool replayed each trace through the registry's assigned decoder alone and
// reported "observed exceeds registered" as a falsification. That phrasing
// hides the question that actually matters — *which side is wrong* — and in the
// 2026-07-28 sweep it produced two misattributions in opposite directions:
//
//   • CTH-480/680, CTL-480/680 were recorded as a decoder bug. They were on the
//     wrong parser family entirely; the correct one hits maxX exactly.
//   • Cintiq 12WX/21UX were recorded as a registry error (maxPressure too low).
//     The registry was right; the decoder was applying an 11-bit pressure
//     formula to 10-bit hardware.
//
// So this version runs every plausible hypothesis and reports which one fits:
//
//   1. **Parser family** — replay through all families, not just the assigned
//      one. An exact max hit under a different family is a reassignment signal.
//   2. **Pressure depth** — check whether an over-range pressure halves into
//      range, and whether the low bit looks like a status flag rather than
//      data. That distinguishes a decoder normalization bug from a registry
//      error, which is exactly the call the old output got wrong.
//
// **This narrows candidates; it does not identify families on its own.** Related
// parsers share coordinate formulas and will tie on exact hits — cintiqV1 mirrors
// intuosV1's 10-byte layout, and graphire/dtu/bamboo all read LE16 at the same
// offsets. Treat a tie as "several families remain possible" and settle it with
// report IDs and lengths, which is what actually separated INTUOSHT from
// INTUOSHT2. A tie never triggers a reassignment recommendation below.
//
// **Exact max hits are the strongest signal this tool produces.** A trace whose
// decoded maximum lands precisely on the registry's declared maximum means a
// real stroke reached the true edge of the tablet — that is positive evidence,
// not merely absence of contradiction. An observed max that falls short proves
// nothing: the capture may never have reached the edge. An observed max that
// exceeds the declared one disproves *something*, and the hypotheses below are
// there to say what.
//
// To run:
//   python3 tools/hid_trace_parser.py some_trace.hid --export-json 0x00D4 \
//     | swift run --package-path TabletKit hid-trace-sweep

import Foundation
import TabletKit

struct TraceEvent: Decodable {
    let t: Double
    let interface: Int
    let bytes: [UInt8]
}

struct TraceFile: Decodable {
    let pid: Int
    let events: [TraceEvent]
}

// MARK: - Input

let inputData: Data
if CommandLine.arguments.count > 1 {
    inputData = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
} else {
    inputData = FileHandle.standardInput.readDataToEndOfFile()
}

let trace: TraceFile
do {
    trace = try JSONDecoder().decode(TraceFile.self, from: inputData)
} catch {
    fputs("error: couldn't parse input JSON: \(error)\n", stderr)
    exit(1)
}

guard let spec = WacomDeviceRegistry.spec(for: trace.pid) else {
    fputs("error: PID 0x\(String(trace.pid, radix: 16)) not found in WacomDeviceRegistry\n", stderr)
    exit(1)
}

// MARK: - Parser -> decoder dispatch (mirrors WacomKnownDevice.swift; keep in sync)

func makeDecoder(_ parser: ReportParser) -> TabletReportDecoder {
    switch parser {
    case .intuosV2:  return IntuosV2Decoder()
    case .intuosV3:  return IntuosV3Decoder()
    case .dtus:      return DTUSDecoder()
    case .dtu:       return DTUDecoder()
    case .intuos3:   return Intuos3Decoder()
    case .bamboo:    return BambooDecoder()
    case .cintiqV1:  return CintiqV1Decoder()
    case .graphire:  return GraphireDecoder()
    case .xencelabs: return XencelabsDecoder()
    case .intuosV1:  return IntuosV1Decoder()
    }
}

/// Families worth replaying. Xencelabs is excluded: it is the only non-Wacom
/// parser and its specs are synthesized at connect time rather than stored in
/// this registry, so replaying a Wacom trace through it is meaningless.
let candidateParsers: [ReportParser] = [
    .intuosV1, .intuosV2, .intuosV3, .intuos3, .bamboo, .cintiqV1, .graphire, .dtu, .dtus,
]

// MARK: - Replay

/// Everything one hypothesis produced over the whole trace.
struct Outcome {
    var parser: ReportParser
    var maxXBound = 0
    var maxYBound = 0
    var maxPressureBound = 0
    var penEvents = 0
    var maxX = Int.min
    var maxY = Int.min
    var maxPressure = Int.min
    var pressureEven = 0
    var pressureOdd = 0
    var decodedCounts: [String: Int] = [:]
    var reportIDsDecoded = Set<UInt8>()

    var exceedsX: Bool { penEvents > 0 && maxX > maxXBound }
    var exceedsY: Bool { penEvents > 0 && maxY > maxYBound }
    var exceedsPressure: Bool { penEvents > 0 && maxPressure > maxPressureBound }
    var falsified: Bool { exceedsX || exceedsY || exceedsPressure }

    /// Exact boundary hits — the positive-evidence signal.
    var exactX: Bool { penEvents > 0 && maxX == maxXBound && maxXBound > 0 }
    var exactY: Bool { penEvents > 0 && maxY == maxYBound && maxYBound > 0 }
    var exactPressure: Bool {
        penEvents > 0 && maxPressure == maxPressureBound && maxPressureBound > 0
    }
    var exactHits: Int { (exactX ? 1 : 0) + (exactY ? 1 : 0) + (exactPressure ? 1 : 0) }

    /// Fraction of nonzero pressures that are even. On hardware whose true depth
    /// is one bit narrower than the formula applied, the spurious low bit comes
    /// from a status flag and almost every value lands even.
    var evenPressureFraction: Double {
        let total = pressureEven + pressureOdd
        return total == 0 ? 0 : Double(pressureEven) / Double(total)
    }
}

var reportIDsSeen = Set<UInt8>()
let sortedEvents = trace.events.sorted(by: { $0.t < $1.t })

func replay(_ parser: ReportParser) -> Outcome {
    var out = Outcome(
        parser: parser, maxXBound: spec.maxX, maxYBound: spec.maxY,
        maxPressureBound: spec.maxPressure)
    var decoder = makeDecoder(parser)
    var state = DecoderState()
    let digiSpec = DigitizerSpec(
        maxX: spec.maxX, maxY: spec.maxY, maxPressure: spec.maxPressure,
        buttonCount: spec.buttonCount, hasTilt: spec.hasTilt,
        hasFingerTouch: spec.hasFingerTouch, maxTouchContacts: spec.maxTouchContacts)

    for event in sortedEvents {
        guard let firstByte = event.bytes.first else { continue }
        reportIDsSeen.insert(firstByte)

        let results = event.bytes.withUnsafeBufferPointer { buf -> [DecodeResult] in
            guard let base = buf.baseAddress else { return [] }
            return decoder.decode(
                report: base, length: buf.count, spec: digiSpec, state: &state,
                deviceFamily: spec.family)
        }
        if !results.isEmpty { out.reportIDsDecoded.insert(firstByte) }

        for result in results {
            switch result {
            case .pen(let pt):
                out.penEvents += 1
                out.maxX = max(out.maxX, pt.x)
                out.maxY = max(out.maxY, pt.y)
                out.maxPressure = max(out.maxPressure, pt.pressure)
                if pt.pressure > 0 {
                    if pt.pressure % 2 == 0 { out.pressureEven += 1 } else { out.pressureOdd += 1 }
                }
                out.decodedCounts["pen", default: 0] += 1
            case .toolEnter:   out.decodedCounts["toolEnter", default: 0] += 1
            case .aux:         out.decodedCounts["aux", default: 0] += 1
            case .touch:       out.decodedCounts["touch", default: 0] += 1
            case .wireless:    out.decodedCounts["wireless", default: 0] += 1
            case .battery:     out.decodedCounts["battery", default: 0] += 1
            case .mouseButton: out.decodedCounts["mouseButton", default: 0] += 1
            case .wheel:       out.decodedCounts["wheel", default: 0] += 1
            case .none:        out.decodedCounts["none", default: 0] += 1
            case .toolCompatibility(let msg):
                out.decodedCounts["toolCompatibility(\(msg))", default: 0] += 1
            }
        }
    }
    return out
}

let outcomes = candidateParsers.map(replay)
guard let assigned = outcomes.first(where: { $0.parser == spec.parser }) else {
    fputs("error: assigned parser \(spec.parser) missing from candidate list\n", stderr)
    exit(1)
}

// MARK: - Report

print("hid-trace-sweep — \(spec.name)  (PID 0x\(String(format: "%04X", trace.pid)))")
print("Registry: parser=\(spec.parser) maxX=\(spec.maxX) maxY=\(spec.maxY) "
    + "maxPressure=\(spec.maxPressure)  confidence: \(spec.confidence)")
print("Trace: \(trace.events.count) raw reports across all interfaces")
print(String(repeating: "-", count: 72))

print("Report IDs seen in trace:    \(reportIDsSeen.sorted().map { String(format: "0x%02X", $0) })")
print("Report IDs assigned parser used: "
    + "\(assigned.reportIDsDecoded.sorted().map { String(format: "0x%02X", $0) })")
let unused = reportIDsSeen.subtracting(assigned.reportIDsDecoded)
if !unused.isEmpty {
    print("Report IDs NEVER decoded:    \(unused.sorted().map { String(format: "0x%02X", $0) })  "
        + "(expected for aux/pad/vendor-status channels the pen decoder ignores)")
}
print("")
print("Assigned-parser event counts: \(assigned.decodedCounts)")
print("")

// ── Hypothesis 1: parser family ──────────────────────────────────────────────

print("PARSER HYPOTHESES  (\"exact\" = decoded max lands precisely on the registry max)")
print(String(repeating: "-", count: 72))

func describe(_ o: Outcome) -> String {
    guard o.penEvents > 0 else { return "no pen events" }
    var flags: [String] = []
    if o.exactX { flags.append("exact X") }
    if o.exactY { flags.append("exact Y") }
    if o.exactPressure { flags.append("exact P") }
    if o.exceedsX { flags.append("X over") }
    if o.exceedsY { flags.append("Y over") }
    if o.exceedsPressure { flags.append("P over") }
    let note = flags.isEmpty ? "within bounds" : flags.joined(separator: ", ")
    return "pen=\(o.penEvents)  max \(o.maxX)x\(o.maxY) p\(o.maxPressure)   \(note)"
}

let ranked = outcomes.sorted {
    if $0.exactHits != $1.exactHits { return $0.exactHits > $1.exactHits }
    if $0.falsified != $1.falsified { return !$0.falsified }
    return $0.penEvents > $1.penEvents
}
for o in ranked {
    let marker = o.parser == spec.parser ? "→" : " "
    let verdict: String
    if o.penEvents == 0 {
        verdict = "  ·"
    } else if o.falsified {
        verdict = "  ✗"
    } else if o.exactHits > 0 {
        verdict = "  ★"
    } else {
        verdict = "  ?"
    }
    print("\(marker)\(verdict) \(o.parser.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
        + " \(describe(o))")
}
print("")
print("→ = registry's assigned parser   ★ = exact max hit (positive evidence)")
print("✗ = decodes out of range          ? = in range but never reached an edge")
print("")
print("Note: related families share coordinate formulas and will tie on exact hits")
print("(cintiqV1 mirrors intuosV1's 10-byte layout; graphire/dtu/bamboo all read LE16")
print("at the same offsets). An exact hit narrows the candidates — it does not on its")
print("own identify the family. Confirm with report IDs and report lengths.")
print("")

// ── Verdict on the family assignment ─────────────────────────────────────────

let betterFits = outcomes.filter {
    $0.parser != spec.parser && !$0.falsified && $0.exactHits > assigned.exactHits
}
if assigned.penEvents == 0 {
    print("*** ASSIGNED PARSER DECODES NO PEN EVENTS.")
    print("*** Either this trace never exercises the pen, or the assignment is wrong.")
    if let best = betterFits.max(by: { $0.exactHits < $1.exactHits }) {
        print("*** \(best.parser) decodes \(best.penEvents) pen events with "
            + "\(best.exactHits) exact hit(s) — likely the right family.")
    }
} else if !betterFits.isEmpty {
    let best = betterFits.max(by: { $0.exactHits < $1.exactHits })!
    print("*** REASSIGNMENT CANDIDATE: \(best.parser) fits better than the assigned "
        + "\(spec.parser).")
    print("*** \(best.parser) → \(describe(best))")
    print("*** \(spec.parser) → \(describe(assigned))")
    print("*** An exact max hit under a different family is strong evidence the row is")
    print("*** on the wrong parser. Check report IDs and lengths before acting.")
} else if assigned.falsified {
    print("*** ASSIGNED PARSER DECODES OUT OF RANGE, and no other family fits better.")
    print("*** Either the registry bounds are wrong, or the bug is inside this decoder")
    print("*** rather than in the choice of decoder. See the pressure check below.")
} else if assigned.exactHits > 0 {
    print("CONFIRMED: assigned parser \(spec.parser) hits the registry maximum exactly "
        + "on \(assigned.exactHits) axis/axes.")
    print("A real stroke reached the true edge — positive evidence, not just absence of")
    print("contradiction.")
} else {
    print("INCONCLUSIVE: assigned parser decodes within bounds but never reached an edge.")
    print("This does NOT confirm the row.")
}
print("")

// ── Hypothesis 2: pressure depth ─────────────────────────────────────────────

if assigned.penEvents > 0 && spec.maxPressure > 0 {
    print("PRESSURE DEPTH")
    print(String(repeating: "-", count: 72))
    let evenPct = Int((assigned.evenPressureFraction * 100).rounded())
    print("Observed max \(assigned.maxPressure) vs registry \(spec.maxPressure);  "
        + "nonzero values \(evenPct)% even "
        + "(\(assigned.pressureEven) even / \(assigned.pressureOdd) odd)")

    if assigned.exceedsPressure {
        let halved = assigned.maxPressure >> 1
        if halved <= spec.maxPressure && assigned.evenPressureFraction > 0.9 {
            print("")
            print("*** DECODER pressure-depth bug, NOT a registry error.")
            print("*** Halving gives \(halved), inside the registry's \(spec.maxPressure), and "
                + "\(evenPct)% of values are even —")
            print("*** the low bit is a status flag, not data. Apply the >>1 normalization for")
            print("*** maxPressure <= 1023 rather than raising the registry value.")
        } else if halved <= spec.maxPressure {
            print("")
            print("*** AMBIGUOUS: halving would fit (\(halved) <= \(spec.maxPressure)), but only "
                + "\(evenPct)% of values are even,")
            print("*** so the low bit looks like real data. More likely the registry maximum is")
            print("*** genuinely too low. Needs a second source before changing either side.")
        } else {
            print("")
            print("*** REGISTRY maxPressure likely too low: even halved (\(halved)) the observed")
            print("*** value exceeds \(spec.maxPressure). Confirm the real depth before changing.")
        }
    } else if assigned.evenPressureFraction > 0.95 && (assigned.pressureEven + assigned.pressureOdd) > 50 {
        print("")
        print("*** NOTE: pressure is in range but \(evenPct)% of values are even. That is the")
        print("*** signature of a doubled value that happens to fit. Worth a look if this row's")
        print("*** effective sensitivity seems halved.")
    }
    print("")
}
