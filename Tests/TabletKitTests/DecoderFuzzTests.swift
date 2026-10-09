// SPDX-License-Identifier: MPL-2.0
//
// Feeds seeded random and truncated reports to every decoder, the descriptor
// parser, and the helpers built on it. Buffers are exactly the report's size,
// so a run under `swift test --sanitize=address` flags any read past a report;
// a plain run still catches arithmetic overflow and runaway allocation.
// Raise FUZZ_ITERS for a longer search.
import XCTest
@testable import TabletKit

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

/// Calls `body` with a report whose storage is exactly `bytes.count` long.
private func withExactReport(_ bytes: [UInt8], _ body: (HIDReport) -> Void) {
    let p = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
    defer { p.deallocate() }
    for (i, b) in bytes.enumerated() { p[i] = b }
    body(HIDReport(pointer: UnsafePointer(p), count: bytes.count))
}

private func randomReport(_ rng: inout SplitMix64, ids: [UInt8]) -> [UInt8] {
    let lengths = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16, 20, 32, 64, 192]
    let len = rng.int(4) == 0 ? rng.int(200) : lengths[rng.int(lengths.count)]
    var bytes = (0..<len).map { _ in rng.byte() }
    if len > 0, rng.int(5) != 0 { bytes[0] = ids[rng.int(ids.count)] }
    // Bias toward extreme values, which find overflow.
    for i in bytes.indices where rng.int(4) == 0 { bytes[i] = rng.int(2) == 0 ? 0xFF : 0x00 }
    return bytes
}

final class DecoderFuzzTests: XCTestCase {

    static let ids: [UInt8] = Array(0x00...0x20) + [0x80, 0x81, 0xC0, 0xF0, 0xFF]
    static let iterations = Int(ProcessInfo.processInfo.environment["FUZZ_ITERS"] ?? "300")!

    func testRegistryDecoders() {
        var rng = SplitMix64(state: 1)
        for spec in WacomDeviceRegistry.knownDevices {
            var decoder = spec.parser.makeDecoder()
            var state = DecoderState()
            for _ in 0..<Self.iterations {
                let bytes = randomReport(&rng, ids: Self.ids)
                withExactReport(bytes) { report in
                    _ = decoder.decode(report: report, spec: spec.digitizerSpec, state: &state, deviceFamily: spec.family)
                }
                if rng.int(50) == 0 {
                    _ = decoder.decodeSilence(spec: spec.digitizerSpec, state: &state, deviceFamily: spec.family)
                }
            }
        }
    }

    func testEveryParserAgainstEveryFamilyAndOddSpecs() {
        var rng = SplitMix64(state: 2)
        let parsers: [ReportParser] = [.graphire, .intuosV1, .intuosV2, .intuosV3, .dtus, .dtu, .bamboo,
                                       .intuos3, .cintiqV1, .xencelabs, .ucLogic, .expressKeyRemote, .pl]
        let specs = [
            DigitizerSpec(maxX: 0, maxY: 0, maxPressure: 0),
            DigitizerSpec(maxX: 1, maxY: 1, maxPressure: 1, buttonCount: 18, hasTilt: true, hasDualRings: true,
                          bezelButtonCount: 20, isPenDisplay: true, ringSlotCount: 0, hasFingerTouch: true,
                          maxTouchContacts: 16, tiltMaxDegrees: 0),
            DigitizerSpec(maxX: Int(Int32.max), maxY: Int(Int32.max), maxPressure: Int(Int32.max), buttonCount: 64,
                          hasTilt: true, ringSlotCount: 64, hasFingerTouch: true, maxTouchContacts: 64),
        ]
        for parser in parsers {
            for family in DeviceFamily.allCases {
                for spec in specs {
                    var decoder = parser.makeDecoder()
                    var state = DecoderState()
                    for _ in 0..<(Self.iterations / 8) {
                        withExactReport(randomReport(&rng, ids: Self.ids)) { report in
                            _ = decoder.decode(report: report, spec: spec, state: &state, deviceFamily: family)
                        }
                        if rng.int(50) == 0 {
                            _ = decoder.decodeSilence(spec: spec, state: &state, deviceFamily: family)
                        }
                    }
                }
            }
        }
    }

