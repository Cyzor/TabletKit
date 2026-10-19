// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import TabletKit

final class ByteReadingTests: XCTestCase {
    private let bytes: [UInt8] = [0x34, 0x12, 0x56, 0xFE, 0xFF, 0x78]

    func testLittleEndian() {
        XCTAssertEqual(bytes.le16(at: 0), 0x1234)
        XCTAssertEqual(bytes.le24(at: 0), 0x56_1234)
        XCTAssertEqual(bytes.le32(at: 0), 0xFE56_1234)
    }

    func testBigEndian() {
        XCTAssertEqual(bytes.be16(at: 0), 0x3412)
    }

    func testSignedLittleEndian() {
        XCTAssertEqual(bytes.signedLE16(at: 3), -2)
        XCTAssertEqual(bytes.signedLE16(at: 0), 0x1234)
    }

    func testReportAndPointerReadAlike() {
        HIDReport.withReport(bytes) { report in
            XCTAssertEqual(report.le16(at: 1), bytes.le16(at: 1))
            XCTAssertEqual(report.pointer.le24(at: 2), bytes.le24(at: 2))
        }
    }
}
