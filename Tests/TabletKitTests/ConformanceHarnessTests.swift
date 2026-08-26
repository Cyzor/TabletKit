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
    /// Device-family string passed to `decode(deviceFamily:)`.
    let deviceFamily: String
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
            deviceFamily: "bamboo",
            captureLog: """
            [00:00.000] CTL-460             ID=02 len=9    02 21 34 12 45 23 E8 03 00
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
