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

    func testDongleBatteryReportsEachChange() {
        var w = DongleBatteryWatcher()
        func status(_ power: UInt8, linked: Bool = true) -> DeviceEvent.Battery? {
            // Status reports recorded from a PTH-850 on the wireless kit.
            HIDReport.withReport([0x80, linked ? 1 : 0, 0xDC, 0x14, 0xB3, power, 0x00, 0x28]) {
                w.observe($0)
            }
        }
        func held(_ power: UInt8) -> [Int?] {
            (0..<DongleBatteryWatcher.holdReports).map { _ in status(power)?.percent }
        }
        XCTAssertNil(status(0x9E, linked: false))
        // The first reading and a change in charging show at once.
        XCTAssertEqual(status(0x9E).map { [$0.percent, $0.charging ? 1 : 0] }, [96, 1])
        XCTAssertNil(status(0x9E))
        XCTAssertEqual(status(0x1F).map { [$0.percent, $0.charging ? 1 : 0] }, [100, 0])
        // A new level on battery shows once it holds.
        XCTAssertEqual(held(0x03), [nil, nil, nil, 9])
        XCTAssertNil(status(0x03, linked: false))
        XCTAssertEqual(status(0x03)?.percent, 9)
        // Bit 5 isn't part of the level.
        XCTAssertEqual(held(0x21), [nil, nil, nil, 3])
        XCTAssertNil(HIDReport.withReport([0x80, 1, 0, 0, 0]) { w.observe($0) })
        XCTAssertNil(HIDReport.withReport([0x02, 1, 0, 0, 0, 0x1F]) { w.observe($0) })
    }

    func testDongleBatteryIgnoresFlickerBetweenSteps() {
        var w = DongleBatteryWatcher()
        // Byte 5 from a PTH-850 power-on on the kit, 2026-10-15.
        let seen = [0x13, 0x16, 0x16, 0x17, 0x15, 0x15, 0x15, 0x15, 0x16, 0x15, 0x15, 0x15, 0x16, 0x16, 0x15]
            .compactMap { power in
                HIDReport.withReport([0x80, 1, 0xDC, 0x14, 0xB3, UInt8(power), 0x00, 0x28]) {
                    w.observe($0)?.percent
                }
            }
        XCTAssertEqual(seen, [61, 67])
    }

    func testDongleBatteryOnlyFallsOnceSettled() {
        var w = DongleBatteryWatcher()
        func status(_ power: UInt8, linked: Bool = true) -> Int? {
            HIDReport.withReport([0x80, linked ? 1 : 0, 0xDC, 0x14, 0xB3, power, 0x00, 0x28]) {
                w.observe($0)?.percent
            }
        }
        func held(_ power: UInt8) -> [Int?] {
            (0..<DongleBatteryWatcher.holdReports).map { _ in status(power) }
        }
        XCTAssertEqual(status(0x1C), 90)
        XCTAssertEqual(held(0x1D), [nil, nil, nil, 93])
        for _ in 0..<DongleBatteryWatcher.settleReports { _ = status(0x1D) }
        // Settled: a rise on battery is load drift, a fall still shows.
        XCTAssertEqual(held(0x1E), [nil, nil, nil, nil])
        XCTAssertEqual(held(0x1C), [nil, nil, nil, 90])
        // Charging and its end show at once.
        XCTAssertEqual(status(0x9E), 96)
        XCTAssertEqual(status(0x1F), 100)
        // A relink settles again.
        XCTAssertNil(status(0x1F, linked: false))
        XCTAssertEqual(status(0x1C), 90)
        XCTAssertEqual(held(0x1D), [nil, nil, nil, 93])
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
