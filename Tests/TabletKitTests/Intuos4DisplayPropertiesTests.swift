// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
//
// Intuos4 report 0x20 and idle cycle, against the bytes Wacom's driver sends.
import XCTest
@testable import TabletKit

final class Intuos4DisplayPropertiesTests: XCTestCase {

    private typealias P = Intuos4DisplayProperties

    func testPTK640MatchesVendorDriver() {
        XCTAssertEqual(P.displayProperties(slot: 2, sleepState: .awake, productID: 0x00B9),
                       [0x20, 0x06, 10, 40, 0x1a, 0, 0, 0, 0])
        XCTAssertEqual(P.displayProperties(slot: 2, sleepState: .lightSleep, productID: 0x00B9),
                       [0x20, 0x06, 10, 40, 0x15, 0, 0, 0, 0])
        XCTAssertEqual(P.displayProperties(slot: 2, sleepState: .deepSleep, productID: 0x00B9),
                       [0x20, 0x06, 10, 10, 0x00, 0, 0, 0, 0])
    }

    func testPTK540WLUsesItsOwnOLEDTable() {
        XCTAssertEqual(P.displayProperties(slot: 0, sleepState: .awake, productID: 0x00BC)[4], 0x1c)
        XCTAssertEqual(P.displayProperties(slot: 0, sleepState: .lightSleep, productID: 0x00BC)[4], 0x17)
        XCTAssertEqual(P.displayProperties(slot: 0, sleepState: .deepSleep, productID: 0x00BC)[4], 0x00)
    }

    /// The PTK-440 and every non-Intuos4 sibling keep the kernel defaults.
    func testModelsTheDriverDoesNotDimKeepKernelDefaults() {
        for productID in [0x00B8, 0x00BD, 0x0042] {
            XCTAssertFalse(P.hasOLEDs(productID: productID))
            for state in P.SleepState.allCases {
                XCTAssertEqual(P.displayProperties(slot: 1, sleepState: state, productID: productID),
                               [0x20, 0x05, 10, 20, 10, 0, 0, 0, 0])
            }
        }
    }

    func testIdleCycleCountsFromLastInputAndEndsInDeepSleep() {
        XCTAssertEqual(P.nextSleepState(after: .awake), .lightSleep)
        XCTAssertEqual(P.nextSleepState(after: .lightSleep), .deepSleep)
        XCTAssertNil(P.nextSleepState(after: .deepSleep))
        XCTAssertEqual(P.deadline(leaving: .awake, lastInput: 1000), 1300)
        XCTAssertEqual(P.deadline(leaving: .lightSleep, lastInput: 1000), 1600)
        XCTAssertNil(P.deadline(leaving: .deepSleep, lastInput: 1000))
    }
}
