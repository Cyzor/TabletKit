// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 TabletKit contributors
// SPDX-License-Identifier: MPL-2.0
//
// The MobileStudio Pro 13's pad report, rebuilt from the field layout of its
// own descriptor. That descriptor (0x034D) is in the sysinfo archive attached
// to linuxwacom/input-wacom#58. Per the project's rule, this fixture restates
// those facts in new bytes instead of copying the captured ones.
import XCTest
@testable import TabletKit

enum MobileStudioProDescriptorFixtures {

    /// Report 0x11, nine bytes counting the ID, on vendor page 0xFF0D:
    /// - byte 1, bits 1 to 6: ExpressKeys 1 to 6 (usages 0x0911 to 0x0916)
    /// - byte 3, bit 0: 0x0990 (center); bits 1 to 4: rocker right 0x0994,
    ///   up 0x0991, left 0x0993, down 0x0992
    /// - byte 4, bits 0 to 6: touch ring 0x0138, logical 0 to 35; bit 7:
    ///   ring status 0x0139
    /// The rest of the report is padding.
    static let pad13: String = [
        "060dff0901a101851109 39a100150025017501",
        "95018103 0a11090a12090a13090a14090a15090a1609 95068102",
        "95098103 0a90090a94090a91090a93090a9209 95058102 95038103",
        "0a3801 2523 7507 9501 8102 0a3901 2501 7501 8102",
        "7508 9504 8103 c0c0",
    ].joined().replacingOccurrences(of: " ", with: "")
}

final class MobileStudioProDescriptorTests: XCTestCase {

    private func variableFields(_ report: DescriptorReport) -> [DescriptorField] {
        report.fields.filter { !$0.isConstant }
    }

    func testPadFixtureLayout() throws {
        let layout = try HIDReportDescriptorParser.parse(hex: MobileStudioProDescriptorFixtures.pad13)
        let report = try XCTUnwrap(layout.report(.input, id: 0x11))
        XCTAssertEqual(report.totalBits, 64, "eight bytes after the ID")
        let fields = variableFields(report)
        XCTAssertTrue(fields.allSatisfy { $0.usagePage == 0xFF0D })
        XCTAssertEqual(fields.map(\.usage), [
            0x0911, 0x0912, 0x0913, 0x0914, 0x0915, 0x0916,
            0x0990, 0x0994, 0x0991, 0x0993, 0x0992,
            0x0138, 0x0139,
        ])
        XCTAssertEqual(fields.map(\.bitOffset), [1, 2, 3, 4, 5, 6, 16, 17, 18, 19, 20, 24, 31])
        let ring = fields[11]
        XCTAssertEqual(ring.bitSize, 7)
        XCTAssertEqual(ring.logicalMax, 35)
    }

    /// Checks the fixture against the real descriptor when
    /// TABLETKIT_RECORDINGS holds a file whose name contains "034d" and ends
    /// in .hid.bin. Skips otherwise.
    func testPadFixtureMatchesRealDescriptor() throws {
        let files = PrivateRecordings.descriptors.filter { $0.lastPathComponent.lowercased().contains("034d") }
        try XCTSkipIf(files.isEmpty, "no MobileStudio Pro 13 descriptor in TABLETKIT_RECORDINGS")
        let fixture = try XCTUnwrap(
            HIDReportDescriptorParser.parse(hex: MobileStudioProDescriptorFixtures.pad13).report(.input, id: 0x11))
        for file in files {
            let real = try XCTUnwrap(
                HIDReportDescriptorParser.parse([UInt8](Data(contentsOf: file))).report(.input, id: 0x11),
                file.lastPathComponent)
            XCTAssertEqual(real.totalBits, fixture.totalBits, file.lastPathComponent)
            let shape = { (f: DescriptorField) in [Int(f.extendedUsage), f.bitOffset, f.bitSize, f.logicalMin, f.logicalMax] }
            XCTAssertEqual(variableFields(real).map(shape), variableFields(fixture).map(shape), file.lastPathComponent)
        }
    }
}
