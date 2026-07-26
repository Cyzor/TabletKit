// SPDX-License-Identifier: MPL-2.0
//
// Validation strategy (see Notes/Scratch/HID-Descriptor-Parser-Scoping-2026-07-25.md):
//   1. Fixture corpus with hand-computed offsets (HID spec's boot mouse example).
//   2. Real in-repo descriptor bytes (Xencelabs), checked for a plausible round trip
//      and for the DATAMODE-usage-absent finding rather than exact hand-derived offsets.
//   3. Length round-trip: ceil(totalBits/8) must be a lower bound on the real report length.

import XCTest
@testable import TabletKit

final class HIDReportDescriptorParserTests: XCTestCase {

    // MARK: - Fixture: HID spec boot mouse (no report ID)
    //
    // 3 buttons (1 bit each, variable) + 5 bits constant padding, then relative X/Y
    // (8 bits each). This is the canonical worked example from the HID spec's
    // "Report Descriptor" appendix.

    private let bootMouseHex =
        "05010902a1010901a100050919012903150025019503750181029501750581030501" +
        "093009311581257f750895028106c0c0"

    func testBootMouseFieldOffsetsAndFlags() throws {
        let layout = try HIDReportDescriptorParser.parse(hex: bootMouseHex)
        XCTAssertEqual(layout.reports.count, 1)
        let report = try XCTUnwrap(layout.report(.input, id: 0))
        XCTAssertEqual(report.fields.count, 6)

        let buttons = report.fields.prefix(3)
        for (index, field) in buttons.enumerated() {
            XCTAssertEqual(field.usagePage, 0x09)
            XCTAssertEqual(field.usage, UInt32(index + 1))
            XCTAssertEqual(field.bitOffset, index)
            XCTAssertEqual(field.bitSize, 1)
            XCTAssertTrue(field.isVariable)
            XCTAssertFalse(field.isConstant)
        }

        let padding = report.fields[3]
        XCTAssertTrue(padding.isConstant)
        XCTAssertEqual(padding.bitOffset, 3)
        XCTAssertEqual(padding.bitSize, 5)

        let x = report.fields[4]
        XCTAssertEqual(x.usagePage, 0x01)
        XCTAssertEqual(x.usage, 0x30)
        XCTAssertEqual(x.bitOffset, 8)
        XCTAssertEqual(x.bitSize, 8)
        XCTAssertEqual(x.logicalMin, -127)
        XCTAssertEqual(x.logicalMax, 127)
        XCTAssertTrue(x.isRelative)
        XCTAssertTrue(x.isSigned)

        let y = report.fields[5]
        XCTAssertEqual(y.usagePage, 0x01)
        XCTAssertEqual(y.usage, 0x31)
        XCTAssertEqual(y.bitOffset, 16)

        XCTAssertEqual(report.totalBits, 24)
    }

    func testBootMouseExtractFieldRoundTrip() throws {
        let layout = try HIDReportDescriptorParser.parse(hex: bootMouseHex)
        let report = try XCTUnwrap(layout.report(.input, id: 0))
        // Button 1 + button 3 pressed, X = -5, Y = 10.
        let payload: [UInt8] = [0b0000_0101, UInt8(bitPattern: -5), 10]
        XCTAssertEqual(extractField(report.fields[0], from: payload), 1)
        XCTAssertEqual(extractField(report.fields[1], from: payload), 0)
        XCTAssertEqual(extractField(report.fields[2], from: payload), 1)
        XCTAssertEqual(extractField(report.fields[4], from: payload), -5)
        XCTAssertEqual(extractField(report.fields[5], from: payload), 10)
    }

    // MARK: - Real in-repo descriptor: Xencelabs
    // Notes/Scratch/Discovery-Data-Caputure/mocktab_discovery_0x033E_20260703_004619.json

    private let xencelabsHex =
        "0600ff0980a10185020901150026ff007508953f810385030901150026ff007508953f8103c0"

    func testXencelabsDescriptorParsesWithoutThrowing() throws {
        let layout = try HIDReportDescriptorParser.parse(hex: xencelabsHex)
        XCTAssertFalse(layout.reports.isEmpty)
    }

    /// Length round-trip (validation layer 3): the descriptor's declared bit width,
    /// rounded up to bytes plus the report-ID byte, must be a *lower bound* on the
    /// real captured report length -- not an equality, since padded fixed-size
    /// interrupt reports are normal.
    func testXencelabsDescriptorLengthIsLowerBoundOnCapturedReportLength() throws {
        let layout = try HIDReportDescriptorParser.parse(hex: xencelabsHex)
        // Both reports (0x02, 0x03) are 63 bytes of payload in the real capture.
        let observedReportLength = 64 // includes the report-ID byte
        for report in layout.reports {
            let declaredBytes = (report.totalBits + 7) / 8 + 1 // +1 for report ID byte
            XCTAssertLessThanOrEqual(declaredBytes, observedReportLength,
                                      "report 0x\(String(report.reportID, radix: 16)) declares more bits than the real device emits")
        }
    }

