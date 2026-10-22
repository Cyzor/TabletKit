// SPDX-License-Identifier: MPL-2.0
//
// Pins every decoder's event output to a committed golden file, so a change
// meant to leave decoding alone can show that it did. Each row gets seeded
// input: random reports, then mutation chains grown from the ones that
// decoded to something, then those reports again unchanged. Silence and
// resets are mixed in.
//
// UPDATE_GOLDENS=1 rewrites the golden. GOLDEN_EXPORT=<row key> (for example
// 0x00F4) writes that row's full event stream to a temp file; when a digest
// changes, export at both commits and diff the two.
import XCTest
import TabletKit

private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

private struct FNV1a64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    mutating func add(_ s: String) {
        for b in s.utf8 { hash = (hash ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
    }
}

private func withExactReport<R>(_ bytes: [UInt8], _ body: (HIDReport) -> R) -> R {
    let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(bytes.count, 1))
    defer { p.deallocate() }
    for (i, b) in bytes.enumerated() { p[i] = b }
    return body(HIDReport(pointer: UnsafePointer(p), count: bytes.count))
}

// MARK: - Rows

private struct GoldenRow {
    let key: String
    let name: String
    let templates: [[UInt8]]
    let decoder: () -> DeviceDecoder
}

private func hex(_ s: String) -> [UInt8] {
    s.split(separator: " ").map { UInt8($0, radix: 16)! }
}

private func padded(_ head: [UInt8], to count: Int) -> [UInt8] {
    head + [UInt8](repeating: 0, count: count - head.count)
}

/// Real report shapes, from the decoder unit tests and the conformance
/// fixtures, for formats random bytes seldom reach.
private let formatTemplates: [ReportFormat: [[UInt8]]] = [
    .graphire: [hex("02 80 34 12 78 56 00 00"), hex("02 80 00 00 00 00 FF 01")],
    .pl: [hex("02 40 2A 20 00 1F 58 00"), hex("02 40 2A 20 08 1F 58 C8")],
    .bamboo: [hex("02 E1 34 12 45 23 E8 03 00")],
    .intuosV2: [hex("1E 01 C1 DB FD 00 F4 8D 00 DB 01 0C 00 08 00 00 00 00 00 1F")],
    .intuosV3: [hex("1E 01 C1 B4 83 00 75 36 00 FF 1F 20 00 06 00 00 00 00 00 14 AA 87 C0 24 00 02 10 00 00 02 D4 18 18 3D")],
    .xencelabs: [
        hex("02 20 d5 05 a1 e3 00 00 11 21 00 00 47 38 43 35 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"),
        hex("02 21 41 04 fe e3 17 00 00 23 00 00 47 38 43 35 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"),
        padded([0x02, 0xF0, 0x10], to: 32),
        padded([0x02, 0xF0, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02], to: 32),
    ],
]

private func goldenRows() -> [GoldenRow] {
    var rows: [GoldenRow] = []
    var seen: [String: Int] = [:]
    func add(
        _ base: String, _ name: String, templates: [[UInt8]],
        _ make: @escaping () -> DeviceDecoder
    ) {
        seen[base, default: 0] += 1
        let key = seen[base]! == 1 ? base : "\(base).\(seen[base]!)"
        rows.append(GoldenRow(key: key, name: name, templates: templates, decoder: make))
    }
    for spec in WacomDeviceRegistry.knownDevices {
        add(String(format: "0x%04X", spec.productID), spec.name,
            templates: formatTemplates[spec.format] ?? []) { spec.makeDecoder() }
    }
    // Specs the app builds at connect rather than reading from the registry,
    // built the way it builds them.
    var built: [TabletSpec] = []
    for pid in [0x520D, 0x5202] {
        guard let p = VendorDeviceRegistry.drivableProfile(forVendorID: 0x28BD, productID: pid) else {
            continue
        }
        let auxOnly = p.maxX == nil
        built.append(TabletSpec(
            productID: pid, name: p.productName, format: .xencelabs,
            maxX: p.maxX ?? 0, maxY: p.maxY ?? 0, maxPressure: p.maxPressure ?? 8191,
            buttonCount: p.auxButtonCount ?? 0, bezelButtonCount: p.bezelButtonCount ?? 0,
            hasTouchRing: auxOnly, hasMechanicalDial: auxOnly, hasEraser: !auxOnly, hasTilt: !auxOnly,
            tiltMaxDegrees: auxOnly ? nil : ReportFormat.xencelabs.tiltMaxDegrees,
            isPenDisplay: p.isPenDisplay, seizeUSB: false))
    }
    let ucLogic = TabletSpec(
        productID: 0x006D, name: "UC-Logic tablet", format: .ucLogic,
        maxX: 50_800, maxY: 31_750, maxPressure: 8191, buttonCount: 8, hasTouchRing: false,
        hasEraser: false, hasTilt: true, seizeUSB: false)
    for spec in built + [ucLogic] {
        add("\(spec.format.rawValue)-0x\(String(format: "%04X", spec.productID))", spec.name,
            templates: formatTemplates[spec.format] ?? []) { spec.makeDecoder() }
    }
    // Fixed-layout touch sensors.
    let touch = DigitizerSpec(
        maxX: 100, maxY: 100, maxPressure: 2047, hasFingerTouch: true, maxTouchContacts: 10)
    // One contact: active, id 5, at (100, 200), then the frame count.
    var t24 = padded([0x01, 0x01, 0x05, 0x64, 0x00, 0, 0, 0xC8, 0x00, 0, 0, 0x0A, 0x00, 0x0C, 0x00], to: 62)
    t24[61] = 1
    add("touch-24HDT", "Cintiq 24HD touch", templates: [t24]) {
        DeviceDecoder(Wacom24HDTDecoder(), digitizer: touch, family: .cintiq)
    }
    return rows
}

