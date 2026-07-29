// SPDX-License-Identifier: MPL-2.0
//
// hid-trace-sweep — replays a JSON-exported real HID capture through
// TabletKit's actual registry-assigned decoder and reports anomalies.
//
// Input is NOT vendored: this tool reads a JSON file from stdin (or a path
// argument), produced by `tools/hid_trace_parser.py --export-json PID` from
// a trace file the caller has fetched separately. No device data ships with
// this repo or with TabletKit — the source trace archive carries no license.
//
// This is a falsifier, not a confirmer: classic Wacom HID descriptors are
// largely opaque (vendor-page, undefined usages), so we can't derive the
// "true" coordinate range from the descriptor alone. An observed max that
// EXCEEDS the registry's maxX/maxY/maxPressure disproves that row. An
// observed max that falls short proves nothing — the capture may simply
// never have reached the edge of the tablet.
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

print("hid-trace-sweep — \(spec.name)  (PID 0x\(String(format: "%04X", trace.pid)), parser: \(spec.parser))")
print("Registry: maxX=\(spec.maxX) maxY=\(spec.maxY) maxPressure=\(spec.maxPressure)  "
    + "confidence: \(spec.confidence)")
print("Trace: \(trace.events.count) raw reports across all interfaces")
print(String(repeating: "-", count: 64))

// MARK: - Parser -> decoder dispatch (mirrors WacomKnownDevice.swift; keep in sync)

var decoder: TabletReportDecoder
switch spec.parser {
case .intuosV2:  decoder = IntuosV2Decoder()
case .intuosV3:  decoder = IntuosV3Decoder()
case .dtus:      decoder = DTUSDecoder()
case .dtu:       decoder = DTUDecoder()
case .intuos3:   decoder = Intuos3Decoder()
case .bamboo:    decoder = BambooDecoder()
case .cintiqV1:  decoder = CintiqV1Decoder()
case .graphire:  decoder = GraphireDecoder()
case .xencelabs: decoder = XencelabsDecoder()
case .intuosV1:  decoder = IntuosV1Decoder()
}

let digiSpec = DigitizerSpec(
    maxX: spec.maxX, maxY: spec.maxY, maxPressure: spec.maxPressure,
    buttonCount: spec.buttonCount, hasTilt: spec.hasTilt,
    hasFingerTouch: spec.hasFingerTouch, maxTouchContacts: spec.maxTouchContacts)

var state = DecoderState()

// MARK: - Replay

var decodedCounts: [String: Int] = [:]
var observedMaxX = Int.min
var observedMaxY = Int.min
var observedMaxPressure = Int.min
var penEventCount = 0
var totalDecoded = 0
var reportIDsSeen = Set<UInt8>()
var reportIDsDecoded = Set<UInt8>()

for event in trace.events.sorted(by: { $0.t < $1.t }) {
    guard let firstByte = event.bytes.first else { continue }
    reportIDsSeen.insert(firstByte)

    let results = event.bytes.withUnsafeBufferPointer { buf -> [DecodeResult] in
        guard let base = buf.baseAddress else { return [] }
        return decoder.decode(
            report: base, length: buf.count, spec: digiSpec, state: &state,
            deviceFamily: spec.family)
    }

    if !results.isEmpty {
        reportIDsDecoded.insert(firstByte)
    }

    for result in results {
        totalDecoded += 1
        switch result {
        case .pen(let pt):
            penEventCount += 1
            observedMaxX = max(observedMaxX, pt.x)
            observedMaxY = max(observedMaxY, pt.y)
            observedMaxPressure = max(observedMaxPressure, pt.pressure)
            decodedCounts["pen", default: 0] += 1
        case .toolEnter:      decodedCounts["toolEnter", default: 0] += 1
        case .aux:            decodedCounts["aux", default: 0] += 1
        case .wireless:       decodedCounts["wireless", default: 0] += 1
        case .battery:        decodedCounts["battery", default: 0] += 1
        case .toolCompatibility(let msg):
            decodedCounts["toolCompatibility(\(msg))", default: 0] += 1
        case .mouseButton:    decodedCounts["mouseButton", default: 0] += 1
        case .wheel:          decodedCounts["wheel", default: 0] += 1
        case .none:           decodedCounts["none", default: 0] += 1
        default:              decodedCounts["other", default: 0] += 1
        }
    }
}

// MARK: - Report

print("Report IDs seen in trace:    \(reportIDsSeen.sorted().map { String(format: "0x%02X", $0) })")
print("Report IDs the decoder used: \(reportIDsDecoded.sorted().map { String(format: "0x%02X", $0) })")
let unused = reportIDsSeen.subtracting(reportIDsDecoded)
if !unused.isEmpty {
    print("Report IDs NEVER decoded:    \(unused.sorted().map { String(format: "0x%02X", $0) })  "
        + "(expected for aux/pad/vendor-status channels the pen decoder ignores)")
}
print("")
print("Decoded event counts: \(decodedCounts)")
print("")

if penEventCount == 0 {
    print("*** NO .pen EVENTS DECODED. Either this trace never exercises the pen, or")
    print("*** the registry's parser assignment is wrong for this PID. Needs manual look.")
} else {
    print("Observed max X:        \(observedMaxX)  (registry maxX: \(spec.maxX))")
    print("Observed max Y:        \(observedMaxY)  (registry maxY: \(spec.maxY))")
    print("Observed max pressure: \(observedMaxPressure)  (registry maxPressure: \(spec.maxPressure))")
    print("")

    var falsified = false
    if observedMaxX > spec.maxX {
        print("FALSIFIED: observed X (\(observedMaxX)) exceeds registry maxX (\(spec.maxX))")
        falsified = true
    }
    if observedMaxY > spec.maxY {
        print("FALSIFIED: observed Y (\(observedMaxY)) exceeds registry maxY (\(spec.maxY))")
        falsified = true
    }
    if observedMaxPressure > spec.maxPressure {
        print("FALSIFIED: observed pressure (\(observedMaxPressure)) exceeds registry maxPressure (\(spec.maxPressure))")
        falsified = true
    }
    if !falsified {
        print("No falsification: observed ranges are within registry bounds.")
        print("(This does NOT confirm the row — the capture may simply never have")
        print(" reached the true edge of the tablet or full pressure.)")
    }
}
