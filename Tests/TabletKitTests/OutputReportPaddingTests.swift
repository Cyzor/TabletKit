// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import TabletKit

final class OutputReportPaddingTests: XCTestCase {

    func testPadsToTheDeclaredSize() {
        XCTAssertEqual(padded([0x02, 0xB0, 0x04], toSize: 8), [0x02, 0xB0, 0x04, 0, 0, 0, 0, 0])
    }

    func testLeavesAReportAtOrPastTheDeclaredSizeAlone() {
        XCTAssertEqual(padded([0x02, 0xB0, 0x04], toSize: 3), [0x02, 0xB0, 0x04])
        XCTAssertEqual(padded([0x02, 0xB0, 0x04], toSize: 2), [0x02, 0xB0, 0x04])
    }

    func testAnInterfaceThatDeclaresNothingLeavesTheReportAlone() {
        XCTAssertEqual(padded([0x02, 0xB0, 0x04], toSize: 0), [0x02, 0xB0, 0x04])
    }
}
