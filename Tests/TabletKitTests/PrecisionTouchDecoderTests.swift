// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import TabletKit

/// Descriptor-driven multitouch decode.
///
/// Layouts are derived from the descriptors in `TouchDescriptorFixtures`;
/// report payloads are synthesized from those descriptors rather than copied
/// from any capture.
final class PrecisionTouchDecoderTests: XCTestCase {

    // MARK: - Deriving a layout

    /// The deriver must find both multitouch reports and no others.
    func testDerivesBothMultitouchReports() throws {
        let layouts = PrecisionTouchLayout.derive(from: try parsedDescriptor())
        XCTAssertEqual(layouts.map(\.reportID), [0x81, 0x88])
    }

    /// Report 0x81: ten 6-byte finger slots, then Scan Time and Contact Count.
    func testDerivesTenFingerSlotsWithCorrectOffsets() throws {
        let layout = try layout(forReportID: 0x81)

        XCTAssertEqual(layout.slots.count, 10)
        XCTAssertEqual(layout.payloadBytes, 63)

        for (index, slot) in layout.slots.enumerated() {
            let base = index * 48
            XCTAssertEqual(slot.tipSwitch?.bitOffset, base, "slot \(index) tip")
            XCTAssertEqual(slot.contactID?.bitOffset, base + 8, "slot \(index) id")
            XCTAssertEqual(slot.x.bitOffset, base + 16, "slot \(index) x")
            XCTAssertEqual(slot.y.bitOffset, base + 32, "slot \(index) y")
            XCTAssertNil(slot.width, "slot \(index) declares no width")
        }

        XCTAssertEqual(layout.scanTime?.bitOffset, 480)
        XCTAssertEqual(layout.contactCount?.bitOffset, 496)
    }

    /// Axis maxima come from the descriptor, not from a transcribed table.
    func testAxisMaximaComeFromDescriptor() throws {
        let layout = try layout(forReportID: 0x81)
        XCTAssertEqual(layout.logicalMaxX, 15360)  // 0x3c00
        XCTAssertEqual(layout.logicalMaxY, 8640)   // 0x21c0
    }

    /// The single-contact variant has one slot, a Tip Switch, no Contact
    /// Identifier and no Contact Count — the shape that exercises both decoder
    /// fallbacks.
    func testDerivesSingleContactVariant() throws {
        let layout = try layout(forReportID: 0x88)

        XCTAssertEqual(layout.slots.count, 1)
        XCTAssertEqual(layout.payloadBytes, 7)
        XCTAssertNotNil(layout.slots[0].tipSwitch)
        XCTAssertNil(layout.slots[0].contactID)
        XCTAssertNil(layout.contactCount)
        XCTAssertEqual(layout.scanTime?.bitOffset, 40)
    }

    /// A pen digitizer report also carries Generic Desktop X/Y and a Tip
    /// Switch. Only the enclosing application collection distinguishes it, so
    /// this is the guard that keeps the deriver off the pen path.
    func testPenDigitizerReportIsNotDerivedAsTouch() throws {
        // Digitizer / Pen application collection (0x0D/0x02) → Stylus (0x0D/0x20),
        // report 0x10: Tip Switch, In Range, X, Y, Tip Pressure.
        let penDescriptor = TouchDescriptorFixtures.pen
        let parsed = try HIDReportDescriptorParser.parse(hex: penDescriptor)

        XCTAssertTrue(PrecisionTouchLayout.derive(from: parsed).isEmpty)
    }

    // MARK: - Decoding