// MARK: - Serialization

private func bits(_ flags: [Bool]) -> String {
    String(flags.map { $0 ? "1" : "0" })
}

private func fixed(_ d: Double) -> String { String(format: "%.4f", d) }

func goldenDescription(_ event: TabletEvent) -> (kind: String, text: String) {
    switch event {
    case .pen(let p):
        let buttons = bits([p.penButton1, p.penButton2, p.penButton3, p.penButton4, p.penButton5,
                            p.eraser, p.inProximity, p.mouseMiddleButton])
        let airbrush = p.airbrushWheel.map(String.init) ?? "-"
        return ("pen", "pen \(p.x) \(p.y) \(p.maxX) \(p.maxY) \(p.pressure)/\(p.maxPressure)"
            + " tilt \(fixed(p.tiltX)) \(fixed(p.tiltY)) rot \(fixed(p.rotation)) b \(buttons)"
            + " hover \(p.hoverDistance) wheel \(p.mouseWheelDelta) air \(airbrush)")
    case .tool(let t):
        let id = t.identity
        return ("tool", "tool \(t.phase == .enter ? "enter" : "leave") serial \(id.serial)"
            + " code \(id.toolCode) eraser \(id.isEraser) mouse \(id.isMouse)")
    case .pad(let pad):
        let rings = pad.rings.map { "\($0.position.map(String.init) ?? "-")/\($0.buttonDown ? 1 : 0)" }
        let strips = pad.strips.map { $0.position.map(String.init) ?? "-" }
        let pressed = pad.pressedThisReport.map(String.init).joined(separator: ",")
        return ("pad", "pad \(bits(pad.buttons)) pressed [\(pressed)]"
            + " rings [\(rings.joined(separator: " "))] strips [\(strips.joined(separator: " "))]"
            + " mode \(pad.hardwareMode.map(String.init) ?? "-")")
    case .dial(let index, let delta):
        return ("dial", "dial \(index) \(delta)")
    case .touch(let frame):
        let contacts = frame.contacts.map {
            "\($0.id):\($0.x),\($0.y),\($0.contactArea.map(String.init) ?? "-"),\($0.contactMinor.map(String.init) ?? "-")"
        }
        return ("touch", "touch t \(frame.deviceTime.map(String.init) ?? "-") [\(contacts.joined(separator: " "))]")
    case .device(let e):
        var text = "device \(e.kind.rawValue)"
        if let b = e.battery { text += " \(b.percent) \(b.charging)" }
        if let w = e.wireless { text += " \(w)" }
        if let slots = e.remotePairing {
            text += " [" + slots.map { "\($0.index):\($0.serial):\($0.connected)" }.joined(separator: " ") + "]"
        }
        if let note = e.unsupportedToolNote { text += " \(note)" }
        if let m = e.mouseButtons { text += " \(m)" }
        return ("device", text)
    }
}

private let kinds = ["pen", "tool", "pad", "dial", "touch", "device"]

private struct RowRun {
    var counts: [String: Int] = [:]
    var digest = FNV1a64()
    var inputs = 0
    var exported: [String]?

    /// `input` labels exported lines only; the digest covers the step and events.
    mutating func record(_ step: String, input: String = "", _ events: [TabletEvent]) {
        inputs += 1
        guard !events.isEmpty else { return }
        for event in events {
            let (kind, text) = goldenDescription(event)
            counts[kind, default: 0] += 1
            let line = "\(step) \(text)\n"
            digest.add(line)
            exported?.append(input.isEmpty ? line : "\(step) \(input) \(text)\n")
        }
    }

    func goldenLine(key: String, name: String) -> String {
        let tally = kinds.map { "\($0)=\(counts[$0, default: 0])" }.joined(separator: " ")
        return "\(key) inputs=\(inputs) \(tally) digest=\(String(format: "%016llx", digest.hash))  # \(name)"
    }
}

// MARK: - Input

private let reportIDs: [UInt8] = Array(0x00...0x20) + [0x80, 0x81, 0xC0, 0xF0, 0xFF]

