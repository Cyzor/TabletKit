// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tests for the vendor-agnostic universal floor decode logic. No hardware: we
// drive GenericDigitizerFrame with synthesized (usagePage, usage, value) tuples
// matching the HID Usage Tables, exactly as IOKit value callbacks would deliver
// them for a standards-compliant pen digitizer. This validates the decode logic
// (axis mapping, proximity rules, click-pressure synthesis); the IOKit plumbing
// in GenericHIDDigitizer still needs a physical device to exercise.

import XCTest
@testable import TabletKit

final class GenericDigitizerFrameTests: XCTestCase {

    private typealias U = GenericDigitizerFrame.Usage

    // A typical pressure-reporting pen: X/Y, tip switch, in-range, pressure.
    private func pressurePen() -> GenericDigitizerFrame {
        GenericDigitizerFrame(
            maxX: 32767, maxY: 32767, maxPressure: 8191,
            hasInRange: true, hasPressure: true)
    }

    // A minimal tip-only pen: X/Y and tip switch, no in-range, no pressure axis.
    private func tipOnlyPen() -> GenericDigitizerFrame {
        GenericDigitizerFrame(
            maxX: 4095, maxY: 4095, maxPressure: 1023,
            hasInRange: false, hasPressure: false)
    }

    func testRecognizesStandardUsagesAndRejectsOthers() {
        var f = pressurePen()
        XCTAssertTrue(f.update(usagePage: U.genericDesktopPage, usage: U.x, value: 100))
        XCTAssertTrue(f.update(usagePage: U.digitizerPage, usage: U.tipSwitch, value: 1))
        // Vendor-defined / unrelated usage is ignored.
        XCTAssertFalse(f.update(usagePage: 0xFF00, usage: 0x01, value: 42))
        XCTAssertFalse(f.update(usagePage: U.digitizerPage, usage: 0x09, value: 1))
    }

    func testAbsolutePositionPassesThrough() {
        var f = pressurePen()
        f.update(usagePage: U.genericDesktopPage, usage: U.x, value: 12345)
        f.update(usagePage: U.genericDesktopPage, usage: U.y, value: 6789)
        let p = f.point()
        XCTAssertEqual(p.x, 12345)
        XCTAssertEqual(p.y, 6789)
        XCTAssertEqual(p.maxX, 32767)
        XCTAssertEqual(p.maxY, 32767)
    }

    func testPressurePassesThroughWhenReported() {
        var f = pressurePen()
        f.update(usagePage: U.digitizerPage, usage: U.tipSwitch, value: 1)
        f.update(usagePage: U.digitizerPage, usage: U.tipPressure, value: 4096)
        XCTAssertEqual(f.point().pressure, 4096)
    }

    func testTipOnlyPenSynthesizesClickPressure() {
        var f = tipOnlyPen()
        // Hovering: tip up → no pressure, so no click downstream.
        XCTAssertEqual(f.point().pressure, 0)
        // Tip down with no pressure axis → synthesized full-scale so taps register.
        f.update(usagePage: U.digitizerPage, usage: U.tipSwitch, value: 1)
        XCTAssertEqual(f.point().pressure, 1023)
        // Tip up again → back to zero.
        f.update(usagePage: U.digitizerPage, usage: U.tipSwitch, value: 0)
        XCTAssertEqual(f.point().pressure, 0)
    }

    func testProximityTrustsInRangeWhenPresent() {
        var f = pressurePen()
        XCTAssertFalse(f.point().inProximity)  // in-range not yet set
        f.update(usagePage: U.digitizerPage, usage: U.inRange, value: 1)
        XCTAssertTrue(f.point().inProximity)
        f.update(usagePage: U.digitizerPage, usage: U.inRange, value: 0)
        XCTAssertFalse(f.point().inProximity)
    }

    func testProximityDefaultsTrueWithoutInRange() {
        // A device with no In Range usage only reports while active, so frames
        // are treated as in-proximity.
        let f = tipOnlyPen()
        XCTAssertTrue(f.point().inProximity)
    }

    func testBarrelButtonsAndEraserMap() {
        var f = pressurePen()
        f.update(usagePage: U.digitizerPage, usage: U.barrelSwitch, value: 1)
        f.update(usagePage: U.digitizerPage, usage: U.secondaryBarrel, value: 1)
        f.update(usagePage: U.digitizerPage, usage: U.eraserSwitch, value: 1)
        let p = f.point()
        XCTAssertTrue(p.penButton1)
        XCTAssertTrue(p.penButton2)
        XCTAssertTrue(p.eraser)
    }

    func testInvertUsageAlsoSetsEraser() {
        var f = pressurePen()
        f.update(usagePage: U.digitizerPage, usage: U.invert, value: 1)
        XCTAssertTrue(f.point().eraser)
    }

    func testTiltMapsToDoubles() {
        var f = pressurePen()
        f.update(usagePage: U.digitizerPage, usage: U.tiltX, value: -30)
        f.update(usagePage: U.digitizerPage, usage: U.tiltY, value: 45)
        let p = f.point()
        XCTAssertEqual(p.tiltX, -30.0)
        XCTAssertEqual(p.tiltY, 45.0)
    }
}
