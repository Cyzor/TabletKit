// SPDX-License-Identifier: GPL-3.0-or-later
//
// IntuosV3 decoder fixtures (PTK-470/670/870 — Intuos Pro gen3).
//
// 0x1F is still synthesized (no capture exists for it). 0x11 and 0x1E are
// hardware-confirmed against real PTK-870 captures (see IntuosV3Decoder.swift)
// — tests marked "real capture" use bytes taken verbatim from
// `whot/wacom-recordings` (MIT-licensed), not synthesized guesses.
import XCTest
@testable import TabletKit

final class IntuosV3DecoderTests: XCTestCase {

    private let ptk670 = DigitizerSpec(
        maxX: 44704, maxY: 27940, maxPressure: 8191,
        buttonCount: 8, hasTilt: true, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 4)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState,
        family: DeviceFamily = .intuosProGen3
    ) -> [DecodeResult] {
        var decoder = IntuosV3Decoder()
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: ptk670, state: &state, deviceFamily: family)
        }
    }

    // MARK: - Helpers

    /// 14-byte 0x1F standard pen report.
    /// [0]=0x1F [1]=0x01 [2]=status [3..4]=X LE16 [5..6]=Y LE16
    /// [7..8]=pressure LE16 [9]=tiltX [11]=tiltY [13]=hoverDist
    private func make0x1F(
        status: UInt8,
        x: UInt16 = 0,
        y: UInt16 = 0,
        pressure: UInt16 = 0,
        tiltX: Int8 = 0,
        tiltY: Int8 = 0,
        hover: UInt8 = 0
    ) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 14)
        b[0] = 0x1F
        b[1] = 0x01
        b[2] = status
        b[3] = UInt8(x & 0xFF); b[4] = UInt8(x >> 8)
        b[5] = UInt8(y & 0xFF); b[6] = UInt8(y >> 8)
        b[7] = UInt8(pressure & 0xFF); b[8] = UInt8(pressure >> 8)
        b[9]  = UInt8(bitPattern: tiltX)
        b[11] = UInt8(bitPattern: tiltY)
        b[13] = hover
        return b
    }

    /// 20-byte 0x1E extended pen report.
    /// [0]=0x1E [2]=status [3..5]=X 24-bit LE [6..8]=Y 24-bit LE
    /// [9..10]=pressure LE16 [11..12]=tiltX LE i16 [13..14]=tiltY LE i16
    /// [19]=hoverDist
    private func make0x1E(
        status: UInt8,
        x: Int = 0,
        y: Int = 0,
        pressure: UInt16 = 0,
        tiltX: Int16 = 0,
        tiltY: Int16 = 0,
        hover: UInt8 = 0
    ) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 20)
        b[0] = 0x1E
        b[2] = status
        b[3] = UInt8(x & 0xFF); b[4] = UInt8((x >> 8) & 0xFF); b[5] = UInt8((x >> 16) & 0xFF)
        b[6] = UInt8(y & 0xFF); b[7] = UInt8((y >> 8) & 0xFF); b[8] = UInt8((y >> 16) & 0xFF)
        b[9]  = UInt8(pressure & 0xFF); b[10] = UInt8(pressure >> 8)
        b[11] = UInt8(UInt16(bitPattern: tiltX) & 0xFF)
        b[12] = UInt8(UInt16(bitPattern: tiltX) >> 8)
        b[13] = UInt8(UInt16(bitPattern: tiltY) & 0xFF)
        b[14] = UInt8(UInt16(bitPattern: tiltY) >> 8)
        b[19] = hover
        return b
    }

    // MARK: - 0x1F gating

    func testShort0x1FRejected() {
        var st = DecoderState()
        let r = decode([0x1F, 0x01, 0x40], state: &st)
        XCTAssertTrue(r.isEmpty)
    }

    func testWrong0x1FSubtypeRejected() {
        var st = DecoderState()
        // data[1] must be 0x01; other values are unknown.
        var b = make0x1F(status: 0x40)
        b[1] = 0x02
        let r = decode(b, state: &st)
        XCTAssertTrue(r.isEmpty)
    }

    // MARK: - 0x1F pen report: coordinates, pressure, tilt, buttons

    func test0x1FCoordinatesAndPressureDecoded() {
        var st = DecoderState()
        // X=0x1234=4660, Y=0x5678=22136, pressure=0x1FFF=8191
        let b = make0x1F(
            status: 0x40, x: 0x1234, y: 0x5678, pressure: 0x1FFF)
        let r = decode(b, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail("expected .pen") }
        XCTAssertEqual(pt.x, 0x1234)
        XCTAssertEqual(pt.y, 0x5678)
        XCTAssertEqual(pt.pressure, 8191)
        XCTAssertTrue(pt.inProximity)
    }

    func test0x1FTiltNormalizedAgainst127() {
        var st = DecoderState()
        // tiltX = 127 → 1.0; tiltY = -127 → -1.0 (close enough)
        let b = make0x1F(status: 0x40, tiltX: 127, tiltY: -127)
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.tiltX, 1.0, accuracy: 0.001)
        XCTAssertEqual(pt.tiltY, -1.0, accuracy: 0.001)
    }

    func test0x1FPenButtons() {
        var st = DecoderState()
        // bit1=penButton1, bit2=penButton2; both set alongside prox (bit6)
        let b = make0x1F(status: 0x40 | 0x02 | 0x04)
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertTrue(pt.penButton1)
        XCTAssertTrue(pt.penButton2)
    }

    func test0x1FEraserBit() {
        var st = DecoderState()
        // eraser = status bit 5 (0x20), prox bit 6 (0x40)
        let b = make0x1F(status: 0x40 | 0x20)
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertTrue(pt.eraser)
    }

    func test0x1FHoverDistanceDecoded() {
        var st = DecoderState()
        let b = make0x1F(status: 0x40, hover: 42)
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.hoverDistance, 42)
    }

    // MARK: - 0x1F proximity-exit state machine

    func test0x1FProximityExitEmitsCachedStateAndClearsFlag() {
        var st = DecoderState()
        // Enter proximity at a known position.
        let enter = make0x1F(status: 0x40, x: 1000, y: 2000, tiltX: 64, tiltY: -32)
        _ = decode(enter, state: &st)
        XCTAssertTrue(st.prevInProximity)

        // Exit frame: prox bit clear → synthetic exit using cached coords.
        let exit = make0x1F(status: 0x00)
        let r = decode(exit, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertFalse(pt.inProximity)
        XCTAssertEqual(pt.x, 1000)
        XCTAssertEqual(pt.y, 2000)
        XCTAssertFalse(st.prevInProximity)

        // Second exit frame is suppressed.
        let r2 = decode(exit, state: &st)
        XCTAssertTrue(r2.isEmpty)
    }

    // MARK: - 0x1E extended pen report: 24-bit XY, 16-bit tilt, penButton3

    func testShort0x1ERejected() {
        var st = DecoderState()
        let r = decode([0x1E] + [UInt8](repeating: 0, count: 18), state: &st)
        XCTAssertTrue(r.isEmpty)
    }

    func test0x1E24BitXYDecoded() {
        var st = DecoderState()
        // X = 0x123456, Y = 0xABCDEF. Status 0xC0: proximity + tip switch.
        let b = make0x1E(status: 0xC0, x: 0x123456, y: 0x0ABCDE)
        let r = decode(b, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.x, 0x123456)
        XCTAssertEqual(pt.y, 0x0ABCDE)
    }

    func test0x1EHoveringAloneCountsAsInProximity() {
        var st = DecoderState()
        // Status 0x80: proximity set, tip switch clear — hovering must not
        // be treated as an exit.
        let b = make0x1E(status: 0x80, x: 1000, y: 2000)
        let r = decode(b, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertTrue(pt.inProximity)
        XCTAssertEqual(pt.pressure, 0)
        XCTAssertTrue(st.prevInProximity)
    }

    func test0x1ETiltNormalizedAgainstInt16Max() {
        var st = DecoderState()
        let b = make0x1E(status: 0xC0, tiltX: Int16.max, tiltY: Int16.min + 1)
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.tiltX, 1.0, accuracy: 0.001)
        // Int16.min+1 / Int16.max ≈ -1.0 (avoids UB at exact min)
        XCTAssertLessThan(pt.tiltY, -0.99)
    }

    func test0x1EPenButton3FromBit3() {
        var st = DecoderState()
        // bit3 = 0x08 alongside proximity bit7 + tip switch bit6
        let b = make0x1E(status: 0xC0 | 0x08)
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertTrue(pt.penButton3)
        XCTAssertFalse(pt.penButton1)
        XCTAssertFalse(pt.penButton2)
    }

    func test0x1EHoverDistanceFromByte19() {
        var st = DecoderState()
        let b = make0x1E(status: 0xC0, hover: 17)
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.hoverDistance, 17)
    }

    func test0x1EProximityExitCachedCoords() {
        var st = DecoderState()
        _ = decode(make0x1E(status: 0xC0, x: 55000, y: 30000), state: &st)
        let r = decode(make0x1E(status: 0x00), state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertFalse(pt.inProximity)
        XCTAssertEqual(pt.x, 55000)
        XCTAssertEqual(pt.y, 30000)
    }

    // MARK: - 0x1E real-capture fixtures (PTK-870, whot/wacom-recordings)
    //
    // Bytes below are taken verbatim from `pen.pen-strong-vertical.hid`
    // (056a:03f9, MIT-licensed), a straight vertical stroke sweeping from
    // light to full pressure. Each fixture is one representative frame from
    // that recording, not a synthesized guess.

    func testRealCaptureHoverFrameDecodesAsInProximityZeroPressure() {
        var st = DecoderState()
        let b: [UInt8] = [
            0x1E, 0x01, 0x80, 0x51, 0x8B, 0x00, 0x6B, 0x11, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xBA, 0xC8, 0xB3, 0x3A,
        ]
        let r = decode(b, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertTrue(pt.inProximity)
        XCTAssertEqual(pt.pressure, 0)
        XCTAssertEqual(pt.x, 35665)
        XCTAssertEqual(pt.y, 4459)
    }

    func testRealCaptureTouchdownFrameZeroPressureTransient() {
        var st = DecoderState()
        // Momentary zero-pressure frame right at touchdown (0xC0) — real
        // sensor behavior, not a decode bug.
        let b: [UInt8] = [
            0x1E, 0x01, 0xC0, 0xEB, 0x8A, 0x00, 0xC3, 0x11, 0x00, 0x00, 0x00,
            0x21, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x79, 0xAA, 0x87,
            0xC0, 0x24, 0x00, 0x02, 0x10, 0x00, 0x00, 0x02, 0x90, 0xCA, 0xBA, 0x3A,
        ]
        let r = decode(b, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertTrue(pt.inProximity)
        XCTAssertEqual(pt.pressure, 0)
    }

    func testRealCaptureMaxPressureFrameMatchesDeviceCeiling() {
        var st = DecoderState()
        // Pressure reaches exactly 8191, this device's maxPressure.
        let b: [UInt8] = [
            0x1E, 0x01, 0xC1, 0xB4, 0x83, 0x00, 0x75, 0x36, 0x00, 0xFF, 0x1F,
            0x20, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0xAA, 0x87,
            0xC0, 0x24, 0x00, 0x02, 0x10, 0x00, 0x00, 0x02, 0xD4, 0x18, 0x18, 0x3D,
        ]
        let r = decode(b, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertTrue(pt.inProximity)
        XCTAssertEqual(pt.pressure, 8191)
        XCTAssertEqual(pt.x, 33716)
        XCTAssertEqual(pt.y, 13941)
    }

    func testRealCaptureExitFrameClearsProximity() {
        var st = DecoderState()
        _ = decode(
            [
                0x1E, 0x01, 0xC1, 0xB4, 0x83, 0x00, 0x75, 0x36, 0x00, 0xFF,
                0x1F, 0x20, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14,
                0xAA, 0x87, 0xC0, 0x24, 0x00, 0x02, 0x10, 0x00, 0x00, 0x02,
                0xD4, 0x18, 0x18, 0x3D,
            ], state: &st)
        XCTAssertTrue(st.prevInProximity)

        // Recording's terminal frame: status 0x00, pen lifted out of range.
        let exit: [UInt8] = [
            0x1E, 0x01, 0x00, 0x40, 0x82, 0x00, 0x70, 0x8B, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x94, 0x84, 0x58, 0x40,
        ]
        let r = decode(exit, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertFalse(pt.inProximity)
        XCTAssertFalse(st.prevInProximity)
    }

    // MARK: - 0x11 aux report

    func testAuxShortRejectd() {
        var st = DecoderState()
        let r = decode([0x11], state: &st)
        XCTAssertTrue(r.isEmpty)
    }

    func testAuxAllEightExpressKeysDecoded() {
        var st = DecoderState()
        // All 8 express-key bits set, byte [3] (dial buttons) untouched.
        let r = decode([0x11, 0xFF, 0x00, 0x00, 0x00, 0x00], state: &st)
        XCTAssertFalse(r.isEmpty)
        guard case .aux(let aux) = r[0] else { return XCTFail() }
        XCTAssertEqual(aux.buttons.count, 8)
        for i in 0..<8 { XCTAssertTrue(aux.buttons[i], "button \(i) should be set") }
        XCTAssertFalse(aux.touchRingButtonDown)
    }

    func testAuxOnlyOneExpressKeyLit() {
        var st = DecoderState()
        // Real capture (pen.buttons.hid): each key press lights exactly one
        // bit of byte [1] alone. Confirm byte [3] never leaks into buttons[].
        let r = decode([0x11, 0x04, 0x00, 0x00, 0x00, 0x00], state: &st)
        guard case .aux(let aux) = r[0] else { return XCTFail() }
        XCTAssertTrue(aux.buttons[2])
        for i in [0, 1, 3, 4, 5, 6, 7] { XCTAssertFalse(aux.buttons[i]) }
    }

    func testAuxLeftDialCenterPressSurfacedAsTouchRingButtonDown() {
        var st = DecoderState()
        // Real capture (pen.center-buttons.hid): left cluster-center key is
        // byte [3] bit 0, independent of the express-key byte.
        let r = decode([0x11, 0x00, 0x00, 0x01, 0x00, 0x00], state: &st)
        guard case .aux(let aux) = r[0] else { return XCTFail() }
        XCTAssertTrue(aux.touchRingButtonDown)
        for b in aux.buttons { XCTAssertFalse(b) }
    }

    func testAuxRightDialCenterPressDoesNotLeakIntoButtons() {
        var st = DecoderState()
        // Right cluster-center key is byte [3] bit 1 — decoded but not yet
        // surfaced (no touchRing2ButtonDown field exists). Confirm it stays
        // inert rather than accidentally lighting an express key.
        let r = decode([0x11, 0x00, 0x00, 0x02, 0x00, 0x00], state: &st)
        guard case .aux(let aux) = r[0] else { return XCTFail() }
        XCTAssertFalse(aux.touchRingButtonDown)
        for b in aux.buttons { XCTAssertFalse(b) }
    }

    func testAuxLeftWheelPositiveDelta() {
        var st = DecoderState()
        // Left wheel byte[4] = 3 → delta +3
        let r = decode([0x11, 0x00, 0x00, 0x00, 0x03, 0x00], state: &st)
        XCTAssertEqual(r.count, 2)
        guard case .wheel(let idx, let delta) = r[1] else { return XCTFail() }
        XCTAssertEqual(idx, 0)
        XCTAssertEqual(delta, 3)
    }

    func testAuxRightWheelPositiveDelta() {
        var st = DecoderState()
        // Right wheel byte[5] = 5 → delta +5
        let r = decode([0x11, 0x00, 0x00, 0x00, 0x00, 0x05], state: &st)
        XCTAssertEqual(r.count, 2)
        guard case .wheel(let idx, let delta) = r[1] else { return XCTFail() }
        XCTAssertEqual(idx, 1)
        XCTAssertEqual(delta, 5)
    }

    func testAuxWheelNegativeDeltaSign7BitExtension() {
        var st = DecoderState()
        // 7-bit sign extension: (Int8(bitPattern: byte) << 1) >> 1
        // 0xFE → Int8 == -2, << 1 == -4 (Int8), >> 1 == -2 (arithmetic shift).
        // So a raw byte of 0xFE yields delta == -2.
        let r = decode([0x11, 0x00, 0x00, 0x00, 0xFE, 0x00], state: &st)
        guard let wheelResult = r.first(where: { if case .wheel = $0 { return true }; return false }),
              case .wheel(let idx, let delta) = wheelResult else { return XCTFail() }
        XCTAssertEqual(idx, 0)
        XCTAssertEqual(delta, -2)
    }

    func testAuxWheelZeroDeltaSuppressed() {
        var st = DecoderState()
        // Both wheels at 0 → no .wheel results; only .aux
        let r = decode([0x11, 0x00, 0x00, 0x00, 0x00, 0x00], state: &st)
        XCTAssertEqual(r.count, 1)
        if case .aux = r[0] { } else { XCTFail("expected .aux") }
    }

    func testAuxBothWheelsInSameReport() {
        var st = DecoderState()
        let r = decode([0x11, 0x00, 0x00, 0x00, 0x02, 0x03], state: &st)
        // .aux + two .wheel results
        XCTAssertEqual(r.count, 3)
        let wheels = r.compactMap { r -> (Int, Int)? in
            if case .wheel(let i, let d) = r { return (i, d) }; return nil
        }
        XCTAssertEqual(wheels.count, 2)
        XCTAssertTrue(wheels.contains { $0 == (0, 2) })
        XCTAssertTrue(wheels.contains { $0 == (1, 3) })
    }

    // MARK: - Unknown report IDs

    func testUnknownReportIDReturnsEmpty() {
        var st = DecoderState()
        let r = decode([0x10, 0x00, 0x40] + [UInt8](repeating: 0, count: 20), state: &st)
        XCTAssertTrue(r.isEmpty)
    }
}
