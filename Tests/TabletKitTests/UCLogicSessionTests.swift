// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
//
// The session switching on UC-Logic tablets of the brands it's given.
import Foundation
import IOKit
import XCTest
@testable import TabletKit

@MainActor
final class UCLogicSessionTests: XCTestCase {

    /// The kernel's recorded XP-Pen Deco L answer to string descriptor 100.
    let decoL: [UInt8] = [0x0E, 0x03, 0x70, 0xB2, 0x10, 0x77, 0x08, 0x00, 0xFF, 0x1F, 0xD8, 0x13]
    /// The constructed Huion answer from `UCLogicTabletInfoTests`.
    let huion: [UInt8] = [
        0x12, 0x03, 0x50, 0xC3, 0x00, 0x12, 0x7A, 0x00, 0xFF, 0x1F, 0xD8, 0x13,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    private func iface(
        vendor: Int, product: Int, page: Int, usage: Int = 1, serial: String? = "S1",
        declaresOutput2: Bool = false, strings: [UInt8: [UInt8]] = [:]
    ) -> ReplayRecording.Interface {
        var r = ReplayRecording.Interface()
        r.vendorID = vendor
        r.productID = product
        r.usagePage = page
        r.usage = usage
        r.usagePairs = [HIDUsagePair(page: page, usage: usage)]
        r.transport = "USB"
        r.serialNumber = serial
        if declaresOutput2 {
            r.reportDescriptor = UCLogicTabletInfoTests.outputReport2
            r.maxOutputReportSize = 8
        }
        r.strings = strings
        return r
    }

    private func run(
        _ interfaces: [ReplayRecording.Interface], _ order: [Int], brands: Set<TabletBrand>,
        timeout: TimeInterval = 10
    ) -> (TabletSession, ReplayBackend, RecordingDelegate) {
        let backend = ReplayBackend(ReplayRecording(interfaces: interfaces, events: order.map { .attach($0) }))
        let delegate = RecordingDelegate()
        let session = TabletSession(backend: backend, delegate: delegate)
        session.experimentalTabletBrands = brands
        session.heldSensorTimeout = timeout
        session.start()
        backend.play()
        return (session, backend, delegate)
    }

    private func xpPen(answering: Bool = true) -> [ReplayRecording.Interface] {
        [iface(vendor: 0x28BD, product: 0x0935, page: 0x0D, usage: 2),
         iface(vendor: 0x28BD, product: 0x0935, page: 0xFF0A, declaresOutput2: true,
               strings: answering ? [100: decoL] : [:])]
    }

    /// Only one interface can switch a UGEE tablet on; whichever arrives
    /// first, both end up on one transport, sized from the answer.
    func testUGEETabletSwitchesOnAsOneTransport() throws {
        for order in [[0, 1], [1, 0]] {
            let (session, backend, _) = run(xpPen(), order, brands: [.xpPen])
            let transports = session.tablets.flatMap(\.transports)
            XCTAssertEqual(transports.count, 1, "order \(order)")
            let transport = try XCTUnwrap(transports.first)
            XCTAssertEqual(transport.spec.format, .ucLogic)
            XCTAssertEqual(transport.spec.maxX, 0xB270)
            XCTAssertEqual(transport.spec.buttonCount, 8)
            XCTAssertTrue(transport.primary === backend.interfaces[1], "the interface that answered leads")
            XCTAssertEqual(transport.interfaces.count, 2, "order \(order)")
            XCTAssertNil(transport.guessedAs)
            XCTAssertEqual(
                Array(backend.interfaces[1].writes.prefix(2)), ["output 02 b0 04 00 00 00 00 00", "string 100"])
            XCTAssertTrue(backend.interfaces[0].writes.isEmpty, "no switch-on on an interface that can't take it")
        }
    }

    /// Reports on the switched-on interface decode as pen samples.
    func testReportsDecodeThroughTheSession() throws {
        let report: [UInt8] = [0x02, 0xA1, 0x38, 0x59, 0x88, 0x3B, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00]
        let backend = ReplayBackend(ReplayRecording(
            interfaces: xpPen(), events: [.attach(1), .attach(0), .report(interface: 1, bytes: report, ns: 1, decoded: nil)]))
        let delegate = RecordingDelegate()
        let session = TabletSession(backend: backend, delegate: delegate)
        session.experimentalTabletBrands = [.xpPen]
        session.start()
        backend.play()
        let point = try XCTUnwrap(delegate.lastBatch.compactMap { if case .pen(let p) = $0 { p } else { nil } }.first)
        XCTAssertEqual(point.x, 0x5938)
        XCTAssertEqual(point.y, 0x3B88)
        XCTAssertEqual(point.pressure, 0x1000)
        XCTAssertEqual(point.maxX, 0xB270, "sized from the answer")
    }

    /// The connect sequence switches the tablet on again, and records it.
    func testConnectSequenceSwitchesOnAgain() throws {
        let (session, backend, _) = run(xpPen(), [1, 0], brands: [.xpPen])
        let transport = try XCTUnwrap(session.tablets.first?.transports.first)
        XCTAssertEqual(transport.spec.initSteps, [.outputReport([0x02, 0xB0, 0x04]), .stringDescriptor(100)])
        transport.connection.output.drain()
        XCTAssertEqual(backend.interfaces[1].writes.filter { $0 == "string 100" }.count, 2)
    }

    func testBrandNotChosenIsLeftAlone() {
        let (session, backend, delegate) = run(xpPen(), [0, 1], brands: [.huion])
        XCTAssertTrue(session.tablets.isEmpty)
        XCTAssertEqual(delegate.unclaimed, [.recognizedOnly, .recognizedOnly])
        XCTAssertTrue(backend.interfaces.allSatisfy { $0.writes.isEmpty })
    }

    func testNoBrandsChangesNothing() {
        let (_, backend, delegate) = run(xpPen(), [0, 1], brands: [])
        XCTAssertEqual(delegate.unclaimed, [.recognizedOnly, .recognizedOnly])
        XCTAssertTrue(backend.interfaces.allSatisfy { $0.writes.isEmpty })
    }

    /// A tablet that never answers routes as it would have, after the wait.
    func testNoAnswerRoutesAsUsualAfterTheWait() {
        let (session, _, delegate) = run(xpPen(answering: false), [0, 1], brands: [.xpPen], timeout: 0.05)
        XCTAssertTrue(delegate.unclaimed.isEmpty && session.tablets.isEmpty, "held")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(delegate.unclaimed, [.recognizedOnly, .recognizedOnly])
    }

    /// A held interface that leaves isn't routed later.
    func testHeldInterfaceThatLeavesIsForgotten() {
        let backend = ReplayBackend(ReplayRecording(
            interfaces: xpPen(answering: false), events: [.attach(0), .detach(0)]))
        let delegate = RecordingDelegate()
        let session = TabletSession(backend: backend, delegate: delegate)
        session.experimentalTabletBrands = [.xpPen]
        session.heldSensorTimeout = 0.05
        session.start()
        backend.play()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(delegate.unclaimed.isEmpty && session.tablets.isEmpty)
    }

    /// Xencelabs shares XP-Pen's vendor ID but keeps its own path.
    func testXencelabsKeepsItsOwnPath() throws {
        let (session, backend, _) = run(
            [iface(vendor: 0x28BD, product: 0x520D, page: 0xFF0A, declaresOutput2: true, strings: [100: decoL])],
            [0], brands: Set(TabletBrand.all))
        let transport = try XCTUnwrap(session.tablets.first?.transports.first)
        XCTAssertEqual(transport.spec.format, .xencelabs)
        XCTAssertFalse(backend.interfaces[0].writes.contains("string 100"))
    }

    /// The debug switch reads a Xencelabs pen display as a UGEE tablet,
    /// but leaves Quick Keys alone.
    func testXencelabsCanReadAsUGEE() throws {
        let backend = ReplayBackend(ReplayRecording(
            interfaces: [iface(vendor: 0x28BD, product: 0x520D, page: 0xFF0A, declaresOutput2: true, strings: [100: decoL]),
                         iface(vendor: 0x28BD, product: 0x5202, page: 0xFF0A, serial: "Q1", declaresOutput2: true)],
            events: [.attach(0), .attach(1)]))
        let session = TabletSession(backend: backend, delegate: RecordingDelegate())
        session.readsXencelabsAsUGEE = true
        session.start()
        backend.play()
        let formats = session.tablets.flatMap(\.transports).map(\.spec.format)
        XCTAssertEqual(formats, [.ucLogic, .xencelabs])
        XCTAssertFalse(backend.interfaces[1].writes.contains("string 100"))
    }

    /// Huion and Gaomon share 0x006F; the firmware name says which, and
    /// names the model.
    func testFirmwareNamePicksBrandAndModel() throws {
        let name = Array("HUION_T204_190801".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let tablet = [iface(vendor: 0x256C, product: 0x006F, page: 0xFF00,
                            strings: [201: [UInt8(name.count + 2), 0x03] + name, 200: huion])]

        let (session, backend, _) = run(tablet, [0], brands: [.huion])
        let transport = try XCTUnwrap(session.tablets.first?.transports.first)
        XCTAssertEqual(transport.spec.format, .ucLogic)
        XCTAssertEqual(transport.spec.name, "Huion H950P")
        XCTAssertEqual(transport.spec.maxX, 50000)
        XCTAssertFalse(transport.spec.hasEraser)
        XCTAssertEqual(Array(backend.interfaces[0].writes.prefix(2)), ["string 201", "string 200"])

        let (gaomonOnly, gaomonBackend, _) = run(tablet, [0], brands: [.gaomon])
        XCTAssertNotEqual(gaomonOnly.tablets.first?.transports.first?.spec.format, .ucLogic)
        XCTAssertEqual(gaomonBackend.interfaces[0].writes, ["string 201"], "never switched on")
    }

    // MARK: - Silence

    /// A Huion tablet that switched on, with one tip-down report queued.
    private func huionWithReport() -> (TabletSession, ReplayBackend, RecordingDelegate) {
        let report: [UInt8] = [0x08, 0x81, 0x50, 0xC3, 0x12, 0x7A, 0x00, 0x08, 0x00, 0x00, 0x14, 0x0A]
        let backend = ReplayBackend(ReplayRecording(
            interfaces: [iface(vendor: 0x256C, product: 0x006D, page: 0xFF00, strings: [200: huion])],
            events: [.attach(0), .report(interface: 0, bytes: report, ns: 1, decoded: nil)]))
        let delegate = RecordingDelegate()
        let session = TabletSession(backend: backend, delegate: delegate)
        session.experimentalTabletBrands = [.huion]
        session.start()
        return (session, backend, delegate)
    }

    private func leaves(_ events: [TabletEvent]) -> Int {
        events.filter { if case .pen(let p) = $0 { !p.inProximity } else { false } }.count
    }

    /// Huion tablets never say the pen left. After 100 ms of quiet, the
    /// session says so for them, once.
    func testHuionSilenceMeansThePenLeft() {
        let (session, backend, delegate) = huionWithReport()
        backend.play()
        XCTAssertEqual(session.tablets.first?.transports.first?.spec.format, .ucLogic)
        XCTAssertEqual(leaves(delegate.lastBatch), 0, "not yet")
        // Waiting longer can't add a second leave; a busy runner can't fail it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(leaves(delegate.lastBatch), 1)
    }

    /// A transport that's gone delivers no silence.
    func testNoSilenceAfterTheTransportCloses() {
        let (session, backend, delegate) = huionWithReport()
        backend.play()
        session.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(leaves(delegate.lastBatch), 0)
    }

    /// Tablets that say the pen left get no timer.
    func testUGEEGetsNoSilence() {
        let report: [UInt8] = [0x02, 0xA1, 0x38, 0x59, 0x88, 0x3B, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00]
        let backend = ReplayBackend(ReplayRecording(
            interfaces: xpPen(), events: [.attach(1), .report(interface: 1, bytes: report, ns: 1, decoded: nil)]))
        let delegate = RecordingDelegate()
        let session = TabletSession(backend: backend, delegate: delegate)
        session.experimentalTabletBrands = [.xpPen]
        session.start()
        backend.play()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(leaves(delegate.lastBatch), 0)
    }
}
