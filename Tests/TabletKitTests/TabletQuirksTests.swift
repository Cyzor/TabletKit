// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import TabletKit

/// Pins each family default to the behavior it replaced.
final class TabletQuirksTests: XCTestCase {

    func testFamilyDefaults() {
        let v2 = TabletQuirks.defaults(for: .intuosV2)
        XCTAssertTrue(v2.inputModeWriteOverUSB)
        XCTAssertFalse(v2.initOverBluetooth)
        XCTAssertFalse(v2.initNeedsDeclaringInterface)

        let v3 = TabletQuirks.defaults(for: .intuosV3)
        XCTAssertTrue(v3.initOverBluetooth)
        XCTAssertTrue(v3.initNeedsDeclaringInterface)
        XCTAssertEqual(v3.usbIdleReport?.reportID, 0x06)
        XCTAssertEqual(v3.usbIdleReport?.liveReportIDs, [0x1E, 0x1B])
        XCTAssertEqual(v3.usbIdleReport?.timeout, 5)
        XCTAssertEqual(v3.toolAnnounceGraceFrames, 4)

        for format in [ReportFormat.intuosV1, .bamboo] {
            XCTAssertTrue(TabletQuirks.defaults(for: format).initNeedsDeclaringInterface)
        }

        let xl = TabletQuirks.defaults(for: .xencelabs)
        XCTAssertFalse(xl.answersSerialQuery)
        XCTAssertTrue(xl.reinitOnReenumeration)

        XCTAssertTrue(TabletQuirks.defaults(for: .cintiqV1).seizesTouchSensor)
        XCTAssertEqual(TabletQuirks.defaults(for: .intuos3), TabletQuirks())
    }

    /// The One S and M send real pen data in report 0x06; only the three
    /// USB rows the driver exempted before quirks existed are exempt.
    func testWacomOneRowsHaveNoIdleReport() {
        for pid in [0x0100, 0x0102, 0x0104] {
            XCTAssertNil(WacomDeviceRegistry.spec(for: pid)?.quirks.usbIdleReport, "0x\(String(pid, radix: 16))")
        }
        XCTAssertNotNil(WacomDeviceRegistry.spec(for: 0x0105)?.quirks.usbIdleReport)
        XCTAssertNotNil(WacomDeviceRegistry.spec(for: 0x03F9)?.quirks.usbIdleReport)  // PTK-870
    }

    func testOverrideKeepsOtherDefaults() {
        let spec = TabletSpec(
            productID: 1, name: "t", format: .intuosV3, maxX: 1, maxY: 1, maxPressure: 1,
            buttonCount: 0, hasTouchRing: false, hasEraser: false, seizeUSB: false)
        let changed = spec.withQuirks { $0.usbIdleReport = nil }
        XCTAssertNil(changed.quirks.usbIdleReport)
        XCTAssertEqual(changed.quirks.toolAnnounceGraceFrames, 4)
    }
}
