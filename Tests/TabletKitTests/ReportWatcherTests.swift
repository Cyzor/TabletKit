// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import TabletKit

final class ReportWatcherTests: XCTestCase {

    private let rule = TabletQuirks.defaults(for: .intuosV3).usbIdleReport!

    private func idle(_ w: inout IdleReportWatcher, _ id: UInt8, at t: TimeInterval) -> Bool {
        HIDReport.withReport([id, 0, 0]) { w.observe($0, now: t) }
    }

    func testIdleReportAsksForInitAfterTimeoutThenWaitsAnotherTimeout() {
        var w = IdleReportWatcher(rule: rule)
        XCTAssertFalse(idle(&w, 0x06, at: 0))
        XCTAssertFalse(idle(&w, 0x06, at: 5))  // not past the timeout yet
        XCTAssertTrue(idle(&w, 0x06, at: 5.1))
        XCTAssertFalse(idle(&w, 0x06, at: 9))
        XCTAssertTrue(idle(&w, 0x06, at: 10.2))
    }

    func testLiveReportResetsTheIdleClock() {
        var w = IdleReportWatcher(rule: rule)
        _ = idle(&w, 0x06, at: 0)
        _ = idle(&w, 0x1E, at: 4)
        XCTAssertFalse(idle(&w, 0x06, at: 6))
        XCTAssertFalse(idle(&w, 0x06, at: 11))
        XCTAssertTrue(idle(&w, 0x06, at: 11.1))
    }

    func testOtherReportsNeitherCountNorReset() {
        var w = IdleReportWatcher(rule: rule)
        _ = idle(&w, 0x06, at: 0)
        _ = idle(&w, 0x10, at: 3)
        XCTAssertTrue(idle(&w, 0x06, at: 5.5))
    }

    func testDonglePairingReportsEachNewProduct() {
        var w = DonglePairingWatcher()
        func status(_ pid: Int, linked: Bool = true) -> Int? {
            HIDReport.withReport([0x80, linked ? 1 : 0, 0, 0, 0, 0, UInt8(pid >> 8), UInt8(pid & 0xFF)]) {
                w.observe($0)
            }
        }
        XCTAssertNil(status(0x0357, linked: false))
        XCTAssertEqual(status(0x0357), 0x0357)
        XCTAssertNil(status(0x0357))
        XCTAssertNil(status(0))
        XCTAssertEqual(status(0x0358), 0x0358)
        XCTAssertNil(HIDReport.withReport([0x80, 1, 0]) { w.observe($0) })
    }

    func testGraceFiresOnceWhenThePenStaysInRange() {
        var g = ToolAnnouncementGrace(frames: 4)
        let fired = [false, true, true, true, true, true, true].map { g.advance(penInRange: $0) }
        XCTAssertEqual(fired, [false, false, false, false, true, false, false])
        XCTAssertFalse(g.advance(penInRange: false))
        XCTAssertEqual((0..<4).map { _ in g.advance(penInRange: true) }, [false, false, false, true])
    }

    func testZeroFramesNeverFires() {
        var g = ToolAnnouncementGrace(frames: 0)
        XCTAssertFalse((0..<5).contains { _ in g.advance(penInRange: true) })
    }
}
