// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import Foundation
import IOKit
import XCTest
@testable import TabletKit

final class HIDOutputQueueTests: XCTestCase {

    func testSendsInOrderAndReportsResults() {
        let iface = RecordingHIDInterface()
        let queue = HIDOutputQueue(label: "test")
        let results = Recorded<IOReturn>()
        for i in 0..<5 {
            queue.send(.feature, [0x20, UInt8(i)], to: iface) { results.append($0) }
        }
        queue.drain()
        XCTAssertEqual(iface.log, (0..<5).map { "feature 20 0\($0)" })
        XCTAssertEqual(results.values, Array(repeating: kIOReturnSuccess, count: 5))
    }

    func testPacesOnlyPacedWrites() {
        let iface = RecordingHIDInterface()
        let queue = HIDOutputQueue(label: "test", minimumGap: 0.02)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<3 { queue.send(.output, [0x02], to: iface) }
        queue.drain()
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 15_000_000)

        let pacedStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<3 { queue.send(.output, [0x02], to: iface, paced: true) }
        queue.drain()
        // The first paced write has nothing to wait for; the next two wait 20 ms each.
        XCTAssertGreaterThanOrEqual(DispatchTime.now().uptimeNanoseconds - pacedStart, 38_000_000)
    }

    func testSendReturnsWithoutWaitingForTheWrite() {
        let iface = RecordingHIDInterface()
        let queue = HIDOutputQueue(label: "test", minimumGap: 0.05)
        queue.send(.output, [0x02], to: iface, paced: true)
        let start = DispatchTime.now().uptimeNanoseconds
        queue.send(.output, [0x02], to: iface, paced: true)
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 10_000_000)
        queue.drain()
    }
}
