// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import TabletKit

/// A tablet the registry doesn't know, decoded from its own descriptor
/// through `TabletInput`.
final class DescriptorPenDecoderTests: XCTestCase {

    // MARK: - The spec

    func testSpecComesFromTheFirstPenReport() throws {
        let spec = try XCTUnwrap(
            TabletSpec.described(by: bytes(TouchDescriptorFixtures.vendorPagePen), productID: 0x1234, name: "Pen"))
        XCTAssertEqual(spec.format, .descriptor)
        XCTAssertEqual(spec.family, .descriptor)
        XCTAssertEqual(spec.maxX, 105286)
        XCTAssertEqual(spec.maxY, 59574)
        XCTAssertEqual(spec.maxPressure, 8191)
        XCTAssertTrue(spec.hasTilt)
        XCTAssertTrue(spec.hasEraser)
        XCTAssertFalse(spec.hasFingerTouch)
        XCTAssertFalse(spec.seizeUSB)
    }

    func testNoSpecWithoutAPenReport() {
        XCTAssertNil(TabletSpec.described(by: bytes(TouchDescriptorFixtures.precisionTouch10Finger), productID: 1, name: "T"))
        XCTAssertNil(TabletSpec.described(by: [], productID: 1, name: "T"))
    }

    // MARK: - Through TabletInput

    func testDecodesOnlyOnceTheInterfaceRegisters() throws {
        var input = try makeInput(TouchDescriptorFixtures.vendorPagePen)
        XCTAssertTrue(feed(&input, penReport(status: 0x20)).isEmpty)

        input.register(Described(TouchDescriptorFixtures.vendorPagePen))
        XCTAssertEqual(kinds(feed(&input, penReport(status: 0x20))), ["enter", "pen"])
    }

    /// Enter on coming into range, points while in range, then leave.
    func testAnnouncesEnterAndLeave() throws {
        var input = try makeInput(TouchDescriptorFixtures.vendorPagePen)
        input.register(Described(TouchDescriptorFixtures.vendorPagePen))

        let enter = feed(&input, penReport(status: 0x21, x: 50000, y: 30000, pressure: 4000))
        XCTAssertEqual(kinds(enter), ["enter", "pen"])
        guard case .tool(let tool) = enter[0] else { return XCTFail() }
        XCTAssertEqual(tool.identity.toolCode, 0xE902)
        guard case .pen(let point) = enter[1] else { return XCTFail() }
        XCTAssertEqual(point.x, 50000)
        XCTAssertEqual(point.pressure, 4000)
        XCTAssertTrue(input.penInRange)

        XCTAssertEqual(kinds(feed(&input, penReport(status: 0x20))), ["pen"])
        XCTAssertEqual(kinds(feed(&input, penReport(status: 0x00))), ["pen", "leave"])
        XCTAssertFalse(input.penInRange)
    }

    /// Reports the descriptor doesn't declare as a pen decode to nothing.
    func testOtherReportsDecodeToNothing() throws {
        var input = try makeInput(TouchDescriptorFixtures.vendorPagePen)
        input.register(Described(TouchDescriptorFixtures.vendorPagePen))
        XCTAssertTrue(feed(&input, [0x11, 0xFF, 0xFF]).isEmpty)
        XCTAssertTrue(feed(&input, []).isEmpty)
    }

    /// A pen interface that joins after a touch-only primary still decodes.
    func testSiblingInterfaceAddsItsPenReports() throws {
        var input = try makeInput(TouchDescriptorFixtures.vendorPagePen)
        input.register(Described(TouchDescriptorFixtures.precisionTouch10Finger))
        XCTAssertTrue(feed(&input, penReport(status: 0x20)).isEmpty)
        input.register(Described(TouchDescriptorFixtures.vendorPagePen))
        XCTAssertEqual(kinds(feed(&input, penReport(status: 0x20))), ["enter", "pen"])
    }

    /// A descriptor with no report IDs: every report is the pen report.
    func testDescriptorWithoutReportIDs() throws {
        let hex = "050d0902a1010942093215002501750195028102950681030501"
            + "09300931150026ff7f751095028102c0"
        var input = try makeInput(hex)
        input.register(Described(hex))
        let events = feed(&input, [0b11, 0xD2, 0x04, 0x2E, 0x16])
        XCTAssertEqual(kinds(events), ["enter", "pen"])
        guard case .pen(let point) = events[1] else { return XCTFail() }
        XCTAssertEqual(point.x, 1234)
        XCTAssertEqual(point.y, 5678)
        XCTAssertEqual(point.normalizedPressure, 1)
    }

    // MARK: - Helpers

    private final class Described: HIDInterface {
        let reportDescriptor: [UInt8]
        init(_ hex: String) { reportDescriptor = DescriptorPenDecoderTests.bytes(hex) }
        var vendorID: Int { 0x1234 }
        var productID: Int { 0x5678 }
        var usagePage: Int { 0x0D }
        var usage: Int { 0x02 }
        var maxOutputReportSize: Int { 0 }
        func setReport(_ kind: HIDReportKind, bytes: [UInt8]) -> IOReturn { kIOReturnUnsupported }
        func getReport(_ kind: HIDReportKind, id: UInt8, length: Int) -> (IOReturn, [UInt8]) { (kIOReturnUnsupported, []) }
        func readString(index: UInt8) -> [UInt8]? { nil }
    }

    private func makeInput(_ hex: String) throws -> TabletInput {
        let spec = try XCTUnwrap(TabletSpec.described(by: Self.bytes(hex), productID: 0x5678, name: "Pen"))
        return TabletInput(spec: spec, isBluetooth: false, isWireless: false)
    }

    /// A report for the vendor-page fixture, report 0x10.
    private func penReport(status: UInt8, x: Int = 0, y: Int = 0, pressure: Int = 0) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 15)
        report[0] = 0x10
        report[1] = status
        for i in 0..<3 { report[2 + i] = UInt8((x >> (8 * i)) & 0xFF) }
        for i in 0..<3 { report[5 + i] = UInt8((y >> (8 * i)) & 0xFF) }
        for i in 0..<2 { report[8 + i] = UInt8((pressure >> (8 * i)) & 0xFF) }
        return report
    }

    private func feed(_ input: inout TabletInput, _ bytes: [UInt8]) -> [TabletEvent] {
        HIDReport.withReport(bytes) { input.handle($0, at: 1).events }
    }

    private func kinds(_ events: [TabletEvent]) -> [String] {
        events.map {
            switch $0 {
            case .tool(let t): t.phase == .enter ? "enter" : "leave"
            case .pen: "pen"
            default: "other"
            }
        }
    }

    fileprivate static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    private func bytes(_ hex: String) -> [UInt8] { Self.bytes(hex) }
}
