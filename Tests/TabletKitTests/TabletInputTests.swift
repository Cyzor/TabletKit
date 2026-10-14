// SPDX-License-Identifier: MPL-2.0
//
// TabletInput's effects and gates on paths the report traces don't reach:
// the idle-report resend, a wireless receiver's pairing and link gate, and
// the Xencelabs Pen Display.
import Foundation
import XCTest
@testable import TabletKit

final class TabletInputTests: XCTestCase {

    private func feed(_ input: inout TabletInput, _ bytes: [UInt8], seconds: Double = 0) -> TabletInput.Output {
        HIDReport.withReport(bytes) { input.handle($0, at: UInt64(seconds * 1_000_000_000) + 1) }
    }

    func testStuckIdleReportAsksForInitOverUSBOnly() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x03F9))  // PTK-870
        let rule = try XCTUnwrap(spec.quirks.usbIdleReport)
        var usb = TabletInput(spec: spec, isBluetooth: false, isWireless: false)
        var effects: [TabletInput.Effect] = []
        for t in stride(from: 0.0, through: rule.timeout + 1, by: 1) {
            effects += feed(&usb, [rule.reportID, 0, 0, 0], seconds: t).effects
        }
        XCTAssertEqual(effects, [.resendInit(.stuckOnIdleReport(reportID: rule.reportID))])

        var bluetooth = TabletInput(spec: spec, isBluetooth: true, isWireless: false)
        for t in stride(from: 0.0, through: rule.timeout + 1, by: 1) {
            XCTAssertTrue(feed(&bluetooth, [rule.reportID, 0, 0, 0], seconds: t).effects.isEmpty)
        }
    }

    /// A receiver holds the pen back until its link is up, names its tablet
    /// once, and asks for init when the link comes up.
    func testReceiverGatesUntilLinkUpAndNamesItsTablet() throws {
        let dongle = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x0084))
        var input = TabletInput(spec: dongle, isBluetooth: false, isWireless: true)
        let toolChange: [UInt8] = [0x02, 0xC2, 130, 41, 152, 0, 94, 88, 0, 168]

        let before = feed(&input, toolChange)
        XCTAssertFalse(before.events.contains { if case .tool = $0 { true } else { false } },
                       "no pen events before the link is up")

        // Status report: link up, paired with a PTH-850 (0x0028).
        let status: [UInt8] = [0x80, 0x01, 0, 0, 0, 0, 0x00, 0x28]
        let up = feed(&input, status)
        XCTAssertEqual(up.effects, [.pairedTablet(productID: 0x0028), .resendInit(.wirelessLinkUp)])
        XCTAssertEqual(input.pairedProductID, 0x0028)
        XCTAssertEqual(input.digitizer.maxX, WacomDeviceRegistry.spec(for: 0x0028)?.maxX)
        XCTAssertTrue(feed(&input, status).effects.isEmpty, "a repeated status changes nothing")

        let after = feed(&input, toolChange)
        XCTAssertTrue(after.events.contains { if case .tool(let t) = $0 { t.phase == .enter } else { false } })

        let lost = feed(&input, [0x80, 0x00, 0, 0, 0, 0, 0, 0])
        XCTAssertTrue(lost.effects.isEmpty)
        let gated = feed(&input, toolChange)
        XCTAssertFalse(gated.events.contains { if case .tool = $0 { true } else { false } }, "gated again once the link drops")
    }

    func testXencelabsDecodesOnlyItsVendorTunnel() throws {
        let profile = try XCTUnwrap(VendorDeviceRegistry.drivableProfile(forVendorID: 0x28BD, productID: 0x520D))
        let spec = TabletSpec(
            productID: 0x520D, name: profile.productName, format: .xencelabs,
            maxX: profile.maxX ?? 0, maxY: profile.maxY ?? 0, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, isPenDisplay: true, seizeUSB: false)
        let input = TabletInput(spec: spec, isBluetooth: false, isWireless: false)
        XCTAssertTrue(input.accepts(usagePage: 0xFF0A))
        XCTAssertFalse(input.accepts(usagePage: 0x0D))
        XCTAssertFalse(input.accepts(usagePage: 0x01))

        let wacom = TabletInput(
            spec: try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x0358)), isBluetooth: false, isWireless: false)
        XCTAssertTrue(wacom.accepts(usagePage: 0x0D), "other formats decode every interface")
    }

    /// The Pen Display's bezel buttons arrive as aux keys 0–2 and also fill
    /// the bezel slots, 16–18.
    func testPenDisplayBezelButtonsFillTheBezelSlots() throws {
        let spec = TabletSpec(
            productID: 0x520D, name: "Xencelabs Pen Display 24", format: .xencelabs,
            maxX: 52_960, maxY: 29_790, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, isPenDisplay: true, seizeUSB: false)
        var input = TabletInput(spec: spec, isBluetooth: false, isWireless: false)
        var frame = [UInt8](repeating: 0, count: 32)
        frame[0] = 0x02
        frame[1] = 0xF0
        frame[2] = 0x02  // key 2
        let pads = feed(&input, frame).events.compactMap { if case .pad(let p) = $0 { p } else { nil } }
        let pad = try XCTUnwrap(pads.first)
        XCTAssertGreaterThanOrEqual(pad.buttons.count, 19)
        XCTAssertEqual(Array(pad.buttons[16..<19]), [false, true, false])
    }
}
