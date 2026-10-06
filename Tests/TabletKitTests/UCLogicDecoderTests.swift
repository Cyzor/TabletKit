// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import TabletKit

/// Reports here are constructed to the layouts in the Linux kernel's
/// hid-uclogic driver, checked against public recordings of Huion tablets.
final class UCLogicDecoderTests: XCTestCase {

    let spec = DigitizerSpec(
        maxX: 0x01FFFF, maxY: 0x01FFFF, maxPressure: 8191, hasTilt: true, tiltMaxDegrees: 60)

    private func decode(
        _ bytes: [UInt8], _ decoder: inout UCLogicDecoder, _ state: inout DecoderState
    ) -> [DecodeResult] {
        HIDReport.withReport(bytes) { report in
            decoder.decode(report: report, spec: spec, state: &state, deviceFamily: .ucLogic)
        }
    }

    private func pens(_ results: [DecodeResult]) -> [TabletPoint] {
        results.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }
    }

    private func toolCodes(_ results: [DecodeResult]) -> [UInt16] {
        results.compactMap { if case .toolEnter(let t) = $0 { return t.toolCode } else { return nil } }
    }

    // MARK: - Huion v2

    /// Tip down at X 0x01C350, Y 0x007A12, pressure 0x0800, tilt 20° and 10°.
    let huionContact: [UInt8] = [
        0x08, 0x81,
        0x50, 0xC3,  // X low bytes
        0x12, 0x7A,  // Y low bytes
        0x00, 0x08,  // pressure
        0x01, 0x00,  // X and Y third bytes
        0x14, 0x0A,  // tilt X, tilt Y
    ]

    func testHuionPenReport() throws {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        let results = decode(huionContact, &decoder, &state)
        XCTAssertEqual(toolCodes(results), [0xE902])
        let pen = try XCTUnwrap(pens(results).first)
        XCTAssertEqual(pen.x, 0x01C350)
        XCTAssertEqual(pen.y, 0x007A12)
        XCTAssertEqual(pen.pressure, 0x0800)
        XCTAssertTrue(pen.inProximity)
        XCTAssertFalse(pen.eraser)
        XCTAssertEqual(pen.tiltX, 20.0 / 60, accuracy: 1e-9)
    }

    /// The kernel reverses tilt Y too.
    func testHuionTiltYIsReversed() throws {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        let pen = try XCTUnwrap(pens(decode(huionContact, &decoder, &state)).first)
        XCTAssertEqual(pen.tiltY, -10.0 / 60, accuracy: 1e-9)
    }

    func testHuionBarrelButtons() throws {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        var bytes = huionContact
        bytes[1] = 0x82
        var pen = try XCTUnwrap(pens(decode(bytes, &decoder, &state)).first)
        XCTAssertTrue(pen.penButton1)
        XCTAssertFalse(pen.penButton2)
        bytes[1] = 0x84
        pen = try XCTUnwrap(pens(decode(bytes, &decoder, &state)).first)
        XCTAssertFalse(pen.penButton1)
        XCTAssertTrue(pen.penButton2)
    }

    /// Announced once on arrival, not on every report.
    func testPenIsAnnouncedOnce() {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        XCTAssertEqual(toolCodes(decode(huionContact, &decoder, &state)), [0xE902])
        XCTAssertEqual(toolCodes(decode(huionContact, &decoder, &state)), [])
    }

    /// Dials and touch strips, 0xF0 and up, aren't decoded yet.
    func testHuionDialReportIsIgnored() {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        var bytes = huionContact
        bytes[1] = 0xF1
        XCTAssertTrue(decode(bytes, &decoder, &state).isEmpty)
    }

    /// With no button count in the spec, all 16 bits are reported.
    func testButtonsWithoutCountReportAllSixteen() throws {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        var bytes = huionContact
        bytes[1] = 0xE0
        bytes[4] = 0x00
        bytes[5] = 0x80
        let results = decode(bytes, &decoder, &state)
        guard results.count == 1, case .aux(let aux) = results[0] else {
            return XCTFail("expected one button report")
        }
        XCTAssertEqual(aux.buttons.count, 16)
        XCTAssertEqual(aux.buttons.indices.filter { aux.buttons[$0] }, [15])
    }

    /// Huion tablets never set the in-range bit, so a hovering pen reads 0x80.
    func testHuionHoverWithoutInRangeBit() throws {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        var bytes = huionContact
        bytes[1] = 0x80
        bytes[6] = 0x00
        bytes[7] = 0x00
        let pen = try XCTUnwrap(pens(decode(bytes, &decoder, &state)).first)
        XCTAssertTrue(pen.inProximity)
        XCTAssertEqual(pen.pressure, 0)
    }

    /// Each key sets one bit, lowest first, up to the spec's button count.
    func testButtonsFollowSpecCount() throws {
        let counted = DigitizerSpec(
            maxX: spec.maxX, maxY: spec.maxY, maxPressure: 8191, buttonCount: 13,
            hasTilt: true, tiltMaxDegrees: 60)
        for index in 0..<13 {
            var decoder = UCLogicDecoder()
            var state = DecoderState()
            var bytes = huionContact
            bytes[1] = 0xE0
            bytes[4] = index < 8 ? UInt8(1 << index) : 0
            bytes[5] = index < 8 ? 0 : UInt8(1 << (index - 8))
            let results = HIDReport.withReport(bytes) { report in
                decoder.decode(report: report, spec: counted, state: &state, deviceFamily: .ucLogic)
            }
            guard results.count == 1, case .aux(let aux) = results[0] else {
                return XCTFail("expected one button report")
            }
            XCTAssertEqual(aux.buttons.count, 13)
            XCTAssertEqual(aux.buttons.indices.filter { aux.buttons[$0] }, [index])
        }
    }

    func testShortHuionReportIsIgnored() {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        XCTAssertTrue(decode(Array(huionContact.prefix(11)), &decoder, &state).isEmpty)
    }

    func testCoordinatesAreClampedToSpec() throws {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        var bytes = huionContact
        bytes[8] = 0x05
        let pen = try XCTUnwrap(pens(decode(bytes, &decoder, &state)).first)
        XCTAssertEqual(pen.x, spec.maxX)
    }

    // MARK: - Silence

    func testNoTimeoutUntilProtocolIsKnown() {
        XCTAssertNil(UCLogicDecoder().silenceTimeout)
        XCTAssertEqual(UCLogicDecoder(protocol: .huionV2).silenceTimeout, 0.1)
        XCTAssertNil(UCLogicDecoder(protocol: .ugeeV2).silenceTimeout)
    }

    func testHuionReportSetsTimeout() {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        _ = decode(huionContact, &decoder, &state)
        XCTAssertEqual(decoder.tabletProtocol, .huionV2)
        XCTAssertEqual(decoder.silenceTimeout, 0.1)
    }

    func testSilenceReportsPenLeavingOnce() throws {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        _ = decode(huionContact, &decoder, &state)
        let left = decoder.decodeSilence(spec: spec, state: &state, deviceFamily: .ucLogic)
        let pen = try XCTUnwrap(pens(left).first)
        XCTAssertFalse(pen.inProximity)
        XCTAssertEqual(pen.pressure, 0)
        XCTAssertEqual(pen.x, 0x01C350)
        XCTAssertTrue(decoder.decodeSilence(spec: spec, state: &state, deviceFamily: .ucLogic).isEmpty)
    }

    func testPenIsAnnouncedAgainAfterSilence() {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        _ = decode(huionContact, &decoder, &state)
        _ = decoder.decodeSilence(spec: spec, state: &state, deviceFamily: .ucLogic)
        XCTAssertEqual(toolCodes(decode(huionContact, &decoder, &state)), [0xE902])
    }

    // MARK: - UGEE v2

    /// In range with the tip down: X 0xB270, Y 0x7710, pressure 0x0FFF, tilt
    /// −5° and 7°. The top three bits of the pressure bytes aren't pressure.
    let ugeeContact: [UInt8] = [
        0x02, 0xA1,
        0x70, 0xB2,  // X
        0x10, 0x77,  // Y
        0xFF, 0xEF,  // pressure, 13 bits
        0xFB, 0x07,  // tilt X, tilt Y
    ]

    func testUGEEPenReport() throws {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        let results = decode(ugeeContact, &decoder, &state)
        XCTAssertEqual(toolCodes(results), [0xE902])
        let pen = try XCTUnwrap(pens(results).first)
        XCTAssertEqual(pen.x, 0xB270)
        XCTAssertEqual(pen.y, 0x7710)
        XCTAssertEqual(pen.pressure, 0x0FFF)
        XCTAssertEqual(pen.tiltX, -5.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(pen.tiltY, 7.0 / 60, accuracy: 1e-9)
        XCTAssertTrue(pen.inProximity)
    }

    /// UGEE tablets report leaving, so they need no timeout.
    func testUGEEReportsLeaving() throws {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        _ = decode(ugeeContact, &decoder, &state)
        XCTAssertNil(decoder.silenceTimeout)
        var bytes = ugeeContact
        bytes[1] = 0x80
        let pen = try XCTUnwrap(pens(decode(bytes, &decoder, &state)).first)
        XCTAssertFalse(pen.inProximity)
        XCTAssertTrue(decode(bytes, &decoder, &state).isEmpty)
    }

    /// Wide tablets put X's third byte at 10. A Xencelabs Pen Display 24
    /// wrapped at 65535 without it.
    func testUGEEWideTabletReadsThirdXByte() throws {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        let pen = try XCTUnwrap(pens(decode(ugeeContact + [0x01, 0x00], &decoder, &state)).first)
        XCTAssertEqual(pen.x, 0x1B270)
    }

    /// Tablets whose X fits in 16 bits don't use byte 10 for X.
    func testUGEENarrowTabletIgnoresByte10() throws {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        let narrow = DigitizerSpec(maxX: 0xFFFF, maxY: 0xFFFF, maxPressure: 8191, hasTilt: true, tiltMaxDegrees: 60)
        let results = HIDReport.withReport(ugeeContact + [0x01, 0x00]) { report in
            decoder.decode(report: report, spec: narrow, state: &state, deviceFamily: .ucLogic)
        }
        XCTAssertEqual(try XCTUnwrap(pens(results).first).x, 0xB270)
    }

    // Status bytes from a Xencelabs Pen Display capture. The slim pen leaves
    // bit 7 clear (20 hover, 21 tip, 24 and 28 buttons, 60 eraser); the
    // 3-button pen sets it (A0, A1, A2, A4, A8, E0, E1).

    func testUGEEPenWithoutBit7IsPen() throws {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        var bytes = ugeeContact
        bytes[1] = 0x21
        let pen = try XCTUnwrap(pens(decode(bytes, &decoder, &state)).first)
        XCTAssertTrue(pen.inProximity)
        XCTAssertGreaterThan(pen.pressure, 0)
    }

    func testUGEEThirdButton() throws {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        var bytes = ugeeContact
        bytes[1] = 0xA8
        let pen = try XCTUnwrap(pens(decode(bytes, &decoder, &state)).first)
        XCTAssertTrue(pen.penButton3)
        XCTAssertFalse(pen.penButton1)
        XCTAssertFalse(pen.penButton2)
    }

    func testUGEEEraser() throws {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        _ = decode(ugeeContact, &decoder, &state)
        var bytes = ugeeContact
        bytes[1] = 0xE1
        let results = decode(bytes, &decoder, &state)
        XCTAssertEqual(toolCodes(results), [0xE90A])
        XCTAssertTrue(try XCTUnwrap(pens(results).first).eraser)
        bytes[1] = 0xC0
        XCTAssertTrue(try XCTUnwrap(pens(decode(bytes, &decoder, &state)).first).eraser)
    }

    func testUGEEBatteryReportIsIgnored() {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        var bytes = ugeeContact
        bytes[1] = 0xF2
        XCTAssertTrue(decode(bytes, &decoder, &state).isEmpty)
    }

    /// Layout from the kernel; the Xencelabs Quick Keys use the same one.
    func testUGEEButtons() throws {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        let bytes: [UInt8] = [0x02, 0xF0, 0x05, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let results = HIDReport.withReport(bytes) { report in
            decoder.decode(
                report: report,
                spec: DigitizerSpec(maxX: 0xFFFF, maxY: 0xFFFF, maxPressure: 8191, buttonCount: 10),
                state: &state, deviceFamily: .ucLogic)
        }
        guard results.count == 1, case .aux(let aux) = results[0] else {
            return XCTFail("expected one button report")
        }
        XCTAssertEqual(aux.buttons.count, 10)
        XCTAssertEqual(aux.buttons.indices.filter { aux.buttons[$0] }, [0, 2, 8])
        XCTAssertFalse(state.prevInProximity, "a button report isn't the pen")
    }

    func testOtherReportIDsAreIgnored() {
        var decoder = UCLogicDecoder()
        var state = DecoderState()
        var bytes = huionContact
        bytes[0] = 0x07
        XCTAssertTrue(decode(bytes, &decoder, &state).isEmpty)
    }
}