    /// Three fingers down in slots 0–2, the rest clear.
    func testDecodesThreeContacts() throws {
        let layout = try layout(forReportID: 0x81)
        let decoder = PrecisionTouchDecoder(layout: layout)

        var report = emptyReport(0x81, payloadBytes: 63)
        setFinger(&report, slot: 0, down: true, id: 7, x: 1000, y: 2000)
        setFinger(&report, slot: 1, down: true, id: 8, x: 5000, y: 300)
        setFinger(&report, slot: 2, down: true, id: 9, x: 15360, y: 8640)
        report[63] = 3  // Contact Count

        let frame = try XCTUnwrap(decoder.decode(report: report))

        XCTAssertEqual(frame.contacts.count, 3)
        XCTAssertEqual(frame.contacts.map(\.id), [7, 8, 9])
        XCTAssertEqual(frame.contacts[0].x, 1000)
        XCTAssertEqual(frame.contacts[0].y, 2000)
        XCTAssertEqual(frame.contacts[2].x, 15360)
        XCTAssertEqual(frame.contacts[2].y, 8640)
        XCTAssertNil(frame.contacts[0].contactArea)
        XCTAssertEqual(frame.reportedContactCount, 3)
        XCTAssertFalse(frame.contactCountMismatch)
    }

    /// A finger in a later slot with earlier slots clear. This is the case the
    /// contiguous-packing shortcut loses, and the reason every slot is read.
    func testDecodesNonContiguousSlot() throws {
        let layout = try layout(forReportID: 0x81)
        let decoder = PrecisionTouchDecoder(layout: layout)

        var report = emptyReport(0x81, payloadBytes: 63)
        setFinger(&report, slot: 4, down: true, id: 42, x: 700, y: 800)
        report[63] = 1

        let frame = try XCTUnwrap(decoder.decode(report: report))

        XCTAssertEqual(frame.contacts.count, 1)
        XCTAssertEqual(frame.contacts[0].id, 42)
        XCTAssertEqual(frame.contacts[0].x, 700)
        XCTAssertEqual(frame.contacts[0].y, 800)
    }

    /// A lifting finger reports its last position with Tip Switch already
    /// clear. It must not survive into the frame.
    func testLiftingContactIsExcluded() throws {
        let layout = try layout(forReportID: 0x81)
        let decoder = PrecisionTouchDecoder(layout: layout)

        var report = emptyReport(0x81, payloadBytes: 63)
        setFinger(&report, slot: 0, down: true, id: 1, x: 100, y: 100)
        setFinger(&report, slot: 1, down: false, id: 2, x: 4000, y: 4000)
        report[63] = 1

        let frame = try XCTUnwrap(decoder.decode(report: report))

        XCTAssertEqual(frame.contacts.map(\.id), [1])
    }

    /// All fingers up produces an empty frame, which is the "all lifted"
    /// signal the injector's gesture tracker resets on.
    func testAllFingersUpProducesEmptyFrame() throws {
        let layout = try layout(forReportID: 0x81)
        let decoder = PrecisionTouchDecoder(layout: layout)

        let frame = try XCTUnwrap(
            decoder.decode(report: emptyReport(0x81, payloadBytes: 63)))

        XCTAssertTrue(frame.contacts.isEmpty)
        XCTAssertEqual(frame.reportedContactCount, 0)
        XCTAssertFalse(frame.contactCountMismatch)
    }

    /// Contact Count is advisory: a frame whose count undercounts the live Tip
    /// Switches keeps every contact and raises the diagnostic flag.
    func testContactCountDisagreementDoesNotTruncate() throws {
        let layout = try layout(forReportID: 0x81)
        let decoder = PrecisionTouchDecoder(layout: layout)

        var report = emptyReport(0x81, payloadBytes: 63)
        setFinger(&report, slot: 0, down: true, id: 1, x: 10, y: 20)
        setFinger(&report, slot: 1, down: true, id: 2, x: 30, y: 40)
        report[63] = 1  // firmware says one; two are actually down

        let frame = try XCTUnwrap(decoder.decode(report: report))

        XCTAssertEqual(frame.contacts.count, 2)
        XCTAssertTrue(frame.contactCountMismatch)
    }

    /// Scan Time is carried through for future frame-reassembly work.
    func testScanTimeIsCarried() throws {
        let layout = try layout(forReportID: 0x81)
        let decoder = PrecisionTouchDecoder(layout: layout)

        var report = emptyReport(0x81, payloadBytes: 63)
        report[61] = 0x34
        report[62] = 0x12

        let frame = try XCTUnwrap(decoder.decode(report: report))

        XCTAssertEqual(frame.scanTime, 0x1234)
    }

