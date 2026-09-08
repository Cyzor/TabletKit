// SPDX-License-Identifier: MPL-2.0
//
// A conformance harness: a data-driven proof that a device's declared
// (parser, DigitizerSpec) combination actually decodes its own capture log
// into structured events, using nothing but the public decode loop — no
// decoder-internals knowledge required.
//
// This is the mechanism the API design notes ask for: publish the fixture
// format so a contributor with hardware can prove a device works by adding
// one entry below, pasting a capture log body (the same format
// `CaptureLogParser` reads — see its own doc comment for the exact shape)
// and the registry fields the device would carry. No new Swift test code,
// no touching any decoder file.
//
// What "proves a device works" means here, deliberately kept minimal: the
// whole log replays through the named decoder without throwing, and at
// least one frame produces a result that isn't `.none`/empty. That's a low
// bar on purpose — it catches "wrong parser assigned" and "garbage
// coordinates" (the exact class of bug the 2026-07-29 IntuosV1→bamboo
// reassignments were), not full field-by-field correctness. A contributor
// who wants to assert specific decoded values still writes a normal XCTest,
// the way BambooDecoderTests does — this harness is the floor, not a
// replacement for targeted tests.
import XCTest
@testable import TabletKit

struct ConformanceFixture {
    /// Free-text device identification, shown in failure messages.
    let device: String
    /// Matches a `ReportParser` case name exactly (it's a `String` raw-value
    /// enum) — e.g. "bamboo", "intuosV2".
    let parser: String
    let spec: DigitizerSpec
    /// Device family passed to `decode(deviceFamily:)`.
    let deviceFamily: DeviceFamily
    /// Capture log body, in `CaptureLogParser`'s format. No header line
    /// needed — parsed with `requireHeader: false`.
    let captureLog: String
}

enum ConformanceDecoderFactory {
    /// Every `TabletReportDecoder` reachable through the `ReportParser`
    /// enum. Deliberately excludes `GenericPenDecoder`/`PrecisionTouchDecoder`
    /// — those are descriptor-driven, selected independently of this enum,
    /// and don't fit this harness's (parser name) → decoder mapping.
    static func make(for parser: String) -> (any TabletReportDecoder)? {
        switch parser {
        case "graphire": return GraphireDecoder()
        case "intuosV1": return IntuosV1Decoder()
        case "intuosV2": return IntuosV2Decoder()
        case "intuosV3": return IntuosV3Decoder()
        case "dtus": return DTUSDecoder()
        case "dtu": return DTUDecoder()
        case "bamboo": return BambooDecoder()
        case "intuos3": return Intuos3Decoder()
        case "cintiqV1": return CintiqV1Decoder()
        case "xencelabs": return XencelabsDecoder()
        default: return nil
        }
    }
}

final class ConformanceHarnessTests: XCTestCase {

    /// Add one entry per device a contributor wants to prove decodes
    /// correctly. See the type doc comments above for the bar this checks.
    static let fixtures: [ConformanceFixture] = [
        ConformanceFixture(
            device: "Wacom Bamboo Pen (CTL-460, 0x00D4) — BAMBOO_PT 9-byte pen",
            parser: "bamboo",
            spec: DigitizerSpec(
                maxX: 14720, maxY: 9200, maxPressure: 1023,
                buttonCount: 0, hasTilt: false),
            deviceFamily: .bamboo,
            captureLog: """
            [00:00.000] CTL-460             ID=02 len=9    02 21 34 12 45 23 E8 03 00
            """),
        ConformanceFixture(
            device: "Intuos Pro L gen 3 (PTK-870, 0x03F9) — real capture, whot/wacom-recordings",
            parser: "intuosV3",
            spec: DigitizerSpec(
                maxX: 69800, maxY: 39000, maxPressure: 8191,
                buttonCount: 8, hasTilt: true, hasDualRings: true,
                ringSlotCount: 4, tiltMaxDegrees: 64.0),
            deviceFamily: .intuosProGen3,
            captureLog: """
            [00:00.000] PTK-870             ID=1E len=34   1E 01 C1 B4 83 00 75 36 00 FF 1F 20 00 06 00 00 00 00 00 14 AA 87 C0 24 00 02 10 00 00 02 D4 18 18 3D
            """),
        ConformanceFixture(
            device: "Movink 13 (DTH-135, 0x03F0) — real capture, OpenTabletDriver PR #3679",
            parser: "intuosV3",
            spec: DigitizerSpec(
                maxX: 59552, maxY: 33848, maxPressure: 8191,
                buttonCount: 3, hasTilt: true, tiltMaxDegrees: 64.0),
            deviceFamily: .intuosProGen3,
            captureLog: """
            [00:00.000] DTH-135             ID=1E len=34   1E 01 C2 FD 75 00 27 42 00 00 00 22 00 FA FF 00 00 00 00 57 36 D9 50 24 00 02 10 00 00 02 E0 CE 1E B8
            """),
        ConformanceFixture(
            device: "Cintiq Pro 22 (DTH-227, 0x03D0) — real capture, OpenTabletDriver PR #3858",
            parser: "intuosV2",
            spec: DigitizerSpec(
                maxX: 96012, maxY: 54356, maxPressure: 8191,
                buttonCount: 8, hasTilt: true),
            deviceFamily: .intuosProGen2,
            captureLog: """
            [00:00.000] DTH-227             ID=1E len=20   1E 01 C1 DB FD 00 F4 8D 00 DB 01 0C 00 08 00 00 00 00 00 1F
            """),
    ]

    func testFixturesDecodeToNonTrivialResults() throws {
        for fixture in Self.fixtures {
            guard var decoder = ConformanceDecoderFactory.make(for: fixture.parser) else {
                XCTFail("\(fixture.device): unknown parser '\(fixture.parser)' — " +
                        "add it to ConformanceDecoderFactory.make(for:)")
                continue
            }

            let records: [CaptureRecord]
            do {
                records = try CaptureLogParser.parse(fixture.captureLog, requireHeader: false)
            } catch {
                XCTFail("\(fixture.device): capture log failed to parse: \(error)")
                continue
            }
            XCTAssertFalse(records.isEmpty, "\(fixture.device): fixture has no records")

            var state = DecoderState()
            var sawNonTrivialResult = false

            for record in records {
                let results = record.bytes.withUnsafeBufferPointer { buf -> [DecodeResult] in
                    guard let base = buf.baseAddress else { return [] }
                    return decoder.decode(
                        report: base, length: record.length,
                        spec: fixture.spec, state: &state,
                        deviceFamily: fixture.deviceFamily)
                }
                for result in results {
                    if case .none = result { continue }
                    sawNonTrivialResult = true
                }
            }

            XCTAssertTrue(
                sawNonTrivialResult,
                "\(fixture.device): every frame in the capture log decoded to nothing — " +
                "check the parser assignment and DigitizerSpec fields")
        }
    }
}
