// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 TabletKit contributors
// SPDX-License-Identifier: MPL-2.0
//
// The MobileStudio Pro's 0x11 pad report. Bit positions come from the
// descriptor fixture in MobileStudioProDescriptorTests, not from this file.
import XCTest
@testable import TabletKit

final class MobileStudioProPadTests: XCTestCase {

    private func spec(_ productID: Int) throws -> DigitizerSpec {
        try XCTUnwrap(WacomDeviceRegistry.spec(for: productID)).digitizerSpec
    }

    private func aux(_ bytes: [UInt8], _ spec: DigitizerSpec) -> AuxButtons? {
        var state = IntuosV2Decoder.State()
        let results = HIDReport.withReport(bytes) { report in
            IntuosV2Decoder().decode(report: report, spec: spec, state: &state, deviceFamily: .intuosProGen2)
        }
        return results.compactMap { r -> AuxButtons? in
            if case .aux(let a) = r { return a } else { return nil }
        }.first
    }

    /// A report with one bit set, `bitOffset` counted from the byte after the ID.
    private func report(settingBit bitOffset: Int?, ring: UInt8 = 0x7F) -> [UInt8] {
        var bytes: [UInt8] = [0x11, 0, 0, 0, ring, 0, 0, 0, 0]
        if let bitOffset { bytes[1 + bitOffset / 8] |= 1 << UInt8(bitOffset % 8) }
        return bytes
    }

    private func fixtureFields() throws -> [DescriptorField] {
        let layout = try HIDReportDescriptorParser.parse(hex: MobileStudioProDescriptorFixtures.pad13)
        return try XCTUnwrap(layout.report(.input, id: 0x11)).fields.filter { !$0.isConstant }
    }

    func testLayoutByModel() throws {
        XCTAssertEqual(try spec(0x034D).intuosV2PadLayout, .mobileStudioPro(keys: 6))
        XCTAssertEqual(try spec(0x0398).intuosV2PadLayout, .mobileStudioPro(keys: 6))
        for pid in [0x034E, 0x0399, 0x03AA] {
            XCTAssertEqual(try spec(pid).intuosV2PadLayout, .mobileStudioPro(keys: 8))
        }
        for pid in [0x0357, 0x0358, 0x0360, 0x0361, 0x0392, 0x03DC] {
            XCTAssertEqual(try spec(pid).intuosV2PadLayout, .intuosPro, String(format: "0x%04X", pid))
        }
    }

    /// Keys plus the four rocker directions, and Device Mode on the touch sensor.
    func testRegistryRows() throws {
        for (pid, count) in [(0x034D, 10), (0x0398, 10), (0x034E, 12), (0x0399, 12), (0x03AA, 12)] {
            let row = try XCTUnwrap(WacomDeviceRegistry.spec(for: pid))
            XCTAssertEqual(row.buttonCount, count, String(format: "0x%04X", pid))
            XCTAssertEqual(row.touchCompanionInitSteps, [.featureReport([0x0E, 0x02, 0x00])])
        }
    }

    /// Keys 1–6 land on buttons 0–5 and the rocker (right, up, left, down)
    /// on 6–9, each alone; the center bit reaches only the ring button.
    func testEachControlBitReachesOnlyItsButton() throws {
        let msp13 = try spec(0x034D)
        let fields = try fixtureFields()
        let keys = fields.filter { (0x0911...0x0916).contains($0.usage) }
        let rocker = [0x0994, 0x0991, 0x0993, 0x0992].compactMap { usage in fields.first { $0.usage == usage } }
        XCTAssertEqual(keys.count, 6)
        XCTAssertEqual(rocker.count, 4)
        for (index, field) in (keys + rocker).enumerated() {
            let pad = try XCTUnwrap(aux(report(settingBit: field.bitOffset), msp13))
            XCTAssertEqual(pad.buttons.count, 10)
            XCTAssertEqual(pad.buttons.indices.filter { pad.buttons[$0] }, [index], String(format: "usage 0x%04X", field.usage))
            XCTAssertFalse(pad.touchRingButtonDown)
        }
        let center = try XCTUnwrap(fields.first { $0.usage == 0x0990 })
        let pad = try XCTUnwrap(aux(report(settingBit: center.bitOffset), msp13))
        XCTAssertTrue(pad.touchRingButtonDown)
        XCTAssertFalse(pad.buttons.contains(true))
    }

    /// Byte 1 bit 0 carries nothing on this model.
    func testUnusedKeyBitIsIgnored() throws {
        let pad = try XCTUnwrap(aux(report(settingBit: 0), try spec(0x034D)))
        XCTAssertFalse(pad.buttons.contains(true))
    }

    /// Ring positions 0–35 read doubled onto 0–70 while the status bit is set.
    func testRingScalesToSeventyTwoSteps() throws {
        let msp13 = try spec(0x034D)
        let fields = try fixtureFields()
        let ring = try XCTUnwrap(fields.first { $0.usage == 0x0138 })
        let status = try XCTUnwrap(fields.first { $0.usage == 0x0139 })
        XCTAssertEqual(ring.bitOffset, 24)
        XCTAssertEqual(status.bitOffset, 31)
        for position in [0, 1, 17, 34, 35] {
            let pad = try XCTUnwrap(aux(report(settingBit: nil, ring: 0x80 | UInt8(position)), msp13))
            XCTAssertTrue(pad.touchRingActive)
            XCTAssertEqual(pad.touchRingPosition, UInt8(position * 2))
        }
        for idle: UInt8 in [0x00, 0x05, 0x7F, 0x80 | 36, 0xFF] {
            let pad = try XCTUnwrap(aux(report(settingBit: nil, ring: idle), msp13))
            XCTAssertFalse(pad.touchRingActive, String(format: "0x%02X", idle))
            XCTAssertEqual(pad.touchRingPosition, 0x7F)
        }
    }

    /// Guessed layout for the 16: eight keys on byte 1 bits 1–7 and byte 2
    /// bit 0, then the rocker on 8–11. No descriptor of the 16 has turned up.
    func testSixteenInchKeysRunIntoByteTwo() throws {
        let msp16 = try spec(0x034E)
        for key in 0..<8 {
            let pad = try XCTUnwrap(aux(report(settingBit: key + 1), msp16))
            XCTAssertEqual(pad.buttons.count, 12)
            XCTAssertEqual(pad.buttons.indices.filter { pad.buttons[$0] }, [key])
        }
        let right = try XCTUnwrap(aux(report(settingBit: 17), msp16))
        XCTAssertEqual(right.buttons.indices.filter { right.buttons[$0] }, [8])
    }

    func testShortReportIsIgnored() throws {
        let msp13 = try spec(0x034D)
        for count in 1..<5 {
            XCTAssertNil(aux(Array(report(settingBit: nil).prefix(count)), msp13))
        }
    }
}
