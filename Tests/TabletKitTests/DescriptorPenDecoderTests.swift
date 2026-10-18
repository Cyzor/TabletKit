// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import TabletKit

/// Tablets the registry doesn't know, through `TabletInput`: read from
/// their own descriptor, or a guess for an unknown Wacom.
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

    // MARK: - An unknown Wacom

    func testUnknownWacomFamilyFromReportSize() {
        let v2 = TabletSpec.guessed(
            forUnknownWacom: 0x9999, name: "W", maxInputReportSize: 192, descriptor: bytes(TouchDescriptorFixtures.opaqueVendor))
        XCTAssertEqual(v2.format, .intuosV2)
        XCTAssertEqual([v2.maxX, v2.maxY, v2.maxPressure], [44800, 29600, 8191])
        XCTAssertEqual(v2.initSteps, [.featureReport([0x02, 0x02])])
        XCTAssertTrue(v2.quirks.readsDescriptorPens)
        XCTAssertTrue(v2.quirks.inputModeWriteOverUSB, "keeps its family's quirks")

        let v1 = TabletSpec.guessed(forUnknownWacom: 0x9999, name: "W", maxInputReportSize: 10, descriptor: [])
        XCTAssertEqual(v1.format, .intuosV1)
        XCTAssertEqual(v1.maxPressure, 1023)
    }

    func testUnknownWacomRangesAndInitFromDescriptor() {
        let dataMode = "060dff0901a10185400a02101500250275089501b102c0"
        let spec = TabletSpec.guessed(
            forUnknownWacom: 0x9999, name: "W", maxInputReportSize: 26,
            descriptor: bytes(TouchDescriptorFixtures.vendorPagePen + dataMode))
        XCTAssertEqual([spec.maxX, spec.maxY, spec.maxPressure], [105286, 59574, 8191])
        XCTAssertEqual(spec.initSteps, [.featureReport([0x40, 0x02])])
    }

    /// The native pen report sets the range, not the HID-mode one that
    /// comes first at a coarser resolution over the same 349 mm. Unknown
    /// Wacoms and other described tablets pick alike.
    func testSpecsTakeNativePenRange() throws {
        func pen(id: String, size: String, maxX: String, maxY: String, pressure: String) -> String {
            "050d0902a10185" + id + "0920a1000942150025017501950181027507810305010930"
                + "6511550d3500475488000015007510" + size + "27" + maxX + "8102"
                + "0931472c4c000027" + maxY + "8102050d093026" + pressure + "75108102c0c0"
        }
        let hidMode = pen(id: "06", size: "", maxX: "ff7f0000", maxY: "ff7f0000", pressure: "ff0f")
        let native = pen(id: "10", size: "7518", maxX: "a8100100", maxY: "58980000", pressure: "ff1f")
        let parsed = try HIDReportDescriptorParser.parse(hex: hidMode + native)
        XCTAssertEqual(GenericPenLayout.derive(from: parsed).map(\.logicalMaxX), [32767, 69800])
        let spec = TabletSpec.guessed(
            forUnknownWacom: 0x9999, name: "W", maxInputReportSize: 26, descriptor: bytes(hidMode + native))
        XCTAssertEqual([spec.maxX, spec.maxY, spec.maxPressure], [69800, 39000, 8191])
        let described = try XCTUnwrap(TabletSpec.described(by: bytes(hidMode + native), productID: 0x5678, name: "Pen"))
        XCTAssertEqual([described.maxX, described.maxY, described.maxPressure], [69800, 39000, 8191])
    }

    /// A relative mouse's X/Y is no tablet's range.
    func testUnknownWacomIgnoresRelativeMouseRange() {
        let mouse = "05010902a10185010901a100050919012903150025019503750181029505810305010930093109381581257f750895038106c0c0"
        let spec = TabletSpec.guessed(forUnknownWacom: 0x9999, name: "W", maxInputReportSize: 10, descriptor: bytes(mouse))
        XCTAssertEqual([spec.maxX, spec.maxY], [44704, 27940])
    }

    /// With an opaque descriptor, the guess decodes as the registry entry
    /// for the same family does.
    func testUnknownIntuosV2DecodesLikeTheRegistry() throws {
        let registry = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x0357))  // PTH-660
        let guessed = TabletSpec.guessed(
            forUnknownWacom: 0x9999, name: "W", maxInputReportSize: 192, descriptor: bytes(TouchDescriptorFixtures.opaqueVendor))
        var known = TabletInput(spec: registry, isBluetooth: false, isWireless: false)
        var unknown = TabletInput(spec: guessed, isBluetooth: false, isWireless: false)
        unknown.register(Described(TouchDescriptorFixtures.opaqueVendor))

        var report = [UInt8](repeating: 0, count: 192)
        report[0] = 0x10
        report[1] = 0x60
        report[2] = 0x34; report[3] = 0x12          // X 0x1234
        report[5] = 0x78; report[6] = 0x05          // Y 0x0578
        report[17] = 0x11; report[18] = 0x22         // serial
        report[21] = 0x42; report[22] = 0x08         // Pro Pen 2
        let a = feed(&known, report), b = feed(&unknown, report)
        XCTAssertEqual(kinds(a), ["enter", "pen"])
        XCTAssertEqual(kinds(b), kinds(a))
        guard case .tool(let ta) = a[0], case .tool(let tb) = b[0],
            case .pen(let pa) = a[1], case .pen(let pb) = b[1]
        else { return XCTFail() }
        XCTAssertEqual(tb.identity, ta.identity)
        XCTAssertEqual([pb.x, pb.y, pb.pressure], [pa.x, pa.y, pa.pressure])
    }

    /// A pen report the descriptor declares skips the family guess.
    func testUnknownWacomReadsDescribedPenReportsFirst() throws {
        let spec = TabletSpec.guessed(
            forUnknownWacom: 0x9999, name: "W", maxInputReportSize: 26, descriptor: bytes(TouchDescriptorFixtures.vendorPagePen))
        XCTAssertEqual(spec.format, .intuosV1)
        var input = TabletInput(spec: spec, isBluetooth: false, isWireless: false)
        input.register(Described(TouchDescriptorFixtures.vendorPagePen))

        let events = feed(&input, penReport(status: 0x21, x: 50000, y: 30000, pressure: 4000))
        XCTAssertEqual(kinds(events), ["enter", "pen"])
        guard case .pen(let point) = events[1] else { return XCTFail() }
        XCTAssertEqual(point.x, 50000)
        XCTAssertEqual(point.pressure, 4000)
        XCTAssertTrue(input.penInRange)
        XCTAssertEqual(kinds(feed(&input, penReport(status: 0x00))), ["pen", "leave"])
        XCTAssertFalse(input.penInRange)
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
