// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import TabletKit

final class UCLogicTabletInfoTests: XCTestCase {

    // MARK: - UGEE v2, string descriptor 100
    //
    // Real answers from three tablets, as recorded in the Linux kernel's
    // hid-uclogic tests (commit bf4afc53), with the values the kernel expects.

    /// XP-Pen Deco L: 8 buttons.
    let decoL: [UInt8] = [0x0E, 0x03, 0x70, 0xB2, 0x10, 0x77, 0x08, 0x00, 0xFF, 0x1F, 0xD8, 0x13]
    /// Parblo A610 Pro: 9 buttons and a dial.
    let parbloA610Pro: [UInt8] = [0x0E, 0x03, 0x96, 0xC7, 0xF9, 0x7C, 0x09, 0x01, 0xFF, 0x1F, 0xD8, 0x13]
    /// XP-Pen Deco Pro S: 8 buttons and a mouse-style control.
    let decoProS: [UInt8] = [0x0E, 0x03, 0xC8, 0xB3, 0x34, 0x65, 0x08, 0x02, 0xFF, 0x1F, 0xD8, 0x13]

    func testDecoL() throws {
        let info = try XCTUnwrap(UCLogicTabletInfo(ugeeDescriptor100: decoL))
        XCTAssertEqual(info.tabletProtocol, .ugeeV2)
        XCTAssertEqual(info.maxX, 0xB270)
        XCTAssertEqual(info.maxY, 0x7710)
        XCTAssertEqual(info.maxPressure, 0x1FFF)
        XCTAssertEqual(info.lpi, 5080)
        XCTAssertEqual(info.tabletButtonCount, 8)
    }

    func testParbloA610Pro() throws {
        let info = try XCTUnwrap(UCLogicTabletInfo(ugeeDescriptor100: parbloA610Pro))
        XCTAssertEqual(info.maxX, 0xC796)
        XCTAssertEqual(info.maxY, 0x7CF9)
        XCTAssertEqual(info.tabletButtonCount, 9)
    }

    func testDecoProS() throws {
        let info = try XCTUnwrap(UCLogicTabletInfo(ugeeDescriptor100: decoProS))
        XCTAssertEqual(info.maxX, 0xB3C8)
        XCTAssertEqual(info.maxY, 0x6534)
    }

    /// The kernel's physical sizes are thousandths of an inch: 0x2320 by 0x1770
    /// for the Deco L, which is 228.4 mm by 152.4 mm.
    func testActiveAreaMatchesKernel() throws {
        let info = try XCTUnwrap(UCLogicTabletInfo(ugeeDescriptor100: decoL))
        XCTAssertEqual(try XCTUnwrap(info.activeWidthMM), Double(0x2320) * 0.0254, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(info.activeHeightMM), Double(0x1770) * 0.0254, accuracy: 0.05)
    }

    func testZeroResolutionGivesNoActiveArea() throws {
        var bytes = decoL
        bytes[10] = 0
        bytes[11] = 0
        let info = try XCTUnwrap(UCLogicTabletInfo(ugeeDescriptor100: bytes))
        XCTAssertEqual(info.lpi, 0)
        XCTAssertNil(info.activeWidthMM)
    }

    func testFourteenByteAnswerAddsThirdByteOfX() throws {
        let info = try XCTUnwrap(UCLogicTabletInfo(ugeeDescriptor100: decoL + [0x01, 0x00]))
        XCTAssertEqual(info.maxX, 0x01B270)
    }

    func testShortUGEEAnswerIsRejected() {
        XCTAssertNil(UCLogicTabletInfo(ugeeDescriptor100: Array(decoL.prefix(11))))
        XCTAssertNil(UCLogicTabletInfo(ugeeDescriptor100: []))
    }

    /// Xencelabs Pen Display 24, read from the hardware on 2026-10-01 with
    /// MockTab running. A 14-byte answer, so X has a third byte. Matches the
    /// display's `VendorDeviceRegistry` entry: 105000 by 59000, pressure 8191.
    let xencelabsPenDisplay24: [UInt8] = [
        0x0E, 0x03, 0x28, 0x9A, 0x78, 0xE6, 0x03, 0x00, 0xFF, 0x1F, 0xD8, 0x13, 0x01, 0x00,
    ]

    func testXencelabsPenDisplayAnswer() throws {
        let info = try XCTUnwrap(UCLogicTabletInfo(ugeeDescriptor100: xencelabsPenDisplay24))
        XCTAssertEqual(info.tabletProtocol, .ugeeV2)
        XCTAssertEqual(info.maxX, 105000)
        XCTAssertEqual(info.maxY, 59000)
        XCTAssertEqual(info.maxPressure, 8191)
        XCTAssertEqual(info.lpi, 5080)
        XCTAssertEqual(info.tabletButtonCount, 3)
    }