private func randomReport(_ rng: inout SplitMix64) -> [UInt8] {
    let lengths = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16, 20, 32, 34, 64, 192]
    let len = rng.int(4) == 0 ? 1 + rng.int(199) : lengths[rng.int(lengths.count)]
    var bytes = (0..<len).map { _ in rng.byte() }
    if rng.int(5) != 0 { bytes[0] = reportIDs[rng.int(reportIDs.count)] }
    for i in bytes.indices where rng.int(4) == 0 { bytes[i] = rng.int(2) == 0 ? 0xFF : 0x00 }
    return bytes
}

/// Changes one to three bytes, mostly by small steps so coordinates and
/// rings move the way real input does. Keeps the report ID most of the time.
private func mutate(_ bytes: [UInt8], _ rng: inout SplitMix64) -> [UInt8] {
    var out = bytes
    for _ in 0..<(1 + rng.int(3)) {
        let i = out.count > 1 && rng.int(10) != 0 ? 1 + rng.int(out.count - 1) : rng.int(out.count)
        switch rng.int(4) {
        case 0: out[i] = rng.byte()
        case 1: out[i] ^= 1 << UInt8(rng.int(8))
        default: out[i] = out[i] &+ UInt8(truncatingIfNeeded: rng.int(9) - 4)
        }
    }
    return out
}

private func seed(for key: String) -> UInt64 {
    var h = FNV1a64()
    h.add(key)
    return h.hash
}

private func runRow(_ row: GoldenRow, export: Bool) -> RowRun {
    var rng = SplitMix64(state: seed(for: row.key))
    var decoder = row.decoder()
    var result = RowRun()
    if export { result.exported = [] }
    var step = 0
    func feed(_ bytes: [UInt8]) -> Bool {
        let events = withExactReport(bytes) { decoder.events($0) }
        let input = export ? bytes.map { String(format: "%02x", $0) }.joined() : ""
        result.record("\(step)", input: input, events)
        step += 1
        return !events.isEmpty
    }
    func maybeSilenceOrReset() {
        if rng.int(25) == 0 {
            result.record("\(step) silence", decoder.eventsForSilence())
            step += 1
        }
        if rng.int(150) == 0 { decoder.reset() }
    }

    // 1. Random reports; keep the ones that decoded as chain seeds, after
    // the row's templates.
    var seeds = row.templates
    for _ in 0..<500 {
        let bytes = randomReport(&rng)
        if feed(bytes), seeds.count < 16 + row.templates.count, !seeds.contains(bytes) { seeds.append(bytes) }
        maybeSilenceOrReset()
    }
    // 2. Mutation chains.
    var current: [UInt8] = []
    var chainLeft = 0
    for _ in 0..<500 {
        if chainLeft == 0 {
            current = seeds.isEmpty ? randomReport(&rng) : seeds[rng.int(seeds.count)]
            chainLeft = 5 + rng.int(36)
        }
        current = mutate(current, &rng)
        chainLeft -= 1
        _ = feed(current)
        maybeSilenceOrReset()
    }
    // 3. The seeds again, unchanged.
    for bytes in seeds { _ = feed(bytes) }
    return result
}

// MARK: - Test

final class DecoderGoldenTests: XCTestCase {

    private static var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Goldens/decoder-events.txt")
    }

    private static let header = """
        # Decoder output digests, one line per row. Regenerate with
        # UPDATE_GOLDENS=1 swift test --filter DecoderGoldenTests, and say in the
        # commit which rows changed and why.

        """

    func testDecoderOutputMatchesGolden() throws {
        let env = ProcessInfo.processInfo.environment
        let exportKey = env["GOLDEN_EXPORT"]
        var lines: [String] = []
        for row in goldenRows() {
            let result = runRow(row, export: row.key == exportKey)
            lines.append(result.goldenLine(key: row.key, name: row.name))
            if let exported = result.exported {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("golden-\(row.key).txt")
                try exported.joined().write(to: url, atomically: true, encoding: .utf8)
                print("GOLDEN_EXPORT wrote \(url.path)")
            }
        }
        let current = Self.header + lines.joined(separator: "\n") + "\n"

        if env["UPDATE_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(
                at: Self.goldenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try current.write(to: Self.goldenURL, atomically: true, encoding: .utf8)
            return
        }

        let stored = try String(contentsOf: Self.goldenURL, encoding: .utf8)
        guard stored != current else { return }
        func byKey(_ text: String) -> [String: String] {
            var map: [String: String] = [:]
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                map[String(line.prefix { $0 != " " })] = String(line)
            }
            return map
        }
        let old = byKey(stored), new = byKey(current)
        var report: [String] = []
        for key in Set(old.keys).union(new.keys).sorted() where old[key] != new[key] {
            report.append("- \(old[key] ?? "(none)")\n+ \(new[key] ?? "(none)")")
        }
        XCTFail("Decoder output changed for \(report.count) rows:\n" + report.joined(separator: "\n"))
    }
}
