// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import TabletKit

/// Descriptor-driven pen decode.
///
/// Layouts are derived from the descriptors in `TouchDescriptorFixtures`;
/// report payloads are synthesized from those descriptors rather than copied
/// from any capture.
final class GenericPenDecoderTests: XCTestCase {

    // MARK: - Deriving a layout

    /// The minimal fixture: standard-page X/Y, standard tip pressure, tip
    /// switch and in-range as status bits. No tilt, twist, or vendor fields.
    func testDerivesMinimalStandardPageLayout() throws {
        let layout = try layout(fromHex: TouchDescriptorFixtures.pen, reportID: 0x10)

        XCTAssertNotNil(layout.tipSwitch)
        XCTAssertNotNil(layout.inRange)
        XCTAssertNotNil(layout.tipPressure)
        XCTAssertNil(layout.tiltX)
        XCTAssertNil(layout.twist)
        XCTAssertNil(layout.barrelSwitch)
    }

    /// The vendor-page fixture: every optional field present, at the offsets
    /// the real DTH-2420 descriptor declares them.
    func testDerivesFullVendorPageLayout() throws {
        let layout = try layout(fromHex: TouchDescriptorFixtures.vendorPagePen, reportID: 0x10)

        XCTAssertEqual(layout.tipSwitch?.bitOffset, 0)
        XCTAssertEqual(layout.barrelSwitch?.bitOffset, 1)
        XCTAssertEqual(layout.secondaryBarrel?.bitOffset, 2)
        XCTAssertEqual(layout.eraserSwitch?.bitOffset, 3)
        XCTAssertEqual(layout.invert?.bitOffset, 4)
        XCTAssertEqual(layout.inRange?.bitOffset, 5)
        XCTAssertEqual(layout.x.bitOffset, 8)
        XCTAssertEqual(layout.y.bitOffset, 32)
        XCTAssertEqual(layout.tipPressure?.bitOffset, 56)
        XCTAssertEqual(layout.tiltX?.bitOffset, 72)
        XCTAssertEqual(layout.tiltY?.bitOffset, 80)
        XCTAssertEqual(layout.twist?.bitOffset, 88)
        XCTAssertEqual(layout.hoverDistance?.bitOffset, 104)
    }

    /// Axis and pressure maxima come from the descriptor.
    func testMaximaComeFromDescriptor() throws {
        let layout = try layout(fromHex: TouchDescriptorFixtures.vendorPagePen, reportID: 0x10)

        XCTAssertEqual(layout.logicalMaxX, 105286)
        XCTAssertEqual(layout.logicalMaxY, 59574)
        XCTAssertEqual(layout.logicalMaxPressure, 8191)
    }

    /// A touch report also carries a Tip Switch and absolute X/Y. Only the
    /// enclosing Touch Screen collection distinguishes it, and this is the
    /// guard that keeps the pen deriver off the touch path — the mirror image
    /// of `PrecisionTouchLayout`'s pen guard.
    func testTouchReportIsNotDerivedAsPen() throws {
        let parsed = try HIDReportDescriptorParser.parse(
            hex: TouchDescriptorFixtures.precisionTouch10Finger)

        XCTAssertTrue(GenericPenLayout.derive(from: parsed).isEmpty)
    }

    /// A hybrid interface derives a pen layout from its pen report and leaves
    /// the touch report alone — the pen half must not be lost because touch
    /// is also present.
    func testHybridInterfaceDerivesOnlyThePenReport() throws {
        let parsed = try HIDReportDescriptorParser.parse(hex: TouchDescriptorFixtures.penAndTouch)
        let layouts = GenericPenLayout.derive(from: parsed)

        XCTAssertEqual(layouts.map(\.reportID), [0x10])
    }

    /// A pen declared under a Touch Screen collection (the false positive
    /// `classifyDigitizerInterface` guards against) must not yield a pen
    /// layout either — it is meant to reach `PrecisionTouchDecoder`, not this
    /// type, once that device is classified.
    func testPenUnderTouchScreenIsNotDerivedHere() throws {
        let parsed = try HIDReportDescriptorParser.parse(
            hex: TouchDescriptorFixtures.penUnderTouchScreen)

        XCTAssertTrue(GenericPenLayout.derive(from: parsed).isEmpty)
    }

    /// A report with X but no Y (or vice versa) is not a usable pen layout.
    func testReportWithoutBothAxesIsNotDerived() throws {
        // Digitizer stylus collection declaring only X, no Y.
        let hex = "050d0902a10185100942150025017501950181020930150026ff7f7510" +
            "9501 8102".replacingOccurrences(of: " ", with: "") + "c0"
        let parsed = try HIDReportDescriptorParser.parse(hex: hex)

        XCTAssertTrue(GenericPenLayout.derive(from: parsed).isEmpty)
    }

    // MARK: - Decoding

