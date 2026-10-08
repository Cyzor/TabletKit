// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import CoreFoundation
import Foundation
import XCTest
@testable import TabletKit

final class HIDThreadTests: XCTestCase {

    /// The shared run loop must belong to a live background thread that runs
    /// work scheduled on it, or no HID report would ever be delivered.
    func testRunLoopRunsScheduledWorkOffTheMainThread() {
        let ran = expectation(description: "block ran on the HID run loop")
        let runLoop = HIDThread.shared.runLoop
        XCTAssertFalse(runLoop === CFRunLoopGetMain())

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(Thread.current.name, "com.cyzor.mocktab.hid")
            ran.fulfill()
        }
        CFRunLoopWakeUp(runLoop)
        wait(for: [ran], timeout: 2)
    }
}