    /// The tablet's answer and the registry agree on the ranges.
    func testXencelabsAnswerMatchesRegistry() throws {
        let info = try XCTUnwrap(UCLogicTabletInfo(ugeeDescriptor100: xencelabsPenDisplay24))
        let profile = try XCTUnwrap(VendorDeviceRegistry.profile(forProductID: 0x520D))
        XCTAssertEqual(info.maxX, profile.maxX)
        XCTAssertEqual(info.maxY, profile.maxY)
        XCTAssertEqual(info.maxPressure, profile.maxPressure)
    }

    // MARK: - Huion v2, string descriptor 200
    //
    // Constructed, since the kernel's tests have no Huion answer: max X
    // 0x00C350, max Y 0x007A12, pressure 8191, 5080 lines per inch, 2 pen
    // buttons, 8 tablet buttons, no screen buttons, pen-display flag clear.

    let huion: [UInt8] = [
        0x12, 0x03,
        0x50, 0xC3, 0x00,  // max X
        0x12, 0x7A, 0x00,  // max Y
        0xFF, 0x1F,        // pressure
        0xD8, 0x13,        // lines per inch
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
    ]

    func testHuionAnswer() throws {
        let info = try XCTUnwrap(UCLogicTabletInfo(huionDescriptor200: huion))
        XCTAssertEqual(info.tabletProtocol, .huionV2)
        XCTAssertEqual(info.maxX, 50000)
        XCTAssertEqual(info.maxY, 31250)
        XCTAssertEqual(info.maxPressure, 8191)
        XCTAssertEqual(info.lpi, 5080)
        XCTAssertEqual(info.tabletButtonCount, 0)
    }

    /// Byte 13 matches the key count in public recordings of four Huion tablets.
    func testHuionButtonCount() throws {
        var bytes = huion
        bytes[13] = 12
        XCTAssertEqual(UCLogicTabletInfo(huionDescriptor200: bytes)?.tabletButtonCount, 12)
    }

    func testHuionThirdByteOfX() throws {
        var bytes = huion
        bytes[4] = 0x01
        XCTAssertEqual(UCLogicTabletInfo(huionDescriptor200: bytes)?.maxX, 0x01C350)
    }

    func testShortHuionAnswerIsRejected() {
        XCTAssertNil(UCLogicTabletInfo(huionDescriptor200: Array(huion.prefix(17))))
    }

    /// Some tablets answer every unknown string descriptor with their name.
    func testHuionNameInsteadOfAnswerIsRejected() {
        let name = Array("HUION_T176_M1".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        XCTAssertNil(UCLogicTabletInfo(huionDescriptor200: [UInt8(name.count + 2), 0x03] + name))
    }

    // MARK: - Spec

    func testSpecCarriesRangesAndTilt() throws {
        let spec = try XCTUnwrap(UCLogicTabletInfo(ugeeDescriptor100: decoL)).digitizerSpec
        XCTAssertEqual(spec.maxX, 0xB270)
        XCTAssertEqual(spec.maxY, 0x7710)
        XCTAssertEqual(spec.maxPressure, 0x1FFF)
        XCTAssertEqual(spec.buttonCount, 8)
        XCTAssertTrue(spec.hasTilt)
        XCTAssertEqual(spec.tiltMaxDegrees, 60)
        XCTAssertFalse(spec.isPenDisplay)
    }

    // MARK: - The shared pen

    func testSharedPenIsInCatalog() throws {
        let pen = try XCTUnwrap(WacomToolCatalog.spec(forToolCode: 0xE902))
        XCTAssertEqual(pen.buttonCount, 2)
        XCTAssertTrue(pen.hasTilt)
        XCTAssertFalse(pen.hasRotation)
        XCTAssertEqual(pen.eraserToolCode, 0xE90A)
        XCTAssertFalse(WacomToolCatalog.isEraser(toolCode: 0xE902))
        XCTAssertTrue(WacomToolCatalog.isEraser(toolCode: 0xE90A))
        XCTAssertFalse(WacomToolCatalog.isMouse(toolCode: 0xE902))
    }

    /// No family restriction: the pen works on any tablet that reports it.
    func testSharedPenWorksOnAnyFamily() throws {
        let pen = try XCTUnwrap(WacomToolCatalog.spec(forToolCode: 0xE902))
        XCTAssertTrue(pen.isSupported(onFamily: .xencelabs))
        XCTAssertTrue(pen.isSupported(onFamily: nil))
    }

    // MARK: - Silence

    /// Decoders that don't opt in keep today's behavior.
    func testDecodersHaveNoSilenceTimeoutByDefault() {
        var decoder = XencelabsDecoder()
        var state = DecoderState()
        XCTAssertNil(decoder.silenceTimeout)
        let spec = DigitizerSpec(maxX: 100, maxY: 100, maxPressure: 100)
        XCTAssertTrue(
            decoder.decodeSilence(spec: spec, state: &state, deviceFamily: .xencelabs).isEmpty)
    }
}
