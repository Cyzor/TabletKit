// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import TabletKit

final class HeldInterfacesTests: XCTestCase {
    private final class Iface {}

    func testReleaseReturnsArrivalOrderOnce() {
        var held = HeldInterfaces<Iface>()
        let a = Iface(), b = Iface(), c = Iface()
        held.hold(a, under: 1); held.hold(b, under: 1); held.hold(c, under: 2)
        XCTAssertTrue(held.release(1).elementsEqual([a, b], by: ===))
        XCTAssertTrue(held.release(1).isEmpty)
        XCTAssertTrue(held.release(2).elementsEqual([c], by: ===))
        XCTAssertTrue(held.isEmpty)
    }

    func testTakeAfterReleaseFails() {
        var held = HeldInterfaces<Iface>()
        let a = Iface()
        held.hold(a, under: 1)
        XCTAssertTrue(held.take(a, under: 1))
        XCTAssertFalse(held.take(a, under: 1))
        held.hold(a, under: 1)
        _ = held.release(1)
        XCTAssertFalse(held.take(a, under: 1), "the wait ran out after its tablet took it")
    }

    func testDropForgetsEverywhere() {
        var held = HeldInterfaces<Iface>()
        let a = Iface(), b = Iface()
        held.hold(a, under: 1); held.hold(b, under: 1); held.hold(a, under: 2)
        held.drop(a)
        XCTAssertTrue(held.release(1).elementsEqual([b], by: ===))
        XCTAssertTrue(held.release(2).isEmpty)
    }
}