    func testTouchDecoders() {
        var rng = SplitMix64(state: 3)
        let spec = DigitizerSpec(maxX: 100, maxY: 100, maxPressure: 2047, hasFingerTouch: true, maxTouchContacts: 10)
        var a = Wacom24HDTDecoder(), b = Wacom27QHDTDecoder()
        var sa = DecoderState(), sb = DecoderState()
        for _ in 0..<(Self.iterations * 4) {
            withExactReport(randomReport(&rng, ids: Self.ids)) { report in
                _ = a.decode(report: report, spec: spec, state: &sa, deviceFamily: .cintiq)
                _ = b.decode(report: report, spec: spec, state: &sb, deviceFamily: .cintiq)
                var lx = 0, ly = 0
                _ = decodeBLEPenReport(report: report, spec: spec, lastX: &lx, lastY: &ly)
                _ = decodeBLEPadReport(report: report)
                _ = decodeWirelessReport(report: report)
            }
        }
    }

    func testDescriptorParserAndDerivedDecoders() {
        var rng = SplitMix64(state: 4)
        // Random item streams: tag bytes chosen from real short items so the
        // parser gets deep instead of failing on byte one. The 4-byte Report
        // Count mostly lands past the parser's size limit; wide but legal
        // counts and ranges are covered in HIDReportDescriptorParserTests.
        let prefixes: [UInt8] = [0x05, 0x09, 0x15, 0x16, 0x25, 0x26, 0x27, 0x35, 0x45, 0x55, 0x65, 0x75, 0x95,
                                 0x97, 0x81, 0x91, 0xB1, 0xA1, 0xC0, 0x85, 0x06, 0x0A, 0x19, 0x29, 0xA4, 0xB4,
                                 0x17]
        for _ in 0..<(Self.iterations * 10) {
            var desc: [UInt8] = []
            for _ in 0..<rng.int(60) {
                let prefix = rng.int(10) == 0 ? rng.byte() : prefixes[rng.int(prefixes.count)]
                desc.append(prefix)
                let size = [0, 1, 2, 4][Int(prefix & 3)]
                for _ in 0..<size { desc.append(rng.int(3) == 0 ? 0xFF : rng.byte()) }
            }
            guard let layout = try? HIDReportDescriptorParser.parse(desc) else { continue }
            for pen in GenericPenLayout.derive(from: layout) {
                let d = GenericPenDecoder(layout: pen)
                for _ in 0..<8 {
                    let bytes = randomReport(&rng, ids: Self.ids)
                    withExactReport(bytes) { _ = d.decode(report: $0) }
                    _ = d.decode(report: bytes)
                }
            }
            for touch in PrecisionTouchLayout.derive(from: layout) {
                let d = PrecisionTouchDecoder(layout: touch)
                for _ in 0..<8 {
                    let bytes = randomReport(&rng, ids: Self.ids)
                    withExactReport(bytes) { _ = d.decode(report: $0) }
                    _ = d.decode(report: bytes)
                }
            }
            _ = layout.modeSwitchFeatureReportID()
        }
    }

    func testUCLogicInfo() {
        var rng = SplitMix64(state: 5)
        for _ in 0..<(Self.iterations * 10) {
            let bytes = (0..<rng.int(40)).map { _ in rng.int(3) == 0 ? 0xFF : rng.byte() }
            _ = UCLogicTabletInfo(huionDescriptor200: bytes)?.digitizerSpec
            _ = UCLogicTabletInfo(ugeeDescriptor100: bytes)?.digitizerSpec
        }
    }
}
