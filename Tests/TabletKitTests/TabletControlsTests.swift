// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import TabletKit

final class TabletControlsTests: XCTestCase {

    private final class PlainDevice: TabletDevice {
        let spec = DigitizerSpec(
            maxX: 100, maxY: 100, maxPressure: 1023, buttonCount: 0)
        func open() {}
        func close() {}
    }

    private final class LEDDevice: TabletDevice, RingLEDControl {
        let spec = DigitizerSpec(
            maxX: 100, maxY: 100, maxPressure: 1023, buttonCount: 0)
        var lit: Int?
        var controls: TabletControls { TabletControls(ringLED: self) }
        func open() {}
        func close() {}
        func setRingLED(index: Int) { lit = index }
        func setRingLEDColors(_ colors: [LEDColor?]) {}
    }

    func testDevicesHaveNoControlsByDefault() {
        let controls = PlainDevice().controls
        XCTAssertNil(controls.ringLED)
        XCTAssertNil(controls.labels)
        XCTAssertNil(controls.displayPanel)
        XCTAssertNil(controls.quickKeys)
    }

    func testADeviceOffersOnlyTheControlsItHas() {
        let device = LEDDevice()
        device.controls.ringLED?.setRingLED(index: 2)
        XCTAssertEqual(device.lit, 2)
        XCTAssertNil(device.controls.labels)
    }
}
