// SPDX-License-Identifier: MPL-2.0
//
// What TabletOutput writes, and where, for each LED format, the Xencelabs
// vendor tunnel, the Intuos4 key displays, and a Quick Keys relink.
import Foundation
import IOKit
import XCTest
@testable import TabletKit

final class TabletOutputTests: XCTestCase {

    private func interface(productID: Int, usagePage: Int, maxOutput: Int = 0) -> ReplayInterface {
        var r = ReplayRecording.Interface()
        r.vendorID = 0x056A
        r.productID = productID
        r.usagePage = usagePage
        r.maxOutputReportSize = maxOutput
        return ReplayInterface(r)
    }

    private func output(_ pid: Int, bluetooth: Bool = false) throws -> (TabletOutput, ReplayInterface, HIDOutputQueue) {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: pid))
        let queue = HIDOutputQueue(label: "test")
        let out = TabletOutput(spec: spec, queue: queue)
        let primary = interface(productID: pid, usagePage: 0xFF00)
        out.attach(primary: primary, isBluetooth: bluetooth, isWireless: false)
        return (out, primary, queue)
    }

    func testIntuosV2RingLEDOverUSBAndBluetooth() throws {
        let (usb, usbIface, q1) = try output(0x0358)
        usb.setRingLED(index: 0)
        q1.drain()
        XCTAssertEqual(usbIface.writes, ["feature 31 46 46 46 46 46", "feature 32 46 01"], "four slots start at 1")

        let (bt, btIface, q2) = try output(0x0358, bluetooth: true)
        bt.setRingLED(index: 2)
        q2.drain()
        let bytes = btIface.writes.first?.split(separator: " ").dropFirst().compactMap { UInt8($0, radix: 16) } ?? []
        XCTAssertEqual(bytes.count, 51)
        XCTAssertEqual(bytes[0], 0x82)
        XCTAssertEqual(bytes[10], 3)
    }

    /// Two-ring Cintiqs take both rings in one report, on the LED interface
    /// once it exists: the right ring in the low bits.
    func testCintiqDualRingsShareOneReportOnTheLEDInterface() throws {
        let (out, primary, queue) = try output(0x00F4)
        let led = interface(productID: 0x0056, usagePage: 0xFF00)
        out.setLEDInterface(led)
        out.setRingLED(index: 1)
        out.setRingLED2(index: 2)
        queue.drain()
        XCTAssertTrue(primary.writes.isEmpty)
        XCTAssertEqual(led.writes.last, "feature 20 56 00 00 00 00 00 00 00")
    }

    func testIntuos4AndIntuos5LEDLayouts() throws {
        let (i4, i4Iface, q1) = try output(0x00B8)
        i4.setRingLED(index: 2)
        q1.drain()
        XCTAssertEqual(i4Iface.writes, ["feature 20 06 0a 14 0a 00 00 00 00"])

        let (i5, i5Iface, q2) = try output(0x0028)
        i5.setRingLED(index: 3)
        q2.drain()
        XCTAssertEqual(i5Iface.writes, ["feature 20 03 00 00 00 00 00 00 00"])
    }

    /// Quick Keys writes made before its vendor tunnel registers wait for it,
    /// then go out in order, padded.
    func testXencelabsWritesWaitForTheVendorTunnel() throws {
        let spec = TabletSpec(
            productID: 0x5202, name: "Xencelabs Quick Keys", format: .xencelabs, maxX: 0, maxY: 0,
            maxPressure: 8191, buttonCount: 8, hasTouchRing: true, hasMechanicalDial: true,
            hasEraser: false, hasTilt: false, seizeUSB: false)
        let queue = HIDOutputQueue(label: "test")
        let out = TabletOutput(spec: spec, queue: queue)
        let digitizer = interface(productID: 0x5202, usagePage: 0x0D)
        out.attach(primary: digitizer, isBluetooth: false, isWireless: false)
        out.setQuickKeysSleepMinutes(10)
        out.setQuickKeysOledBrightness(2)
        queue.drain()
        XCTAssertTrue(digitizer.writes.isEmpty, "nothing goes to the decorative interface")

        let tunnel = interface(productID: 0x5202, usagePage: 0xFF0A, maxOutput: 32)
        out.addSibling(tunnel, isVendorTunnel: true, isInputModeInterface: false)
        out.setQuickKeysSleepMinutes(10)
        queue.drain()
        XCTAssertEqual(tunnel.writes.count, 2, "both held writes, and no repeat of an unchanged setting")
        XCTAssertTrue(tunnel.writes.allSatisfy { $0.split(separator: " ").count == 33 }, "padded to 32 bytes")
    }

    func testDisplayPanelSettingsAreNotResent() throws {
        let spec = TabletSpec(
            productID: 0x520D, name: "Xencelabs Pen Display 24", format: .xencelabs,
            maxX: 52_960, maxY: 29_790, maxPressure: 8191, buttonCount: 0, hasTouchRing: false,
            hasEraser: true, isPenDisplay: true, seizeUSB: false)
        let queue = HIDOutputQueue(label: "test")
        let out = TabletOutput(spec: spec, queue: queue)
        let tunnel = interface(productID: 0x520D, usagePage: 0xFF0A)
        out.attach(primary: tunnel, isBluetooth: false, isWireless: false)
        XCTAssertNotNil(out.controls.displayPanel)
        out.setDisplayBrightness(50)
        out.setDisplayBrightness(50)
        out.setColorMode(1)
        queue.drain()
        XCTAssertEqual(tunnel.writes.count, 3, "brightness once, then the preset and its commit")
    }

    /// Each key's display gets a start, its image chunks, and a stop, and
    /// only when its label changes.
    func testIntuos4KeyDisplaysSendChangedKeysOnly() throws {
        let (out, primary, queue) = try output(0x00B8)
        XCTAssertNotNil(out.controls.labels)
        out.setAuxKeyLabels(["Undo", "Redo"])
        queue.drain()
        let first = primary.writes.count
        XCTAssertEqual(first, 2 * (1 + 4 + 1))
        out.setAuxKeyLabels(["Undo", "Save"])
        queue.drain()
        XCTAssertEqual(primary.writes.count - first, 6, "only the changed key")
        out.setKeyOLEDsRotated180(true)
        queue.drain()
        XCTAssertEqual(primary.writes.count - first, 6 + 12, "turning resends both keys")
    }

    /// A relink addresses the puck, and the resync afterward puts the labels
    /// back even though they were already sent.
    /// The UI shows controls from `offeredControls` while a tablet is
    /// unplugged, so a connected one must fill exactly those slots.
    func testControlsFillExactlyTheOfferedSlots() {
        for spec in WacomDeviceRegistry.knownDevices {
            let c = TabletOutput(spec: spec, queue: HIDOutputQueue(label: "test")).controls
            let filled: TabletControls.Kinds = [
                c.ringLED != nil ? .ringLED : [], c.labels != nil ? .labels : [],
                c.displayPanel != nil ? .displayPanel : [], c.quickKeys != nil ? .quickKeys : [],
            ]
            XCTAssertEqual(filled, spec.offeredControls, spec.name)
        }
    }

    func testTabletWithoutARingGetsNoLEDWrites() throws {
        let (out, primary, queue) = try output(0x0374)  // CTL-4100
        XCTAssertNil(out.controls.ringLED)
        out.setCapableInterface(primary)
        out.setRingLED(index: 1)
        queue.drain()
        XCTAssertEqual(primary.writes, [])
    }

    /// The receiver's own row has no ring; the tablet it relays may.
    func testWirelessReceiverOffersTheRingLED() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x0084))
        XCTAssertNil(TabletOutput(spec: spec, queue: HIDOutputQueue(label: "test")).controls.ringLED)
        XCTAssertNotNil(
            TabletOutput(spec: spec, queue: HIDOutputQueue(label: "test"), isWirelessReceiver: true).controls.ringLED)
    }

    func testRelinkAndResync() throws {
        let spec = TabletSpec(
            productID: 0x5203, name: "Quick Keys receiver", format: .xencelabs, maxX: 0, maxY: 0,
            maxPressure: 8191, buttonCount: 8, hasTouchRing: true, hasMechanicalDial: true,
            hasEraser: false, hasTilt: false, seizeUSB: false)
        let queue = HIDOutputQueue(label: "test")
        let out = TabletOutput(spec: spec, queue: queue)
        let tunnel = interface(productID: 0x5203, usagePage: 0xFF0A)
        out.attach(primary: tunnel, isBluetooth: false, isWireless: false)
        let identity: [UInt8] = [1, 2, 3, 4, 5, 6]
        let result = expectation(description: "relink result")
        out.relink(identity: identity) { ret in
            XCTAssertEqual(ret, kIOReturnSuccess)
            result.fulfill()
        }
        wait(for: [result], timeout: 1)
        XCTAssertEqual(tunnel.writes.first, "output 02 b0 04 00 00 00 00 00 00 00 01 02 03 04 05 06")

        out.setRingModeLabel("Zoom")
        queue.drain()
        let before = tunnel.writes.count
        out.setRingModeLabel("Zoom")
        queue.drain()
        XCTAssertEqual(tunnel.writes.count, before, "an unchanged label isn't resent")
        out.resyncAfterRelink()
        queue.drain()
        XCTAssertGreaterThan(tunnel.writes.count, before + 3, "polls, the LED, and the label again")
        out.stop()
    }
}