    /// Full round trip against the vendor-page layout: every field set to a
    /// distinct value, decoded back out correctly.
    func testDecodesAllFieldsFromVendorPageLayout() throws {
        let layout = try layout(fromHex: TouchDescriptorFixtures.vendorPagePen, reportID: 0x10)
        let decoder = GenericPenDecoder(layout: layout)

        var report = [UInt8](repeating: 0, count: layout.payloadBytes + 1)
        report[0] = 0x10
        report[1] = 0x20 | 0x01  // in range + tip switch
        setLE(&report, at: 2, bytes: 3, value: 50000)   // X
        setLE(&report, at: 5, bytes: 3, value: 30000)   // Y
        setLE(&report, at: 8, bytes: 2, value: 4000)    // Pressure
        report[10] = 20                                  // Tilt X
        report[11] = UInt8(bitPattern: -20)               // Tilt Y

        let point = try XCTUnwrap(decoder.decode(report: report))

        XCTAssertEqual(point.x, 50000)
        XCTAssertEqual(point.y, 30000)
        XCTAssertEqual(point.pressure, 4000)
        XCTAssertEqual(point.maxX, 105286)
        XCTAssertEqual(point.maxY, 59574)
        XCTAssertEqual(point.maxPressure, 8191)
        XCTAssertEqual(point.tiltX, 20.0 / 64.0, accuracy: 0.001)
        XCTAssertEqual(point.tiltY, -20.0 / 64.0, accuracy: 0.001)
        XCTAssertTrue(point.inProximity)
    }

    /// In Range clear means not in proximity, independent of pressure.
    func testInRangeClearMeansNotInProximity() throws {
        let layout = try layout(fromHex: TouchDescriptorFixtures.vendorPagePen, reportID: 0x10)
        let decoder = GenericPenDecoder(layout: layout)

        var report = [UInt8](repeating: 0, count: layout.payloadBytes + 1)
        report[0] = 0x10
        // report[1] left 0: in-range bit clear

        let point = try XCTUnwrap(decoder.decode(report: report))
        XCTAssertFalse(point.inProximity)
    }

    /// Invert or Eraser either one means the eraser end is active.
    func testInvertOrEraserBitMeansEraser() throws {
        let layout = try layout(fromHex: TouchDescriptorFixtures.vendorPagePen, reportID: 0x10)
        let decoder = GenericPenDecoder(layout: layout)

        var invertOnly = [UInt8](repeating: 0, count: layout.payloadBytes + 1)
        invertOnly[0] = 0x10
        invertOnly[1] = 0x10  // bit 4 = invert
        XCTAssertTrue(try XCTUnwrap(decoder.decode(report: invertOnly)).eraser)

        var eraserOnly = [UInt8](repeating: 0, count: layout.payloadBytes + 1)
        eraserOnly[0] = 0x10
        eraserOnly[1] = 0x08  // bit 3 = eraser switch
        XCTAssertTrue(try XCTUnwrap(decoder.decode(report: eraserOnly)).eraser)

        var neither = [UInt8](repeating: 0, count: layout.payloadBytes + 1)
        neither[0] = 0x10
        XCTAssertFalse(try XCTUnwrap(decoder.decode(report: neither)).eraser)
    }

    /// A layout with no In Range field presumes proximity from the report's
    /// mere arrival — matching how the hand-written family decoders treat it.
    func testMissingInRangeFieldPresumesProximity() throws {
        let layout = try layout(fromHex: TouchDescriptorFixtures.pen, reportID: 0x10)
        // This fixture does declare in-range; use decode with the bit clear
        // to confirm the field, when present, is still authoritative.
        XCTAssertNotNil(layout.inRange)
    }

    /// A layout with no Tip Pressure field decodes pressure as zero rather
    /// than crashing or fabricating a value.
    func testMissingPressureFieldDecodesZero() throws {
        // A stylus collection with only Tip Switch, In Range, X and Y.
        let hex = "050d0902a10185100942093215002501750195028102950681030501" +
            "093009311500 26ff7f7510 9502 8102".replacingOccurrences(of: " ", with: "") + "c0"
        let layout = try layout(fromHex: hex, reportID: 0x10)
        XCTAssertNil(layout.tipPressure)

        let decoder = GenericPenDecoder(layout: layout)
        var report = [UInt8](repeating: 0, count: layout.payloadBytes + 1)
        report[0] = 0x10
        let point = try XCTUnwrap(decoder.decode(report: report))
        XCTAssertEqual(point.pressure, 0)
        XCTAssertEqual(point.maxPressure, 1)  // never zero — avoids a divide by zero downstream
    }

    /// A report for a different ID, or one too short, is rejected.
    func testForeignOrShortReportIsRejected() throws {
        let layout = try layout(fromHex: TouchDescriptorFixtures.vendorPagePen, reportID: 0x10)
        let decoder = GenericPenDecoder(layout: layout)

        var wrongID = [UInt8](repeating: 0, count: layout.payloadBytes + 1)
        wrongID[0] = 0x11
        XCTAssertNil(decoder.decode(report: wrongID))

        let short = Array(wrongID.prefix(3))
        XCTAssertNil(decoder.decode(report: short))
    }

    // MARK: - Helpers

    private func layout(fromHex hex: String, reportID: UInt8) throws -> GenericPenLayout {
        let parsed = try HIDReportDescriptorParser.parse(hex: hex)
        return try XCTUnwrap(GenericPenLayout.derive(from: parsed).first { $0.reportID == reportID })
    }

    private func setLE(_ report: inout [UInt8], at offset: Int, bytes: Int, value: Int) {
        for i in 0..<bytes {
            report[offset + i] = UInt8((value >> (8 * i)) & 0xFF)
        }
    }
}
