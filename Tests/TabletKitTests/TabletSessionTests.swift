// SPDX-License-Identifier: MPL-2.0
//
// The session against replayed interfaces: routing, holding, grouping,
// receivers, and what reaches the delegate.
import Foundation
import IOKit
import XCTest
@testable import TabletKit

/// Records what a session reports. Replay runs everything on main.
final class RecordingDelegate: TabletSessionDelegate, TabletInputSink, @unchecked Sendable {
    var log: [String] = []
    var lastBatch: [TabletEvent] = []
    var reports = 0
    var unclaimed: [UnclaimedKind] = []
    var serials: [UInt32] = []
    var onAttach: ((TabletTransport) -> Void)?

    func session(_ session: TabletSession, didAttach transport: TabletTransport, to tablet: ConnectedTablet) {
        log.append("attach 0x\(String(transport.rawProductID, radix: 16)) to 0x\(String(tablet.productID, radix: 16))")
        onAttach?(transport)
    }
    func session(_ session: TabletSession, didDetach transport: TabletTransport, from tablet: ConnectedTablet) {
        log.append("detach 0x\(String(transport.rawProductID, radix: 16))")
    }
    func session(_ session: TabletSession, didRegroup transport: TabletTransport, from old: ConnectedTablet, to new: ConnectedTablet) {
        log.append("regroup 0x\(String(old.productID, radix: 16)) to 0x\(String(new.productID, radix: 16))")
    }
    func session(_ session: TabletSession, didRekey tablet: ConnectedTablet, from old: DeviceInstanceKey) {
        log.append("rekey \(old.stringValue) to \(tablet.key.stringValue)")
    }
    func session(_ session: TabletSession, didFindUnclaimed interface: any HIDInterface, as kind: UnclaimedKind) {
        unclaimed.append(kind)
    }
    func session(_ session: TabletSession, transport: TabletTransport, didReadSerial serial: UInt32) {
        serials.append(serial)
    }
    func session(_ session: TabletSession, inputSinkFor transport: TabletTransport) -> any TabletInputSink { self }
    func didDecode(_ events: [TabletEvent], from report: HIDReport, on interface: any HIDInterface, at receivedNs: UInt64) {
        lastBatch += events
    }
    func didReceive(_ report: HIDReport, at receivedNs: UInt64, from interface: any HIDInterface) {
        reports += 1
    }
}

@MainActor
final class TabletSessionTests: XCTestCase {

    private func iface(
        _ productID: Int, page: Int, usage: Int = 1, vendor: Int = 0x056A, transport: String = "USB",
        serial: String? = nil, pairs: [HIDUsagePair]? = nil, descriptor: [UInt8] = []
    ) -> ReplayRecording.Interface {
        var r = ReplayRecording.Interface()
        r.vendorID = vendor
        r.productID = productID
        r.usagePage = page
        r.usage = usage
        r.usagePairs = pairs ?? [HIDUsagePair(page: page, usage: usage)]
        r.transport = transport
        r.serialNumber = serial
        r.reportDescriptor = descriptor
        return r
    }

    private func run(
        _ interfaces: [ReplayRecording.Interface], _ events: [ReplayRecording.Event],
        onAttach: ((TabletTransport) -> Void)? = nil
    ) -> (TabletSession, ReplayBackend, RecordingDelegate) {
        let backend = ReplayBackend(ReplayRecording(interfaces: interfaces, events: events))
        let delegate = RecordingDelegate()
        delegate.onAttach = onAttach
        let session = TabletSession(backend: backend, delegate: delegate)
        session.start()
        backend.play()
        return (session, backend, delegate)
    }

    /// PTH-660 over USB: interface 0x01 waits for the vendor interface, then
    /// joins its transport.
    func testDeferredInterfaceJoinsItsSibling() {
        let (session, backend, delegate) = run(
            [iface(0x0357, page: 0x01, serial: "S1"), iface(0x0357, page: 0xFF00, serial: "S1")],
            [.attach(0), .attach(1)])
        XCTAssertEqual(delegate.log, ["attach 0x357 to 0x357"])
        XCTAssertEqual(session.tablets.count, 1)
        let transport = try! XCTUnwrap(session.tablets.first?.transports.first)
        XCTAssertTrue(transport.primary === backend.interfaces[1])
        XCTAssertEqual(transport.interfaces.count, 2)
        XCTAssertTrue(session.transport(for: backend.interfaces[0]) === transport)
        // The connect sequence writes on the output queue.
        transport.connection.output.drain()
        XCTAssertEqual(backend.interfaces[1].writes.first, "inputMode")
    }

    /// A host sets its controls as soon as it hears of a transport, before
    /// the session opens it. Those writes must still reach the tablet.
    func testControlWritesFromAttachReachTheTablet() throws {
        let (session, backend, _) = run(
            [iface(0x0358, page: 0xFF00, serial: "S1")], [.attach(0)],
            onAttach: { $0.controls.ringLED?.setRingLED(index: 2) })
        let transport = try XCTUnwrap(session.tablets.first?.transports.first)
        transport.connection.output.drain()
        XCTAssertTrue(backend.interfaces[0].writes.contains("feature 32 46 03"), "\(backend.interfaces[0].writes)")
    }

