// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 TabletKit contributors
// SPDX-License-Identifier: MPL-2.0
//
// Telling a report the decoder ignores apart from one it doesn't know.
import XCTest
@testable import TabletKit

final class ReportFormatReadsTests: XCTestCase {

    func testIntuosV2KnowsItsStatusReport() {
        XCTAssertEqual(ReportFormat.intuosV2.reads(reportID: 0x13), true)
        XCTAssertEqual(ReportFormat.intuosV2.reads(reportID: 0x10), true)
        XCTAssertEqual(ReportFormat.intuosV2.reads(reportID: 0x42), false)
        XCTAssertNil(ReportFormat.cintiqV1.reads(reportID: 0x10))
    }

    /// An ID left off the list must decode to nothing, so a new case in the
    /// decoder's switch can't go unlisted.
    func testUnlistedIDsDecodeToNothing() {
        let spec = WacomDeviceRegistry.spec(for: 0x0358)!.digitizerSpec  // PTH-860
        var seed: UInt64 = 11
        func byte() -> UInt8 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }
        for id in 0...255 where !IntuosV2Decoder.reportIDs.contains(UInt8(id)) {
            for length in [2, 17, 64, 99, 361] {
                var bytes = (0..<length).map { _ in byte() }
                bytes[0] = UInt8(id)
                var state = IntuosV2Decoder.State()
                let results = HIDReport.withReport(bytes) {
                    IntuosV2Decoder().decode(report: $0, spec: spec, state: &state, deviceFamily: .intuosProGen2)
                }
                XCTAssertTrue(results.isEmpty, "0x\(String(id, radix: 16)) length \(length)")
            }
        }
    }
}
