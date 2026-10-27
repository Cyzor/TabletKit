// SPDX-License-Identifier: MPL-2.0
//
// TabletInput's effects and gates on paths the report traces don't reach:
// the idle-report resend, a wireless receiver's pairing and link gate, the
// Xencelabs Pen Display, and a PTK-870's missed Bluetooth announcement.
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

    /// Over Bluetooth a PTK-870's announcement usually lands 3 to 8 reports
    /// after the pen enters, and sometimes never. Until it does, no pen is
    /// made up and no init is resent, however long the pen sat idle.
    func testMissedBluetoothAnnouncementAddsNoPen() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x03F9))  // PTK-870
        var input = TabletInput(spec: spec, isBluetooth: true, isWireless: false)
        let inRange: [UInt8] = [0x1A, 0x02, 0x00, 0x80, 0x28, 0x7A, 0xE0, 0xBB, 0x02] + [UInt8](repeating: 0, count: 11)
        let outOfRange: [UInt8] = [0x1A, 0x02, 0x00, 0x00] + [UInt8](repeating: 0, count: 16)
        let announcement: [UInt8] = [0x1A, 0x21, 0x84, 0xC0, 0x01, 0x02, 0x03, 0x04, 0x42, 0x08, 0x10] + [UInt8](repeating: 0, count: 9)
        func tools(_ outputs: [TabletInput.Output]) -> [ToolIdentity] {
            outputs.flatMap(\.events).compactMap {
                if case .tool(let tool) = $0, tool.phase == .enter { return tool.identity } else { return nil }
            }
        }

        var outputs = (0..<12).map { feed(&input, inRange, seconds: 0.005 * Double($0)) }
        XCTAssertEqual(tools(outputs), [])
        XCTAssertTrue(outputs.allSatisfy { $0.effects.isEmpty })

        outputs = [feed(&input, announcement, seconds: 0.1)]
        XCTAssertEqual(tools(outputs).map(\.toolCode), [0x0842])
        XCTAssertEqual(tools(outputs).map(\.serial), [0x0403_0201])

        // Picked up again after a long idle, announcement missed.
        _ = feed(&input, outOfRange, seconds: 1)
        outputs = (0..<12).map { feed(&input, inRange, seconds: 20 + 0.005 * Double($0)) }
        XCTAssertEqual(tools(outputs), [])
        XCTAssertTrue(outputs.allSatisfy { $0.effects.isEmpty })
    }

    /// Over Bluetooth the announcement names the tip's code for either end,
    /// and only close frames carry the eraser bits. The eraser end is named
    /// with its own code and the pen's serial, whichever arrives first, and
    /// high hover keeps it.
    func testBluetoothEraserEndIsNamed() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x03F9))  // PTK-870
        func frame(_ status: UInt8) -> [UInt8] {
            [0x1A, 0x02, 0x00, status, 0x28, 0x7A, 0xE0, 0xBB, 0x02] + [UInt8](repeating: 0, count: 11)
        }
        let far = frame(0x80), closeTip = frame(0xC0), closeEraser = frame(0xE0), out = frame(0x00)
        let announcement: [UInt8] = [0x1A, 0x21, 0x84, 0xC0, 0x01, 0x02, 0x03, 0x04, 0x42, 0x08, 0x10] + [UInt8](repeating: 0, count: 9)
        func run(_ reports: [[UInt8]]) -> [String] {
            var input = TabletInput(spec: spec, isBluetooth: true, isWireless: false)
            return reports.enumerated().flatMap { i, r in
                feed(&input, r, seconds: 0.005 * Double(i)).events.compactMap { event -> String? in
                    switch event {
                    case .tool(let t) where t.phase == .enter:
                        return String(format: "enter %04X %@", t.identity.toolCode, t.identity.isEraser ? "eraser" : "tip")
                    case .pen(let p) where p.inProximity:
                        return p.eraser ? "pen eraser" : "pen tip"
                    default: return nil
                    }
                }
            }
        }
        // Eraser bit after the announcement: the eraser is named before its point.
        XCTAssertEqual(
            run([far, announcement, closeEraser, far, out, far, announcement, closeTip]),
            ["pen tip", "enter 0842 tip", "enter 084A eraser", "pen eraser", "pen eraser",
             "pen tip", "enter 0842 tip", "pen tip"])
        // Eraser bit first: the announcement names the eraser directly.
        XCTAssertEqual(
            run([far, closeEraser, announcement, closeEraser]),
            ["pen tip", "pen eraser", "enter 084A eraser", "pen eraser"])
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

    /// The receiver's battery reading starts on the report after the one
    /// that names the tablet.
    func testReceiverReportsItsTabletsBattery() throws {
        let dongle = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x0084))
        var input = TabletInput(spec: dongle, isBluetooth: false, isWireless: true)
        func battery(_ power: UInt8) -> [DeviceEvent.Battery] {
            feed(&input, [0x80, 0x01, 0xDC, 0x14, 0xB3, power, 0x00, 0x28]).events.compactMap {
                if case .device(let d) = $0 { d.battery } else { nil }
            }
        }
        XCTAssertEqual(battery(0x16), [], "the naming report carries no reading")
        let held = (0..<DongleBatteryWatcher.holdReports).flatMap { _ in battery(0x16).map(\.percent) }
        XCTAssertEqual(held, [70])
        XCTAssertEqual(battery(0x9E).map(\.charging), [true])
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

    /// The 24HD Touch's sensor also declares a standard touch report on
    /// 0x02, the pen's report ID. Registering the sensor must leave the
    /// pen's reports to the pen decoder.
    func testTouchSensorLeavesThePenReportToThePen() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x00F8))  // DTH-2400
        var input = TabletInput(spec: spec, isBluetooth: false, isWireless: false)
        input.register(Sensor(productID: 0x00F6, descriptor: Self.dth2400SensorDescriptor))
        let toolIn: [UInt8] = [0x02, 0xC2, 0x80, 0x2A, 0xB0, 0x77, 0x31, 0x21, 0x60, 0x00]
        let hover: [UInt8] = [0x02, 0xE0, 0x55, 0xF0, 0x33, 0x44, 0x00, 0x00, 0xF0, 0x60]
        _ = feed(&input, toolIn)
        let events = feed(&input, hover).events
        XCTAssertTrue(events.contains { if case .pen = $0 { true } else { false } })
        XCTAssertTrue(input.penInRange)
    }

    private final class Sensor: HIDInterface {
        let productID: Int
        let reportDescriptor: [UInt8]
        init(productID: Int, descriptor hex: String) {
            self.productID = productID
            reportDescriptor = stride(from: 0, to: hex.count, by: 2).map {
                let start = hex.index(hex.startIndex, offsetBy: $0)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
        }
        var vendorID: Int { 0x056A }
        var usagePage: Int { 0x0D }
        var usage: Int { 0x04 }
        var maxOutputReportSize: Int { 0 }
        func setReport(_ kind: HIDReportKind, bytes: [UInt8]) -> IOReturn { kIOReturnUnsupported }
        func getReport(_ kind: HIDReportKind, id: UInt8, length: Int) -> (IOReturn, [UInt8]) { (kIOReturnUnsupported, []) }
        func readString(index: UInt8) -> [UInt8]? { nil }
    }

    private static let dth2400SensorDescriptor =
        "050d0904a10185010922a10209421500250175019501810209328102950681037508095195018102050175109502550e" +
        "651109302640143500464014810246a80c093126a80c8102050d95010948810209498102c0050d0922a1020942150025" +
        "0175019501810209328102950681037508095195018102050175109502550e651109302640143500464014810246a80c" +
        "093126a80c8102050d95010948810209498102c0050d0922a10209421500250175019501810209328102950681037508" +
        "095195018102050175109502550e651109302640143500464014810246a80c093126a80c8102050d9501094881020949" +
        "8102c0050d0922a10209421500250175019501810209328102950681037508095195018102050175109502550e651109" +
        "302640143500464014810246a80c093126a80c8102050d95010948810209498102c0050d27ffffff0f75209501095681" +
        "02095426ff00950175088102851009559502250ab10285110600ff09c5960001b102c0050d090ea10185120923a10209" +
        "5209531500250a75089502b102c0c0050d0904a10185020922a102094215002501750195018102093281029506810375" +
        "08095195018102050175109502550e651109302640143500464014810246a80c093126a80c8102050d95010948810209" +
        "498102c0050d27ffffff0f7520950109568102c005010902a10185030901a10005091901290215002501950275018102" +
        "950175068103050175109501550e651109302640143500464014810246a80c093126a80c8102c0c0"
}