    /// The same tablet over Bluetooth and then USB is one tablet with two
    /// transports, and takes the USB serial.
    func testBluetoothThenUSBIsOneTablet() {
        let (session, _, delegate) = run(
            [iface(0x03FA, page: 0x01, usage: 1, transport: "Bluetooth Low Energy"),
             iface(0x03F9, page: 0x01, serial: "S9")],
            [.attach(0), .attach(1)])
        XCTAssertEqual(session.tablets.count, 1)
        XCTAssertEqual(session.tablets.first?.transports.map(\.rawProductID).sorted(), [0x03F9, 0x03FA])
        XCTAssertEqual(delegate.log.filter { $0.hasPrefix("rekey") }, ["rekey 0x3F9 to 0x3F9#S9"])
    }

    /// A receiver joins the tablet it names, and its later interfaces follow.
    func testReceiverRegroupsOntoItsTablet() {
        let status: [UInt8] = [0x80, 0x01, 0, 0, 0, 0, 0x00, 0x28]
        let (session, backend, delegate) = run(
            [iface(0x0084, page: 0x0D, usage: 2, serial: "R1"), iface(0x0084, page: 0xFF00, serial: "R1")],
            [.attach(0), .report(interface: 0, bytes: status, ns: 1, decoded: nil), .attach(1)])
        XCTAssertEqual(delegate.log, ["attach 0x84 to 0x84", "regroup 0x84 to 0x28"])
        XCTAssertEqual(session.tablets.map(\.productID), [0x28])
        let transport = try! XCTUnwrap(session.tablets.first?.transports.first)
        XCTAssertEqual(transport.pairedProductID, 0x28)
        XCTAssertTrue(session.transport(for: backend.interfaces[1]) === transport, "a later interface follows")
    }

    /// A touch sensor that enumerates first waits for its pen display.
    func testHeldTouchSensorJoinsItsTablet() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x00F8))
        let sensor = try XCTUnwrap(spec.touchCompanionPID)
        let (session, backend, _) = run(
            [iface(sensor, page: 0x0D, usage: 4), iface(0x00F8, page: 0x0D, usage: 2)],
            [.attach(0), .attach(1)])
        XCTAssertEqual(session.tablets.count, 1)
        XCTAssertTrue(session.transport(for: backend.interfaces[0]) === session.tablets[0].transports[0])
    }

    /// A sensor whose tablet never comes routes on its own after the wait.
    func testHeldTouchSensorRoutesAloneAfterTheWait() throws {
        let sensor = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x00F8)?.touchCompanionPID)
        let backend = ReplayBackend(ReplayRecording(interfaces: [iface(sensor, page: 0x0D, usage: 4)], events: [.attach(0)]))
        let delegate = RecordingDelegate()
        let session = TabletSession(backend: backend, delegate: delegate)
        session.heldSensorTimeout = 0.05
        session.start()
        backend.play()
        XCTAssertTrue(delegate.unclaimed.isEmpty && session.tablets.isEmpty, "held")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(delegate.unclaimed.count + session.tablets.count, 1, "routed once the wait ran out")
    }

    func testUnclaimedInterfaces() {
        let pen: [UInt8] = [0x05, 0x0D, 0x09, 0x02, 0xA1, 0x01, 0x05, 0x01, 0x09, 0x30, 0x26, 0xFF, 0x7F,
                            0x75, 0x10, 0x95, 0x01, 0x81, 0x02, 0xC0]
        let (_, _, delegate) = run(
            [iface(0x7777, page: 0x0D, usage: 2, descriptor: pen),
             iface(0x006D, page: 0x01, usage: 6, vendor: 0x256C),
             iface(0x1234, page: 0x0D, usage: 2, vendor: 0x1111, descriptor: pen)],
            [.attach(0), .attach(1), .attach(2)])
        XCTAssertEqual(delegate.unclaimed, [.wacomFallback, .recognizedOnly, .genericDigitizer])
    }

    func testDetachClosesTheTransportAndTablet() {
        let (session, backend, delegate) = run(
            [iface(0x0357, page: 0xFF00, serial: "S1"), iface(0x0357, page: 0x01, serial: "S1")],
            [.attach(0), .attach(1), .detach(1)])
        XCTAssertEqual(delegate.log, ["attach 0x357 to 0x357", "detach 0x357"])
        XCTAssertTrue(session.tablets.isEmpty)
        XCTAssertFalse(backend.interfaces[0].isOpen)
        XCTAssertNil(session.transport(for: backend.interfaces[0]))
    }

    func testBluetoothGhostMouseIsIgnored() {
        let (session, _, delegate) = run(
            [iface(0x03FA, page: 0x01, usage: 2, transport: "Bluetooth Low Energy")], [.attach(0)])
        XCTAssertTrue(session.tablets.isEmpty)
        XCTAssertTrue(delegate.unclaimed.isEmpty)
    }
}
