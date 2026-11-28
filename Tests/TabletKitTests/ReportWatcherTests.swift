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

    // Issue #35, CTL-6100 over USB: a Sense-only frame (0x40, no tool, hover
    // 63) and an identified one (0x60, Intuos Pen 0x0862; serial bytes are
    // the capture's stand-ins). The reporter's tablet kept sending the first
    // kind for up to 77 s, about 133 a second.
    static let senseOnly: [UInt8] = [
        0x10, 0x40, 0x3A, 0x3C, 0x00, 0xDE, 0x0A, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x3F, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]
    static let exit: [UInt8] = [0x10, 0x00, 0x3A, 0x3C, 0x00, 0xDE, 0x0A] + [UInt8](repeating: 0, count: 20)
    static let identified: [UInt8] = [
        0x10, 0x60, 0xF7, 0x32, 0x00, 0xB4, 0x0F, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x3E,
        0xA0, 0x2E, 0x9C, 0x1E, 0x62, 0x08, 0x10, 0x00, 0x62, 0x08,
    ]

    /// Restart times over `seconds` of reports every 7.5 ms from `start`.
    private func restarts(_ w: inout SenseOnlyWatcher, _ bytes: [UInt8], from start: Double, for seconds: Double) -> [Double] {
        var times: [Double] = []
        for t in stride(from: start, to: start + seconds, by: 0.0075) {
            if HIDReport.withReport(bytes, { w.observe($0, now: t) }) != nil { times.append(t) }
        }
        return times
    }

    func testSenseOnlyStretchAsksForRestartsThenGivesUp() {
        var w = SenseOnlyWatcher()
        let times = restarts(&w, Self.senseOnly, from: 0, for: 15)
        XCTAssertEqual(times.count, SenseOnlyWatcher.attempts)
        XCTAssertEqual(times[0], SenseOnlyWatcher.after, accuracy: 0.01)
        XCTAssertEqual(times[1] - times[0], SenseOnlyWatcher.retryAfter, accuracy: 0.01)
        XCTAssertEqual(times[2] - times[1], SenseOnlyWatcher.retryAfter, accuracy: 0.01)
    }

    /// Two scan restarts, then the connect sequence.
    func testSenseOnlyAttemptsEscalate() {
        var w = SenseOnlyWatcher()
        var attempts: [SenseOnlyWatcher.Attempt] = []
        for t in stride(from: 0.0, to: 15, by: 0.0075) {
            if let a = HIDReport.withReport(Self.senseOnly, { w.observe($0, now: t) }) { attempts.append(a) }
        }
        XCTAssertEqual(attempts, [.restartPenScan, .restartPenScan, .restartTablet])
    }

    /// A restart quiets the tablet; the frames after it continue the same
    /// stretch, so a pen left lying in range isn't restarted every second.
    func testQuietAfterARestartContinuesTheStretch() {
        var w = SenseOnlyWatcher()
        var times: [Double] = []
        var t = 0.0
        while t < 15 {
            if HIDReport.withReport(Self.senseOnly, { w.observe($0, now: t) }) != nil {
                times.append(t)
                // Scanning off: one exit frame, then quiet until it resumes.
                _ = HIDReport.withReport(Self.exit, { w.observe($0, now: t + 0.005) })
                t += 0.7
            }
            t += 0.0075
        }
        XCTAssertEqual(times.count, SenseOnlyWatcher.attempts)
        XCTAssertEqual(times[1] - times[0], SenseOnlyWatcher.retryAfter, accuracy: 0.02)
    }

    func testIdentifiedPenOrSilenceStartsAFreshStretch() {
        var w = SenseOnlyWatcher()
        XCTAssertTrue(restarts(&w, Self.senseOnly, from: 0, for: 0.9).isEmpty)
        // Identified: the next Sense-only frames start over.
        XCTAssertTrue(restarts(&w, Self.identified, from: 0.9, for: 0.1).isEmpty)
        XCTAssertTrue(restarts(&w, Self.senseOnly, from: 1.0, for: 0.9).isEmpty)
        // A gap longer than the tablet's: the pen left and came back.
        XCTAssertTrue(restarts(&w, Self.senseOnly, from: 2.2, for: 0.9).isEmpty)
        XCTAssertEqual(restarts(&w, Self.senseOnly, from: 3.1, for: 0.5).count, 1)
    }

    func testDonglePairingReportsEachNewProduct() {
        var w = DonglePairingWatcher()
        func status(_ pid: Int, linked: Bool = true) -> Int? {
            HIDReport.withReport([0x80, linked ? 1 : 0, 0, 0, 0, 0, UInt8(pid >> 8), UInt8(pid & 0xFF)]) {
                w.observe($0)
            }
        }
        // Named while the tablet sleeps, then not again once it links.
        XCTAssertEqual(status(0x0357, linked: false), 0x0357)
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
        // A level shows once it holds; a change in charging shows at once.
        XCTAssertEqual(held(0x9E), [nil, nil, nil, 96])
        XCTAssertNil(status(0x9E))
        XCTAssertEqual(status(0x1F).map { [$0.percent, $0.charging ? 1 : 0] }, [100, 0])
        XCTAssertEqual(held(0x03), [nil, nil, nil, 9])
        XCTAssertNil(status(0x03, linked: false))
        XCTAssertEqual(held(0x03), [nil, nil, nil, 9])
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
        // It reads low for a few reports, then settles.
        XCTAssertEqual(seen, [67])
    }

    func testDongleBatteryOnlyFallsOnBattery() {
        var w = DongleBatteryWatcher()
        func status(_ power: UInt8, linked: Bool = true) -> Int? {
            HIDReport.withReport([0x80, linked ? 1 : 0, 0xDC, 0x14, 0xB3, power, 0x00, 0x28]) {
                w.observe($0)?.percent
            }
        }
        func held(_ power: UInt8) -> [Int?] {
            (0..<DongleBatteryWatcher.holdReports).map { _ in status(power) }
        }
        XCTAssertEqual(held(0x1D), [nil, nil, nil, 93])
        // A rise on battery is load drift, a fall still shows.
        XCTAssertEqual(held(0x1E), [nil, nil, nil, nil])
        XCTAssertEqual(held(0x1C), [nil, nil, nil, 90])
        // Charging and its end show at once.
        XCTAssertEqual(status(0x9E), 96)
        XCTAssertEqual(status(0x1F), 100)
        // A relink starts over.
        XCTAssertNil(status(0x1F, linked: false))
        XCTAssertEqual(held(0x1C), [nil, nil, nil, 90])
        XCTAssertEqual(held(0x1D), [nil, nil, nil, nil])
    }
}
