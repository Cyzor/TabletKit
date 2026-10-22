// SPDX-License-Identifier: MPL-2.0
//
// The connect sequence against replayed interfaces: which interface takes
// init, what's read back, and what's put back on close.
import Foundation
import IOKit
import XCTest
@testable import TabletKit

@MainActor
final class TabletConnectionTests: XCTestCase {

    /// A vendor-page descriptor that declares one feature report.
    private func declaring(feature id: UInt8) -> [UInt8] {
        [0x06, 0x00, 0xFF, 0x09, 0x01, 0xA1, 0x01, 0x85, id, 0x09, 0x02,
         0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x01, 0xB1, 0x02, 0xC0]
    }

    private func interface(
        productID: Int, usagePage: Int, transport: String = "USB", descriptor: [UInt8] = [],
        replies: [UInt8: [ReplayRecording.Reply]] = [:]
    ) -> ReplayInterface {
        var r = ReplayRecording.Interface()
        r.vendorID = 0x056A
        r.productID = productID
        r.usagePage = usagePage
        r.transport = transport
        r.reportDescriptor = descriptor
        r.featureReplies = replies
        return ReplayInterface(r)
    }

    private final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var _steps: [TabletConnection.ConnectStep] = []
        private var _serial: UInt32?
        var steps: [TabletConnection.ConnectStep] { lock.withLock { _steps } }
        var serial: UInt32? { lock.withLock { _serial } }
        func add(_ s: TabletConnection.ConnectStep) { lock.withLock { _steps.append(s) } }
        func set(_ s: UInt32) { lock.withLock { _serial = s } }
    }

    private func connect(_ primary: ReplayInterface, spec: TabletSpec, seize: Bool = false) -> (TabletConnection, Steps) {
        let connection = TabletConnection(primary: primary, spec: spec, seize: seize)
        let steps = Steps()
        connection.onStep = { steps.add($0) }
        connection.onSerial = { steps.set($0) }
        XCTAssertEqual(connection.open(accepts: { _ in true }, onReport: { _, _, _ in }), kIOReturnSuccess)
        return (connection, steps)
    }

    /// PTK-870 over USB: its vendor interface enumerates first and can't take
    /// DATAMODE, so init waits for the pen interface that declares it.
    func testInitWaitsForTheInterfaceThatDeclaresIt() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x03F9))
        let vendor = interface(productID: 0x03F9, usagePage: 0xFFD1, descriptor: declaring(feature: 0x40))
        let (connection, steps) = connect(vendor, spec: spec)
        connection.output.drain()
        XCTAssertFalse(vendor.writes.contains("feature 02 02"))
        XCTAssertEqual(steps.serial, 0, "no serial from a replay that has none")

        let pen = interface(productID: 0x03F9, usagePage: 0x01, descriptor: declaring(feature: 0x02))
        connection.register(pen)
        connection.output.drain()
        XCTAssertEqual(pen.writes, ["feature 02 02"])
        XCTAssertTrue(connection.capableInterface === pen)
        XCTAssertTrue(steps.steps.contains(.wrote(reportID: 2, value: 2, result: kIOReturnSuccess, usagePage: 0x01)))
    }

    /// Over BLE the same tablet takes DATAMODE on its only interface, and
    /// isn't asked for a serial.
    func testBluetoothLEInitAndNoSerial() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x03F9))
        let ble = interface(productID: 0x03FA, usagePage: 0x01, transport: "Bluetooth Low Energy")
        let (connection, steps) = connect(ble, spec: spec)
        connection.output.drain()
        XCTAssertTrue(connection.isBluetooth)
        XCTAssertEqual(ble.writes, ["feature 02 02"])
        XCTAssertNil(steps.serial)
    }

    /// PTH-860 over USB takes the InputMode switch on every USB interface
    /// and reports the serial it reads.
    func testInputModeOnEachUSBInterfaceAndSerial() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x0358))
        var serialReply = [UInt8](repeating: 0, count: 8)
        serialReply[0] = 0x03
        serialReply[4] = 0x78; serialReply[5] = 0x56; serialReply[6] = 0x34; serialReply[7] = 0x12
        let vendor = interface(productID: 0x0358, usagePage: 0xFF00, replies: [3: [.init(result: 0, bytes: serialReply)]])
        let (connection, steps) = connect(vendor, spec: spec, seize: true)
        let pen = interface(productID: 0x0358, usagePage: 0x01)
        connection.register(pen)
        connection.output.drain()
        XCTAssertTrue(vendor.seized)
        XCTAssertEqual(vendor.writes, ["inputMode"])
        XCTAssertEqual(pen.writes, ["inputMode"])
        XCTAssertEqual(steps.serial, 0x1234_5678)
        guard case .read("hardware serial", 3, kIOReturnSuccess, let reply, _)? =
                steps.steps.first(where: { if case .read("hardware serial", _, _, _, _) = $0 { true } else { false } })
        else { return XCTFail("serial read not reported") }
        XCTAssertEqual(Array(reply[4..<8]), [0, 0, 0, 0], "the reported reply hides the serial")
    }

    /// Intuos4 over USB reads its mode back and resends until it takes.
    func testIntuos4ModeReadBack() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x00B8))
        let primary = interface(
            productID: 0x00B8, usagePage: 0x0D, descriptor: declaring(feature: 0x02),
            replies: [2: [.init(result: 0, bytes: [0x02, 0x00]), .init(result: 0, bytes: [0x02, 0x02])]])
        let (connection, steps) = connect(primary, spec: spec)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !steps.steps.contains(where: { if case .read("mode read-back", _, _, [0x02, 0x02], _) = $0 { true } else { false } }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        connection.output.drain()
        XCTAssertEqual(primary.writes, ["feature 02 02", "feature 02 02"], "init, then one resend")
    }

    /// A Graphire switched out of mouse mode at connect goes back to it on
    /// close, so the pen still moves the cursor after quit.
    func testGraphireReturnsToMouseModeOnClose() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x0013))
        let primary = interface(productID: 0x0013, usagePage: 0x01)
        let (connection, _) = connect(primary, spec: spec)
        connection.output.drain()
        XCTAssertEqual(primary.writes, ["feature 02 02"])
        connection.close()
        XCTAssertEqual(primary.writes, ["feature 02 02", "feature 02 01"])
    }

    /// PTK-x70 keeps its mode on close, and nothing is sent over Bluetooth.
    func testNoMouseModeRestoreForIntuosProGen3OrBluetooth() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x03F9))
        let pen = interface(productID: 0x03F9, usagePage: 0x01, descriptor: declaring(feature: 0x02))
        let (usb, _) = connect(pen, spec: spec)
        usb.output.drain()
        usb.close()
        XCTAssertEqual(pen.writes, ["feature 02 02"])

        let ble = interface(productID: 0x0084, usagePage: 0x0D, transport: "Bluetooth")
        let (bt, _) = connect(ble, spec: try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x0013)))
        bt.output.drain()
        bt.close()
        XCTAssertEqual(ble.writes, [])
    }

    /// A Cintiq's own touch sensor takes its Device Mode write, and gets its
    /// earlier mode back on close.
    func testTouchSensorModeIsSavedAndRestored() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x00F8))
        let companion = try XCTUnwrap(spec.touchCompanionPID)
        let pen = interface(productID: 0x00F8, usagePage: 0x0D, descriptor: declaring(feature: 0x02))
        let (connection, _) = connect(pen, spec: spec, seize: true)
        let sensor = interface(
            productID: companion, usagePage: 0x0D, descriptor: declaring(feature: 0x12),
            replies: [0x12: [.init(result: 0, bytes: [0x12, 0x00])]])
        connection.attachTouchSensor(sensor)
        connection.output.drain()
        XCTAssertEqual(sensor.writes, ["feature 12 02"])
        connection.close()
        XCTAssertEqual(sensor.writes, ["feature 12 02", "feature 12 00"], "the earlier mode goes back")
        XCTAssertFalse(sensor.isOpen)
        XCTAssertFalse(pen.isOpen)
    }
}