    /// Confirms the reframing finding from the 07-24 scoping doc: the one real descriptor
    /// in the repo doesn't declare the WACOM_HID_WD_DATAMODE usage, so auto-fill won't
    /// fire on Xencelabs hardware. This does not by itself prove the lookup logic is
    /// correct -- see the encoding-specific fixtures below for that.
    func testFeatureReportIDLookupFindsNothingOnXencelabs() throws {
        let layout = try HIDReportDescriptorParser.parse(hex: xencelabsHex)
        XCTAssertNil(layout.featureReportID(carryingUsage: 0xff0d1002))
    }

    // MARK: - Usage-queue drain-then-repeat fallback
    //
    // Usage Page (Generic Desktop), Usage(1), Usage(2), Report Size 8, Report Count 4,
    // Input (Data,Var,Abs): 4 fields declared but only 2 usages queued. Per the HID
    // spec (and this walker's doc comment), the last usage repeats for the remaining
    // slots. Getting this wrong silently mislabels every field after the first array --
    // this was flagged as untested and is exactly the case that needs pinning down.

    func testUsageQueueRepeatsLastUsageWhenExhausted() throws {
        let hex = "050109010902750895048102"
        let layout = try HIDReportDescriptorParser.parse(hex: hex)
        let report = try XCTUnwrap(layout.report(.input, id: 0))
        XCTAssertEqual(report.fields.count, 4)
        XCTAssertEqual(report.fields.map(\.usage), [1, 2, 2, 2])
        XCTAssertEqual(report.fields.map(\.bitOffset), [0, 8, 16, 24])
    }

    // MARK: - DATAMODE feature-report lookup (both usage encodings)
    //
    // No device we can test against declares WACOM_HID_WD_DATAMODE (0xff0d1002), so
    // these fixtures are hand-written from the HID spec's two legal encodings rather
    // than captured. Without them `featureReportID(carryingUsage:)` has no test that
    // could actually fail -- the Xencelabs fixture returns nil regardless of whether
    // the lookup logic is correct, since it never declares a feature report at all.

    /// Encoding 1: `Usage Page (0xFF0D)` (2-byte global) + `Usage (0x1002)` (2-byte local).
    func testFeatureReportIDFindsDatamodeViaUsagePagePlusUsage() throws {
        let hex = "060dff0a0210850275089501b102"
        let layout = try HIDReportDescriptorParser.parse(hex: hex)
        XCTAssertEqual(layout.featureReportID(carryingUsage: 0xff0d1002), 0x02)
    }

    /// Encoding 2: extended (4-byte) `Usage (0xff0d1002)` local item, which carries its
    /// own page in the high 16 bits. Also verifies the item does **not** clobber the
    /// Usage Page global: a 2-byte Usage declared immediately afterward (in a second
    /// feature field on the same report) must still resolve against the unchanged
    /// Usage Page (0x0D), not 0xFF0D.
    func testFeatureReportIDFindsDatamodeViaExtendedUsageWithoutClobberingUsagePage() throws {
        let hex = "050d0b02100dff850375089501b1020901b102"
        let layout = try HIDReportDescriptorParser.parse(hex: hex)
        XCTAssertEqual(layout.featureReportID(carryingUsage: 0xff0d1002), 0x03)

        let report = try XCTUnwrap(layout.report(.feature, id: 0x03))
        XCTAssertEqual(report.fields.count, 2)
        XCTAssertEqual(report.fields[0].usagePage, 0xff0d)
        XCTAssertEqual(report.fields[0].usage, 0x1002)
        XCTAssertEqual(report.fields[1].usagePage, 0x0d, "extended usage item must not overwrite the Usage Page global")
        XCTAssertEqual(report.fields[1].usage, 0x01)
    }

    // MARK: - Error handling

    func testOddHexStringThrows() {
        XCTAssertThrowsError(try HIDReportDescriptorParser.parse(hex: "0")) { error in
            XCTAssertEqual(error as? HIDReportDescriptorParserError, .oddHexString)
        }
    }

    func testTruncatedItemThrows() {
        // Usage Page with a declared 2-byte payload but only 1 byte follows.
        XCTAssertThrowsError(try HIDReportDescriptorParser.parse(hex: "0601")) { error in
            XCTAssertEqual(error as? HIDReportDescriptorParserError, .truncatedItem(offset: 0))
        }
    }

    // MARK: - Push/pop

    func testPushPopRestoresGlobalState() throws {
        // Usage Page (Generic Desktop), Logical Min 0, Push, Logical Min -1, Pop,
        // then emit a 1-bit input field -- logical min should be restored to 0.
        let hex = "05011500a415ffb4950175018102"
        let layout = try HIDReportDescriptorParser.parse(hex: hex)
        let report = try XCTUnwrap(layout.reports.first)
        XCTAssertEqual(report.fields.first?.logicalMin, 0)
    }
}
