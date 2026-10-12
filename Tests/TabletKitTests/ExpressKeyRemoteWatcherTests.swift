// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import TabletKit

final class ExpressKeyRemoteWatcherTests: XCTestCase {

    /// A 0x10 pairing table with `serials` in slots 0, 1, …
    private func table(_ serials: [UInt32]) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 32)
        r[0] = 0x10
        for (i, s) in serials.enumerated() {
            let j = i * 6
            r[j + 4] = UInt8(s & 0xFF); r[j + 5] = UInt8(s >> 8 & 0xFF); r[j + 6] = UInt8(s >> 16 & 0xFF)
        }
        return r
    }

    /// A 0x11 event from `serial`.
    private func event(_ serial: UInt32) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 32)
        r[0] = 0x11
        r[3] = UInt8(serial & 0xFF); r[4] = UInt8(serial >> 8 & 0xFF); r[5] = UInt8(serial >> 16 & 0xFF)
        r[12] = 0x7F
        return r
    }

    private func observe(_ w: inout ExpressKeyRemoteWatcher, _ r: [UInt8]) -> [ExpressKeyRemoteWatcher.Change] {
        HIDReport.withReport(r) { w.observe($0) }
    }

    func testPairedButSilentUntilFirstEvent() {
        var w = ExpressKeyRemoteWatcher()
        XCTAssertEqual(observe(&w, table([0x123456])), [])
        XCTAssertEqual(w.silentRemotes, [0x123456])
        XCTAssertEqual(observe(&w, event(0x123456)), [.init(serial: 0x123456, link: .online)])
        XCTAssertEqual(w.silentRemotes, [])
        XCTAssertEqual(observe(&w, event(0x123456)), [], "online once")
        XCTAssertEqual(observe(&w, table([0x123456])), [], "an unchanged table changes nothing")
    }

    func testUnpairingTakesTheRemoteOffline() {
        var w = ExpressKeyRemoteWatcher()
        _ = observe(&w, table([0x000001, 0x000002]))
        _ = observe(&w, event(0x000001))
        XCTAssertEqual(observe(&w, table([0x000002])), [.init(serial: 1, link: .offline)])
        XCTAssertEqual(w.paired, [2])
        XCTAssertEqual(w.heard, [])
        // Paired again: online again on its next event.
        _ = observe(&w, table([0x000001, 0x000002]))
        XCTAssertEqual(observe(&w, event(0x000001)), [.init(serial: 1, link: .online)])
    }

    func testIgnoresZeroSerialsAndShortReports() {
        var w = ExpressKeyRemoteWatcher()
        XCTAssertEqual(observe(&w, event(0)), [])
        XCTAssertEqual(observe(&w, [0x11, 0, 0]), [])
        XCTAssertEqual(observe(&w, [0x10]), [])
    }
}