    /// On the single-contact report there is no Contact Identifier, so the
    /// slot index stands in as a stable id.
    func testSingleContactVariantUsesSlotIndexAsID() throws {
        let layout = try layout(forReportID: 0x88)
        let decoder = PrecisionTouchDecoder(layout: layout)

        var report = emptyReport(0x88, payloadBytes: 7)
        report[1] = 0x01                 // Tip Switch
        report[2] = 0x10; report[3] = 0x27  // X = 10000
        report[4] = 0x20; report[5] = 0x03  // Y = 800

        let frame = try XCTUnwrap(decoder.decode(report: report))

        XCTAssertEqual(frame.contacts.count, 1)
        XCTAssertEqual(frame.contacts[0].id, 0)
        XCTAssertEqual(frame.contacts[0].x, 10000)
        XCTAssertEqual(frame.contacts[0].y, 800)
        XCTAssertNil(frame.reportedContactCount)
    }

    // MARK: - Report rejection

    /// A report for a different ID is not this layout's business.
    func testForeignReportIDIsRejected() throws {
        let decoder = PrecisionTouchDecoder(layout: try layout(forReportID: 0x81))
        var report = emptyReport(0x81, payloadBytes: 63)
        report[0] = 0x88

        XCTAssertNil(decoder.decode(report: report))
    }

    /// A truncated report is rejected rather than read past its end.
    func testShortReportIsRejected() throws {
        let decoder = PrecisionTouchDecoder(layout: try layout(forReportID: 0x81))
        let short = Array(emptyReport(0x81, payloadBytes: 63).prefix(40))

        XCTAssertNil(decoder.decode(report: short))
    }

    // MARK: - Deriver robustness

    /// An unrecognized per-finger field (here Digitizer Confidence) must not
    /// split a slot — otherwise every finger would yield two half-formed ones.
    func testUnknownPerFingerFieldDoesNotSplitSlots() throws {
        // Touch Screen → two Finger collections, each: Tip Switch, Confidence,
        // 6 pad bits, Contact Identifier, X, Y.
        let hex = "050d0904a10185900922a1020942150025017501950181020947950181029506810309517508950181020501150026ff7f7510093095018102093195018102c0050d0922a1020942150025017501950181020947950181029506810309517508950181020501150026ff7f7510093095018102093195018102c0c0"
        let parsed = try HIDReportDescriptorParser.parse(hex: hex)
        let layout = try XCTUnwrap(PrecisionTouchLayout.derive(from: parsed).first)

        XCTAssertEqual(layout.slots.count, 2)
        XCTAssertEqual(layout.slots[0].x.bitOffset, 16)
        XCTAssertEqual(layout.slots[1].x.bitOffset, 64)
    }

    // MARK: - Helpers

    private func parsedDescriptor() throws -> DescriptorLayout {
        try HIDReportDescriptorParser.parse(hex: TouchDescriptorFixtures.precisionTouch10Finger)
    }

    private func layout(forReportID id: UInt8) throws -> PrecisionTouchLayout {
        let layouts = PrecisionTouchLayout.derive(from: try parsedDescriptor())
        return try XCTUnwrap(layouts.first { $0.reportID == id })
    }

    /// A zeroed report with the ID byte set: all fingers up.
    private func emptyReport(_ id: UInt8, payloadBytes: Int) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: payloadBytes + 1)
        report[0] = id
        return report
    }

    /// Writes one 6-byte finger record of report 0x81 (little-endian X/Y).
    private func setFinger(
        _ report: inout [UInt8], slot: Int, down: Bool, id: UInt8, x: Int, y: Int
    ) {
        let base = 1 + slot * 6
        report[base] = down ? 0x01 : 0x00
        report[base + 1] = id
        report[base + 2] = UInt8(x & 0xFF)
        report[base + 3] = UInt8((x >> 8) & 0xFF)
        report[base + 4] = UInt8(y & 0xFF)
        report[base + 5] = UInt8((y >> 8) & 0xFF)
    }
}
