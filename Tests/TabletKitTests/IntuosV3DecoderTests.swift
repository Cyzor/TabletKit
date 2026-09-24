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

    /// Every 0x1A BLE fixture below is a verbatim PTK-870 capture, and the
    /// report carries raw device units — so those tests must assert against
    /// the PTK-870's own registry extents, not the PTK-670 spec the rest of
    /// this file uses.
    private let ptk870 = DigitizerSpec(
        maxX: 69800, maxY: 39000, maxPressure: 8191,
        buttonCount: 8, hasTilt: true, hasDualRings: true,
        isPenDisplay: false, ringSlotCount: 4, tiltMaxDegrees: 64.0)

    /// CTC-4110WL (Wacom One S). Registry extents — see `WacomDeviceRegistry`.
    private let ctc4110wl = DigitizerSpec(maxX: 15200, maxY: 9500, maxPressure: 4095)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState,
        family: DeviceFamily = .intuosProGen3, spec: DigitizerSpec? = nil
    ) -> [DecodeResult] {
        let decoder = IntuosV3Decoder()
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: spec ?? ptk670, state: &state, deviceFamily: family)
        }
    }

    private func decodeBLE(_ bytes: [UInt8], state: inout DecoderState) -> [DecodeResult] {
        let decoder = IntuosV3Decoder()
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: ptk870, state: &state, deviceFamily: .intuosProGen3)
        }
    }

    private func pens(_ results: [DecodeResult]) -> [TabletPoint] {
        results.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }
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
        rotation: Int16 = 0,
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
        b[15] = UInt8(UInt16(bitPattern: rotation) & 0xFF)
        b[16] = UInt8(UInt16(bitPattern: rotation) >> 8)
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

    func test0x1ETiltNormalizedAgainst64Degrees() {
        // A real Movink 13 capture (2026-09-08) shows raw tilt only ever
        // spans -64...63 — the field is already in degrees, not a 16-bit
        // fraction. 64 → 1.0, -64 → -1.0.
        var st = DecoderState()
        let b = make0x1E(status: 0xC0, tiltX: 64, tiltY: -64)
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.tiltX, 1.0, accuracy: 0.001)
        XCTAssertEqual(pt.tiltY, -1.0, accuracy: 0.001)
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

    /// Real frame from `ptk-870-usb-groove-all.txt`, a four-edge trace of the
    /// moulded groove over USB. The wired path has the same out-of-bounds
    /// problem as Bluetooth — the pen keeps being reported from beyond the
    /// drawable area — and states it plainly: hover distance railed at 255,
    /// at the rim, with nothing touching. It must produce no position.
    func testRealCaptureUSBGrooveSuppressed() {
        var st = DecoderState()
        let b: [UInt8] = [
            0x1E, 0x01, 0x80, 0x86, 0x0E, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x47, 0x5C, 0x31,
        ]
        XCTAssertEqual(b[19], 255, "premise: hover distance railed")
        XCTAssertTrue(
            decode(b, state: &st).compactMap { if case .pen = $0 { return true } else { return nil } }
                .isEmpty,
            "a pen in the groove must produce no position over USB either")
    }

    /// Real consecutive pair from `ptk-870-usb-edge-bounce-right.txt`, a
    /// see-saw across the right edge. USB leaps exactly as Bluetooth does:
    /// 4340 units in one 2ms step, both endpoints ~2600 from an edge with
    /// hover railed and nothing touching. That distance is outside the rim,
    /// which is why the rule uses the wider border band.
    func testRealCaptureUSBBarrelLeapSuppressed() {
        var st = DecoderState()
        let atEdge: [UInt8] = [
            0x1E, 0x01, 0x80, 0xAF, 0xF2, 0x00, 0x20, 0x8E, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x8E, 0x30, 0x33, 0x86,
        ]
        let barrel: [UInt8] = [
            0x1E, 0x01, 0x80, 0xBB, 0xE1, 0x00, 0x44, 0x8E, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x6A, 0x31, 0x34, 0x86,
        ]
        func pts(_ b: [UInt8]) -> [TabletPoint] {
            decode(b, state: &st).compactMap {
                if case .pen(let p) = $0 { return p } else { return nil }
            }
        }
        XCTAssertTrue(pts(atEdge).isEmpty, "off-surface sample at the edge produces nothing")
        XCTAssertTrue(pts(barrel).isEmpty, "and neither does the barrel leap that follows")
    }

    /// Guards the headroom the USB band has left. The reference hover frame
    /// below sits 4459 units from an edge and survives the 4000-unit band by
    /// 459 units; widening the band past that silences legitimate high hover
    /// near an edge. If this fails, the band was widened too far.
    func testUSBOutOfSurfaceBandLeavesHeadroomForEdgeHover() {
        var st = DecoderState()
        var b: [UInt8] = [
            0x1E, 0x01, 0x80, 0x51, 0x8B, 0x00, 0x6B, 0x11, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xBA, 0xC8, 0xB3, 0x3A,
        ]
        // Move it to sit exactly 4200 units from the top — inside the
        // reference frame's margin, still outside the band.
        let y = 4200
        b[6] = UInt8(y & 0xFF); b[7] = UInt8((y >> 8) & 0xFF); b[8] = 0
        let pts = decode(b, state: &st).compactMap {
            if case .pen(let p) = $0 { return p } else { return nil }
        }
        XCTAssertEqual(pts.count, 1, "hover just outside the band must still track")
        XCTAssertEqual(pts[0].y, 4200)
    }

    /// The counterexample that shapes the rule above, and the reason it is not
    /// simply "hover railed". This hover frame from the same reference
    /// recording as the fixtures above reads 255 while the pen sits over the
    /// MIDDLE of the tablet — 51% across, 11% down — so the rail means "at or
    /// past the sensing limit", which a pen held high in open space reaches
    /// just as one in the groove does. Only pairing it with the rim separates
    /// them, and this frame must survive.
    func testRealCaptureUSBHighHoverMidTabletSurvives() {
        var st = DecoderState()
        let b: [UInt8] = [
            0x1E, 0x01, 0x80, 0x51, 0x8B, 0x00, 0x6B, 0x11, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xBA, 0xC8, 0xB3, 0x3A,
        ]
        XCTAssertEqual(b[19], 255, "premise: same railed hover distance as the groove frame")
        let pts = decode(b, state: &st).compactMap {
            if case .pen(let p) = $0 { return p } else { return nil }
        }
        XCTAssertEqual(pts.count, 1, "high hover over open surface must still track")
        XCTAssertEqual(pts[0].x, 35665)
        XCTAssertEqual(pts[0].y, 4459)
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
        // Fresh DecoderState means this frame's real, nonzero serial/tool
        // code (0x24c087aa / 0x0200) is a "new" tool by definition, so a
        // .toolEnter precedes the .pen result — see IntuosV3Decoder's
        // 2026-09-16 tool-identity fix.
        XCTAssertEqual(r.count, 2)
        guard case .pen(let pt) = r.last else { return XCTFail() }
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
        // Same reasoning as above — fresh state, real nonzero serial/tool
        // code, so .toolEnter fires alongside .pen.
        XCTAssertEqual(r.count, 2)
        guard case .pen(let pt) = r.last else { return XCTFail() }
        XCTAssertTrue(pt.inProximity)
        XCTAssertEqual(pt.pressure, 8191)
        XCTAssertEqual(pt.x, 33716)
        XCTAssertEqual(pt.y, 13941)
    }

    // MARK: - Tool identity (serial/tool code, bytes 20-25)
    //
    // Confirmed 2026-09-16 against a real PTK-870 capture using a
    // known-identity pen (Wacom Art Pen, tool code 0x0804, serial
    // 0x038000CE): bytes 20-23 decoded byte-for-byte to the real serial,
    // bytes 24-25 to the real tool code. See
    // Notes/Scratch/PTK-870-ToolID-Field-Survey-2026-09-16.md for the full
    // derivation. The bytes below are synthesized from that confirmed
    // offset/encoding (not a verbatim capture — the source JSON only
    // stores aggregate byte statistics, not a raw in-proximity sample), but
    // every other field (status/X/Y/pressure/tilt) is copied from an
    // already-verified real-capture fixture above, so only bytes 20-25 are
    // constructed rather than captured.

    func testRealCaptureToolEnterFiresOnFirstProximityWithKnownArtPen() {
        var st = DecoderState()
        var b: [UInt8] = [
            0x1E, 0x01, 0xC1, 0xB4, 0x83, 0x00, 0x75, 0x36, 0x00, 0xFF, 0x1F,
            0x20, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x02, 0xD4, 0x18, 0x18, 0x3D,
        ]
        // Art Pen ground truth: serial 0x038000CE (LE bytes 20-23),
        // tool code 0x0804 (LE bytes 24-25).
        b[20] = 0xCE
        b[21] = 0x00
        b[22] = 0x80
        b[23] = 0x03
        b[24] = 0x04
        b[25] = 0x08
        let r = decode(b, state: &st)
        // 2: .toolEnter + .pen. The classic Art Pen (0x0804) is confirmed
        // compatible with .intuosProGen3 (2026-09-18 three-pen PTK-870
        // capture), so no .toolCompatibility warning fires here.
        XCTAssertEqual(r.count, 2)
        guard case .toolEnter(let identity) = r.first else { return XCTFail() }
        XCTAssertEqual(identity.serial, 0x038000CE)
        XCTAssertEqual(identity.toolCode, 0x0804)
        XCTAssertFalse(identity.isEraser)  // 0x0804 is the Art-Pen bit3 exclusion
        XCTAssertFalse(identity.isMouse)
        guard case .pen = r.last else { return XCTFail() }
    }

    func testToolEnterDoesNotRefireForTheSameToolAcrossFrames() {
        var st = DecoderState()
        var b: [UInt8] = [
            0x1E, 0x01, 0xC1, 0xB4, 0x83, 0x00, 0x75, 0x36, 0x00, 0xFF, 0x1F,
            0x20, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x02, 0xD4, 0x18, 0x18, 0x3D,
        ]
        b[20] = 0xCE
        b[21] = 0x00
        b[22] = 0x80
        b[23] = 0x03
        b[24] = 0x04
        b[25] = 0x08
        let first = decode(b, state: &st)
        // 2: .toolEnter + .pen — see the test above for why no
        // .toolCompatibility warning fires for this tool on gen3.
        XCTAssertEqual(first.count, 2)
        let second = decode(b, state: &st)
        // Same tool, same frame content — no repeat .toolEnter or
        // .toolCompatibility, just the ordinary pen sample.
        XCTAssertEqual(second.count, 1)
        guard case .pen = second.first else { return XCTFail() }
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

    // MARK: - 0x1E real-capture fixtures (Movink 13, OpenTabletDriver PR #3679)
    //
    // Bytes below are taken verbatim from that capture's tablet-data.1.txt
    // (056a:03f0, Pro Pen 3, ~26k reports). Confirms all three barrel
    // buttons and real tilt range against a device other than the PTK-870.

    func testRealCaptureMovinkBarrelButton1() {
        var st = DecoderState()
        let b: [UInt8] = [
            0x1E, 0x01, 0xC2, 0xFD, 0x75, 0x00, 0x27, 0x42, 0x00, 0x00, 0x00,
            0x22, 0x00, 0xFA, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x57, 0x36, 0xD9,
            0x50, 0x24, 0x00, 0x02, 0x10, 0x00, 0x00, 0x02, 0xE0, 0xCE, 0x1E, 0xB8,
        ]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r.last else { return XCTFail() }
        XCTAssertTrue(pt.penButton1)
        XCTAssertFalse(pt.penButton2)
        XCTAssertFalse(pt.penButton3)
    }

    func testRealCaptureMovinkBarrelButton2() {
        var st = DecoderState()
        let b: [UInt8] = [
            0x1E, 0x01, 0xC4, 0x8A, 0x71, 0x00, 0x03, 0x41, 0x00, 0x00, 0x00,
            0x20, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x61, 0x36, 0xD9,
            0x50, 0x24, 0x00, 0x02, 0x10, 0x00, 0x00, 0x02, 0xB7, 0x6B, 0xE3, 0xBB,
        ]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r.last else { return XCTFail() }
        XCTAssertFalse(pt.penButton1)
        XCTAssertTrue(pt.penButton2)
        XCTAssertFalse(pt.penButton3)
    }

    func testRealCaptureMovinkBarrelButton3() {
        var st = DecoderState()
        let b: [UInt8] = [
            0x1E, 0x01, 0xC8, 0x1C, 0x6C, 0x00, 0x41, 0x43, 0x00, 0x00, 0x00,
            0x1E, 0x00, 0xF8, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x5F, 0x36, 0xD9,
            0x50, 0x24, 0x00, 0x02, 0x10, 0x00, 0x00, 0x02, 0x68, 0x1B, 0x1C, 0xC0,
        ]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r.last else { return XCTFail() }
        XCTAssertFalse(pt.penButton1)
        XCTAssertFalse(pt.penButton2)
        XCTAssertTrue(pt.penButton3)
    }

    func testRealCaptureMovinkTiltMatchesDegreeScale() {
        var st = DecoderState()
        let b: [UInt8] = [
            0x1E, 0x01, 0xC0, 0x09, 0x01, 0x00, 0xE7, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x1F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x71, 0x36, 0xD9,
            0x50, 0x24, 0x00, 0x02, 0x10, 0x00, 0x00, 0x02, 0x83, 0x4A, 0xDA, 0x67,
        ]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r.last else { return XCTFail() }
        XCTAssertEqual(pt.tiltX, 0.0, accuracy: 0.001)
        XCTAssertEqual(pt.tiltY, 31.0 / 64.0, accuracy: 0.001)
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

    // MARK: - 0x1A Bluetooth LE report (PTK-870, real captures)
    //
    // Bytes taken verbatim from raw sequential HID logs captured 2026-09-17
    // via `tools/capture/hid_input_capture.c` against a real PTK-870 over
    // BLE (see IntuosV3Decoder.swift's decodeBLEReport doc comment for the
    // full field-confirmation methodology).

    func testShort0x1ARejected() {
        var st = DecoderState()
        let r = decode([0x1A, 0x42], state: &st)
        XCTAssertTrue(r.isEmpty)
    }

    /// Real mid-stroke sample from `ptk-870-pressure-spiral.txt`, at the
    /// moment pressure reaches its ceiling. Every field in the 0x1A report
    /// is asserted here in raw device units — the report carries the same
    /// units the USB registry entry declares, so nothing is rescaled.
    func testRealCaptureBLEPositionDecoded() {
        var st = DecoderState()
        let b: [UInt8] = [
            26, 66, 128, 193, 84, 124, 144, 31, 6, 255,
            31, 253, 223, 65, 173, 20, 112, 9, 0, 0,
        ]
        let p = pens(decodeBLE(b, state: &st))
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].x, 31828)  // [4..6] 20-bit
        XCTAssertEqual(p[0].y, 25081)  // [6..8] 20-bit
        XCTAssertEqual(p[0].pressure, 8191)  // [9..10] LE16, at spec.maxPressure
        XCTAssertEqual(p[0].tiltX, -3.0 / 64.0, accuracy: 1e-9)  // [11] signed
        XCTAssertEqual(p[0].tiltY, -33.0 / 64.0, accuracy: 1e-9)  // [12] signed
        XCTAssertTrue(p[0].inProximity)
        XCTAssertFalse(p[0].penButton1)
        XCTAssertFalse(p[0].penButton2)
    }

    /// The regression this whole BLE decoder existed to hit and kept
    /// missing: X is 20 bits, not 16, and its high nibble shares byte [6]
    /// with Y's low bits. These two samples are consecutive frames from
    /// `ptk-870-bt-x-shape-edge.txt` at the moment a real stroke crosses
    /// 65536 — raw [4..5] reads 65531 then 10, and the low nibble of [6]
    /// goes 0 → 1. Read as 16 bits the cursor jumps the full width of the
    /// tablet; read correctly it advances 15 units.
    ///
    /// A 16-bit read also made the pen's own tilt look like it was
    /// corrupting position, because tilting shifts the reported coordinate
    /// by enough to cross that boundary when the pen is already near the
    /// right edge — which is why the symptom presented as "tilt confounds
    /// the cursor" rather than as a plain coordinate bug.
    func testRealCaptureBLEXSpans20BitsAcrossTheWrapBoundary() {
        var st = DecoderState()
        let before: [UInt8] = [
            26, 2, 32, 192, 251, 255, 0, 181, 8, 0,
            0, 24, 35, 0, 160, 47, 202, 98, 0, 0,
        ]
        let after: [UInt8] = [
            26, 2, 32, 192, 10, 0, 177, 181, 8, 0,
            0, 24, 35, 0, 176, 46, 235, 98, 0, 0,
        ]
        let xBefore = pens(decodeBLE(before, state: &st))[0].x
        let xAfter = pens(decodeBLE(after, state: &st))[0].x
        XCTAssertEqual(xBefore, 65531)
        XCTAssertEqual(xAfter, 65546)
        XCTAssertEqual(xAfter - xBefore, 15)
    }

    /// Real sample from `ptk-870-bt-right-edge.txt`, where X rests at the
    /// tablet's true right edge. The reconstructed value must land on
    /// `spec.maxX` exactly — this is the independent check that 20 bits is
    /// the right width and that no scale factor belongs anywhere near it.
    /// The earlier "X freezes at 4264 near the right corners" report was
    /// this same frame with bit 16 dropped: 69800 − 65536 = 4264.
    func testRealCaptureBLEXReachesExactlyMaxAtRightEdge() {
        var st = DecoderState()
        let b: [UInt8] = [
            26, 2, 32, 192, 168, 16, 1, 0, 0, 0,
            0, 0, 0, 0, 16, 255, 246, 78, 32, 0,
        ]
        let p = pens(decodeBLE(b, state: &st))
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].x, 69800)
        XCTAssertEqual(p[0].x, ptk870.maxX)
        XCTAssertEqual(p[0].y, 0)  // top edge, and a real sample — not a placeholder
    }

    /// The four held-static tilt poses (`ptk-tilt-left/right/up/down.txt`),
    /// each bit-identical frame to frame for every byte through [12], so
    /// they isolate tilt from position exactly. Byte [11] flips sign between
    /// left and right while [12] stays near zero, and vice versa — the
    /// axis assignment falls straight out.
    func testRealCaptureBLETiltAxesFromHeldPoses() {
        let poses: [(String, [UInt8], Double, Double)] = [
            (
                "left",
                [26, 66, 128, 192, 122, 34, 48, 90, 4, 0, 0, 60, 248, 209, 253, 43, 163, 235, 0, 0],
                60, -8
            ),
            (
                "right",
                [
                    26, 66, 128, 192, 160, 228, 240, 120, 5, 0, 0, 196, 249, 82, 189, 39, 73, 159,
                    0, 0,
                ], -60, -7
            ),
            (
                "up",
                [26, 66, 128, 192, 125, 127, 32, 22, 1, 0, 0, 2, 57, 82, 79, 20, 65, 168, 0, 0],
                2, 57
            ),
            (
                "down",
                [
                    26, 66, 128, 192, 215, 123, 112, 233, 6, 0, 0, 17, 197, 118, 32, 20, 224, 100,
                    0, 0,
                ], 17, -59
            ),
        ]
        for (name, bytes, wantTiltX, wantTiltY) in poses {
            var st = DecoderState()
            let p = pens(decodeBLE(bytes, state: &st))
            XCTAssertEqual(p.count, 1, "pose \(name)")
            XCTAssertEqual(p[0].tiltX, wantTiltX / 64.0, accuracy: 1e-9, "pose \(name) tiltX")
            XCTAssertEqual(p[0].tiltY, wantTiltY / 64.0, accuracy: 1e-9, "pose \(name) tiltY")
        }
    }

    /// Real withdrawal from `ptk-870-pen-2-proximity.txt`. Status byte [3]
    /// drops to 0x00 for exactly one frame per withdrawal — the proximity
    /// exit this investigation spent two capture rounds looking for in the
    /// [1] discriminator, where it does not exist. The exit frame still
    /// carries the last tracked coordinates, so the emitted point must use
    /// the remembered position and report `inProximity == false` rather than
    /// treating those stale bytes as a fresh sample.
    func testRealCaptureBLEProximityExitOnZeroStatus() {
        var st = DecoderState()
        let inRange: [UInt8] = [
            26, 2, 0, 128, 12, 124, 48, 188, 4, 0,
            0, 0, 0, 0, 144, 255, 215, 50, 0, 0,
        ]
        let exit: [UInt8] = [
            26, 2, 0, 0, 240, 123, 112, 187, 4, 0,
            0, 0, 0, 0, 176, 255, 252, 51, 0, 0,
        ]
        let entered = pens(decodeBLE(inRange, state: &st))
        XCTAssertEqual(entered.count, 1)
        XCTAssertTrue(entered[0].inProximity)
        XCTAssertEqual(entered[0].x, 31756)

        let left = pens(decodeBLE(exit, state: &st))
        XCTAssertEqual(left.count, 1)
        XCTAssertFalse(left[0].inProximity)
        XCTAssertEqual(left[0].pressure, 0)
        XCTAssertEqual(left[0].x, 31756, "exit must hold the last position, not the stale bytes")

        // A second out-of-range frame must not emit a second exit.
        XCTAssertTrue(pens(decodeBLE(exit, state: &st)).isEmpty)
    }

    /// Real hover-only frame from the labelled stand capture
    /// (`ptk-870-bt-wacom-stand-art-pen.txt`, "0°" section) — the pen sat in
    /// a fixed stand with no tip contact at all, confirming rotation isn't
    /// tip-switch-gated on BLE the way it is on USB. Bytes [13..14] pack a
    /// 12-bit signed count into byte [13] plus [14]'s low nibble; [14]'s high
    /// nibble is a frame counter (0xb, 0xc, 0xd... here) that must NOT bleed
    /// into the rotation value.
    func testRealCaptureBLERotationDecodedForArtPen() {
        var st = DecoderState()
        let b: [UInt8] = [
            26, 66, 128, 192, 85, 143, 176, 102, 3, 0,
            0, 0, 254, 65, 190, 81, 144, 240, 0, 0,
        ]
        let p = pens(decodeBLE(b, state: &st))
        XCTAssertEqual(p.count, 1)
        // packed = 0x41 | ((0xbe & 0x0F) << 8) = 0xE41 -> sign-extend -> -447
        // (900 - (-447)) / 5 = 269.4
        XCTAssertEqual(p[0].rotation, 269.4, accuracy: 1e-9)
    }

    /// Real interior in-range frame from `ptk-870-bt-top-see-saw-right.txt`
    /// — an ordinary tracing pass with no rotation gesture involved.
    /// Confirms the field decodes to a fixed neutral 180° (raw count 0)
    /// rather than noise when nothing is twisting the barrel: this is what
    /// let rotation be decoded unconditionally instead of gated on tool
    /// identity (see the decoder's header comment — BLE's tool-enter frame
    /// is one-shot and often never arrives, so tool identity can't gate this
    /// reliably).
    func testRealCaptureBLERotationRestsAtNeutralWithoutTwist() {
        var st = DecoderState()
        let b: [UInt8] = [
            26, 2, 32, 192, 245, 68, 64, 190, 0, 0,
            0, 41, 252, 0, 64, 81, 98, 169, 0, 0,
        ]
        let p = pens(decodeBLE(b, state: &st))
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].rotation, 180.0, accuracy: 1e-9)
    }

    /// Real sample from `ptk-870-left-to-right.txt` with a barrel button
    /// held and the tip up (status 0xC4). Bit 2 is the only barrel bit any
    /// capture ever set; bit 0 tracks the tip switch, and agrees with
    /// pressure > 0 across every capture on hand.
    func testRealCaptureBLEBarrelButtonDecoded() {
        var st = DecoderState()
        let b: [UInt8] = [
            26, 66, 128, 196, 191, 4, 96, 198, 7, 0,
            0, 0, 234, 254, 253, 106, 140, 68, 15, 0,
        ]
        let p = pens(decodeBLE(b, state: &st))
        XCTAssertEqual(p.count, 1)
        XCTAssertTrue(p[0].penButton2)
        XCTAssertFalse(p[0].penButton1)
        XCTAssertEqual(p[0].pressure, 0)
        XCTAssertTrue(p[0].inProximity)
    }

    /// Real sample from `ptk-870-tilt-hover-left-to-right.txt` — discriminator
    /// 0x02, which an early version of this decoder treated as pure
    /// idle/no-pen and discarded entirely. A dedicated hover-only sweep (pen
    /// moved across the tablet without ever touching down) showed clean,
    /// live, monotonic X motion exclusively under this discriminator — it
    /// must decode as a real pen point, not be dropped.
    func testRealCaptureBLEHoverFrameDecodesAsPosition() {
        var st = DecoderState()
        let b: [UInt8] = [
            26, 2, 32, 192, 43, 78, 112, 187, 2, 0,
            0, 9, 247, 0, 16, 54, 119, 65, 0, 0,
        ]
        let p = pens(decodeBLE(b, state: &st))
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].x, 20011)
        XCTAssertEqual(p[0].pressure, 0)
    }

    /// Real sample from `ptk-870-left.txt` (ExpressKeys/dial exercised with
    /// no pen anywhere near the tablet). Status byte [3] is 0x00 — the pen
    /// is not in range, so no position is emitted regardless of what the
    /// coordinate bytes happen to hold.
    func testRealCaptureBLENoPenPlaceholderSuppressed() {
        var st = DecoderState()
        let b: [UInt8] = [
            26, 2, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 144, 0, 0, 0, 1, 0,
        ]
        XCTAssertTrue(pens(decodeBLE(b, state: &st)).isEmpty)
    }

    /// Real sample from a live bug capture — discriminator 0x01, observed as
    /// a fixed, byte-for-byte identical phantom point recurring several
    /// times. Not part of the confirmed 0x02/0x21/0x22/0x41/0x42 state set;
    /// excluded outright. (It also sets bit 3 of byte [6], which no real
    /// sample ever does, putting its X far past `spec.maxX`.)
    func testRealCaptureBLEDiscriminatorOneSuppressed() {
        var st = DecoderState()
        let b: [UInt8] = [
            26, 1, 32, 192, 92, 67, 24, 38, 0, 2,
            16, 0, 0, 2, 176, 0, 0, 0, 0, 0,
        ]
        XCTAssertTrue(pens(decodeBLE(b, state: &st)).isEmpty)
    }

    /// An announcement carries identity, never a position — suppressed here
    /// by its class nibble rather than by matching its bytes.
    func testRealCaptureBLEAnnouncementEmitsNoPosition() {
        var st = DecoderState()
        let b: [UInt8] = [
            26, 65, 128, 192, 129, 144, 128, 36, 4, 8,
            17, 0, 4, 8, 224, 0, 0, 0, 0, 0,
        ]
        XCTAssertTrue(pens(decodeBLE(b, state: &st)).isEmpty)
    }

    /// The two byte rows once whitelisted as "mistagged templates" are real
    /// announcements, one per pen, and must yield that pen's identity.
    ///
    /// Verified against `870-usb-healthier-art-pen-0x0084-20260923-210819`:
    /// over USB the same physical pen reports serial 612405377 / toolCode
    /// 0x0804, and its USB identity bytes [20..29] are byte-identical to this
    /// BLE frame's [4..13]. Suppressing these cost both pens their identity,
    /// after which a class-2 position frame's coordinate bytes were trusted
    /// as toolCode 0x1002 — a tool code that does not exist.
    func testRealCaptureBLEFormerlyWhitelistedRowsYieldToolIdentity() {
        let expected: [(name: String, frame: [UInt8], serial: UInt32, code: UInt16)] = [
            (
                "Art Pen", [26, 1, 128, 192, 129, 144, 128, 36, 4, 8, 17, 0, 4, 8, 224, 0, 0, 0, 0, 0],
                612_405_377, 0x0804
            ),
            (
                "Grip Pen", [26, 1, 128, 192, 136, 149, 128, 53, 2, 8, 17, 0, 2, 8, 224, 0, 0, 0, 0, 0],
                897_619_336, 0x0802
            ),
        ]
        for (name, frame, serial, code) in expected {
            var st = DecoderState()
            let identities = decodeBLE(frame, state: &st).compactMap { result -> ToolIdentity? in
                if case .toolEnter(let identity) = result { return identity } else { return nil }
            }
            XCTAssertEqual(identities.count, 1, "\(name) must announce exactly one tool")
            XCTAssertEqual(identities.first?.serial, serial, "\(name) serial")
            XCTAssertEqual(identities.first?.toolCode, code, "\(name) toolCode")
        }
    }

    /// Verbatim from `bt-zap-0x03FA-20260923-152226`: the Art Pen's class-1
    /// frame, which the since-removed literal whitelist never matched.
    /// Decoded as a position it yields a fixed x=206 (hard against the left
    /// edge) with pressure 4360 — the cursor springs to one screen spot and
    /// clicks. Rapid proximity re-entry emits a burst of these, which is why
    /// a slow approach looked clean.
    ///
    /// Class, not literal bytes, is the invariant: across 160,408 BT frames
    /// in 56 captures there are six distinct class-1 `[3..9]` signatures, one
    /// per pen, and a whitelist of two could never cover them.
    func testRealCaptureBLEArtPenClassOneFrameEmitsNoPosition() {
        var st = DecoderState()
        let zap: [UInt8] = [
            0x1A, 0x41, 0x80, 0xC0, 0xCE, 0x00, 0x80, 0x03, 0x04, 0x08,
            0x11, 0x00, 0x04, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        XCTAssertTrue(
            pens(decodeBLE(zap, state: &st)).isEmpty,
            "a class-1 frame must never decode to a pen point — this is the BT zap")
    }

    /// The other four class-1 signatures found in the capture corpus, each a
    /// different pen. None may produce a position. Guards against a future
    /// literal-matching regression: every one of these was falling through
    /// before the guard moved to the discriminator's low nibble.
    func testRealCaptureBLEEveryObservedClassOneSignatureEmitsNoPosition() {
        let signatures: [(String, [UInt8])] = [
            ("Pro Pen 0x0200", [0xC0, 0x5C, 0x43, 0x18, 0x26, 0x00, 0x02]),
            ("Grip Pen 0x0802", [0xC0, 0x4E, 0x1D, 0x80, 0x21, 0x02, 0x08]),
            ("0x0842", [0xC0, 0x98, 0x44, 0x80, 0x87, 0x42, 0x08]),
            ("Art Pen 0x0804", [0xC0, 0xCE, 0x00, 0x80, 0x03, 0x04, 0x08]),
        ]
        // Every class value whose low nibble is 1; the high bits are a
        // rolling counter, so all of these must behave identically.
        for discriminator: UInt8 in [0x01, 0x21, 0x41, 0xC1] {
            for (label, payload) in signatures {
                var st = DecoderState()
                var b: [UInt8] = [0x1A, discriminator, 0x80]
                b.append(contentsOf: payload)
                b.append(contentsOf: [UInt8](repeating: 0, count: 20 - b.count))
                XCTAssertTrue(
                    pens(decodeBLE(b, state: &st)).isEmpty,
                    "\(label) at discriminator \(String(format: "0x%02X", discriminator)) must emit no position")
            }
        }
    }

    /// The counterpart guarantee: suppressing class-1 positions must not cost
    /// us the tool identity those same frames carry. An announcement arriving
    /// as 0x41 rather than a bare 0x01 was previously skipped by the identity
    /// branch *and* rejected by the position branch, so the pen went
    /// unrecognized — the generic-pen symptom, over Bluetooth.
    func testRealCaptureBLEClassOneAnnouncementStillYieldsToolIdentity() {
        var st = DecoderState()
        // Pro Pen announcement (serial 0x2618435C, toolCode 0x0200), verbatim
        // payload, carried on discriminator 0x41.
        let announce: [UInt8] = [
            0x1A, 0x41, 0x20, 0xC0, 0x5C, 0x43, 0x18, 0x26, 0x00, 0x02,
            0x10, 0x00, 0x00, 0x02, 0xB0, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        let results = decodeBLE(announce, state: &st)
        let toolEnters = results.compactMap { result -> (UInt32, UInt16)? in
            if case .toolEnter(let id) = result { return (id.serial, id.toolCode) }
            return nil
        }
        XCTAssertEqual(
            toolEnters.count, 1,
            "a class-1 announcement must still announce the tool")
        XCTAssertEqual(toolEnters.first?.1, 0x0200, "tool code must survive the class-1 position guard")
        XCTAssertTrue(
            pens(results).isEmpty,
            "the announcement frame carries identity only, never a position")
    }

    /// Real three-frame sequence from `ptk-870-bt-edge-bounce-right.txt`, at
    /// the moment the pen tip crosses the right edge during a see-saw. The
    /// first frame sits at maxX with NO close tip fix — the pen is already
    /// off the surface — so the rim rule drops it and arms the gate, and the
    /// two barrel samples that follow (well clear of the rim, so only the
    /// gate can catch them) are dropped too. The cursor stays where the tip
    /// was last genuinely seen.
    func testRealCaptureBLEBarrelTakeoverSuppressedPastTheEdge() {
        var st = DecoderState()
        let pastEdge: [UInt8] = [
            26, 2, 0, 128, 168, 16, 1, 0, 0, 0,
            0, 0, 0, 0, 16, 255, 246, 78, 0, 0,
        ]
        let barrel1: [UInt8] = [
            26, 2, 0, 128, 34, 5, 145, 176, 3, 0,
            0, 0, 0, 0, 112, 255, 210, 171, 0, 0,
        ]
        let barrel2: [UInt8] = [
            26, 2, 0, 128, 16, 6, 161, 153, 2, 0,
            0, 0, 0, 0, 128, 255, 3, 172, 0, 0,
        ]
        XCTAssertEqual(pastEdge[3] & 0x40, 0, "premise: at the edge with no close tip fix")
        XCTAssertTrue(
            pens(decodeBLE(pastEdge, state: &st)).isEmpty,
            "a pen at the rim with no tip fix is off the surface, not a position")
        XCTAssertTrue(
            pens(decodeBLE(barrel1, state: &st)).isEmpty,
            "the rim sample must have armed the gate for the barrel that follows")
        XCTAssertTrue(
            pens(decodeBLE(barrel2, state: &st)).isEmpty,
            "gate stays armed for subsequent barrel samples")
    }

    /// The labelled pair that settles what "out of bounds" means on this
    /// hardware, from two captures made to answer exactly that.
    ///
    /// `ptk-870-bt-top-border.txt` traces the real top border of the drawable
    /// area — described as tracking flawlessly — and sits at Y = 0, ON the
    /// limit. `ptk-870-bt-top-groove.txt` traces the moulded groove beyond
    /// that border, half an inch further out where no cursor response should
    /// be possible at all, and reports Y folded back about 850 units INSIDE
    /// the limit. The out-of-bounds sample therefore reads as further inside
    /// the surface than the in-bounds one, so no inset or matte can separate
    /// them. The status byte can: the border carries a close tip fix, the
    /// groove does not.
    func testRealCaptureBLEGrooveSuppressedButBorderKept() {
        var st = DecoderState()
        let border: [UInt8] = [
            26, 2, 32, 192, 168, 16, 1, 0, 0, 0,
            0, 248, 0, 0, 144, 112, 234, 80, 32, 0,
        ]
        let kept = pens(decodeBLE(border, state: &st))
        XCTAssertEqual(kept.count, 1, "the real border must keep tracking")
        XCTAssertEqual(kept[0].y, 0, "premise: the in-bounds border sits ON the limit")

        var st2 = DecoderState()
        let groove: [UInt8] = [
            26, 2, 0, 128, 67, 77, 208, 53, 0, 0,
            0, 0, 0, 0, 240, 255, 100, 64, 0, 0,
        ]
        let y = Int(groove[6] >> 4) | Int(groove[7]) << 4 | Int(groove[8]) << 12
        XCTAssertGreaterThan(y, 0, "premise: the groove reads INSIDE the limit, not at it")
        XCTAssertLessThan(y, 1000)
        XCTAssertEqual(groove[3] & 0x40, 0, "premise: no close tip fix")

        XCTAssertTrue(
            pens(decodeBLE(groove, state: &st2)).isEmpty,
            "a pen in the groove must produce no position at all")
    }

    /// Real pair from `ptk-870-bt-top-bermuda-triangle-01.txt`, a capture made
    /// specifically to worry at the last spot still misbehaving. The pen is
    /// hovering over the top bezel at Y = 2409 — physically off the drawable
    /// area, but numerically 2409 units short of the limit, so nothing rails.
    /// An earlier gate armed only ON a limit and so never engaged here; all 96
    /// barrel jumps across the three bermuda captures looked exactly like
    /// this. X hops 4124 units with Y essentially unchanged — the barrel
    /// offset — and must be rejected.
    func testRealCaptureBLEBarrelHopOverBezelSuppressedWithoutRailing() {
        var st = DecoderState()
        let hovering: [UInt8] = [
            26, 2, 0, 128, 67, 77, 144, 150, 0, 0,
            0, 0, 0, 0, 240, 255, 100, 64, 0, 0,
        ]
        let barrelHop: [UInt8] = [
            26, 2, 0, 128, 39, 61, 32, 152, 0, 0,
            0, 0, 0, 0, 0, 255, 130, 64, 0, 0,
        ]
        let p = pens(decodeBLE(hovering, state: &st))
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].x, 19779)
        XCTAssertEqual(p[0].y, 2409)
        XCTAssertNotEqual(p[0].y, 0, "premise: nothing is railed here")

        XCTAssertTrue(
            pens(decodeBLE(barrelHop, state: &st)).isEmpty,
            "a barrel hop over the bezel must be rejected even though no coordinate railed")
    }

    /// The border band must not swallow the interior: a pen working in the
    /// middle of the tablet is never gated, however it moves.
    func testRealCaptureBLEInteriorMotionNeverGated() {
        var st = DecoderState()
        let a: [UInt8] = [
            26, 66, 128, 193, 84, 124, 144, 31, 6, 255,
            31, 253, 223, 65, 173, 20, 112, 9, 0, 0,
        ]
        XCTAssertEqual(pens(decodeBLE(a, state: &st)).count, 1)
        var b = a
        b[4] = 0x00
        b[5] = 0x60  // X = 24576, a 7000-unit move
        let moved = pens(decodeBLE(b, state: &st))
        XCTAssertEqual(moved.count, 1, "interior motion is never subject to the gate")
        XCTAssertEqual(moved[0].x, 24576)
    }

    /// Real sequence from `ptk-870-bt-top-see-saw-right.txt`. While the pen
    /// ghosts along the top bezel the tablet emits a proximity exit of its
    /// OWN accord, mid-ghost, and then carries straight on reporting the
    /// barrel. An earlier version of the gate disarmed on that exit, which
    /// let the very next barrel sample through as a fresh position and was
    /// the single largest source of surviving cursor leaps — the gate must
    /// survive it.
    func testRealCaptureBLEBarrelGateSurvivesSpuriousProximityExit() {
        var st = DecoderState()
        let tipAtEdge: [UInt8] = [
            26, 2, 32, 192, 23, 4, 0, 0, 0, 0,
            0, 48, 0, 0, 0, 127, 195, 156, 0, 0,
        ]
        let exit: [UInt8] = [
            26, 2, 0, 0, 0, 174, 32, 86, 0, 0,
            0, 0, 0, 0, 224, 255, 106, 220, 0, 0,
        ]
        let barrel: [UInt8] = [
            26, 2, 0, 128, 27, 20, 80, 144, 0, 0,
            0, 0, 0, 0, 80, 255, 98, 157, 0, 0,
        ]
        let tip = pens(decodeBLE(tipAtEdge, state: &st))
        XCTAssertEqual(tip.count, 1)
        XCTAssertEqual(tip[0].y, 0)

        let left = pens(decodeBLE(exit, state: &st))
        XCTAssertEqual(left.count, 1)
        XCTAssertFalse(left[0].inProximity)

        XCTAssertTrue(
            pens(decodeBLE(barrel, state: &st)).isEmpty,
            "gate must stay armed across the exit and reject the barrel")
    }

    /// The gate bounds its own rejections. A rejected sample deliberately
    /// does not update the reference position, so without a cap a pen that
    /// leaves the edge and keeps going would never satisfy the continuity
    /// test again and the cursor would be dead until the next proximity
    /// cycle. After the cap the gate yields.
    func testRealCaptureBLEBarrelGateCannotLatchForever() {
        var st = DecoderState()
        let tipAtEdge: [UInt8] = [
            26, 2, 32, 192, 23, 4, 0, 0, 0, 0,
            0, 48, 0, 0, 0, 127, 195, 156, 0, 0,
        ]
        let farAway: [UInt8] = [
            26, 2, 0, 128, 27, 20, 80, 144, 0, 0,
            0, 0, 0, 0, 80, 255, 98, 157, 0, 0,
        ]
        XCTAssertEqual(pens(decodeBLE(tipAtEdge, state: &st)).count, 1)

        var emitted = 0
        for _ in 0..<64 where !pens(decodeBLE(farAway, state: &st)).isEmpty {
            emitted += 1
        }
        XCTAssertGreaterThan(emitted, 0, "gate must eventually yield, not latch forever")
    }

    /// The gate must not become a one-way door: a pen that genuinely comes
    /// back onto the surface moves continuously (measured: at most 254 units
    /// per frame across every real re-entry in the four see-saw captures), so
    /// small steps inward from a railed position must be honored.
    func testRealCaptureBLEGateReleasesOnContinuousReentry() {
        var st = DecoderState()
        let railed: [UInt8] = [
            26, 2, 32, 192, 168, 16, 145, 172, 3, 0,
            0, 0, 0, 0, 96, 255, 160, 171, 0, 0,
        ]
        XCTAssertEqual(pens(decodeBLE(railed, state: &st))[0].x, ptk870.maxX)

        // Synthesised from the railed frame by stepping X back by 150 units,
        // the scale of a real re-entry — the surrounding bytes are the real
        // capture's. 69800 - 150 = 69650 = 0x11012 -> [4]=0x12 [5]=0x10 [6] bit0 set.
        var reentry = railed
        reentry[4] = 0x12
        reentry[5] = 0x10
        let back = pens(decodeBLE(reentry, state: &st))
        XCTAssertEqual(back.count, 1, "a continuous step back inside must be honored")
        XCTAssertEqual(back[0].x, 69650)

        // And the gate is now disarmed: ordinary motion flows again.
        var further = reentry
        further[4] = 0x7A  // 69554
        further[5] = 0x0F
        XCTAssertEqual(pens(decodeBLE(further, state: &st)).count, 1)
    }

    /// The slot-1 (discriminator 0x21) sync template — the edge bounceback.
    /// Taken verbatim from `ptk-870-bt-edge-bounce-right.txt`, where it is
    /// emitted as the pen leaves the active surface. It decodes to a fixed
    /// phantom point mid-tablet with a fixed phantom pressure, so letting it
    /// through throws a cursor that is correctly pinned at the edge back into
    /// view for one frame. Confirmed byte-identical (except [14]'s rolling
    /// counter) across 64 occurrences at all four edges.
    func testRealCaptureBLEEdgeBounceTemplateSuppressed() {
        var st = DecoderState()
        let b: [UInt8] = [
            26, 33, 128, 192, 136, 149, 128, 53, 2, 8,
            17, 0, 2, 8, 112, 0, 0, 0, 0, 0,
        ]
        // Guard the premise: these bytes really do decode to the phantom
        // point, so this test fails loudly if the field mapping ever moves.
        let x = Int(b[4]) | Int(b[5]) << 8 | Int(b[6] & 0x0f) << 16
        let y = Int(b[6] >> 4) | Int(b[7]) << 4 | Int(b[8]) << 12
        XCTAssertEqual(x, 38280)
        XCTAssertEqual(y, 9048)
        XCTAssertEqual(Int(b[9]) | Int(b[10]) << 8, 4360)

        XCTAssertTrue(pens(decodeBLE(b, state: &st)).isEmpty)
    }

    /// Real three-frame sequence from `ptk-870-bt-edge-bounce-right.txt`: the
    /// pen is off the right edge with X railed at `maxX`, the slot-1 template
    /// lands between two railed frames, and the cursor must not move. Guards
    /// the bounceback at the sequence level, not just the single frame.
    func testRealCaptureBLEEdgeBounceDoesNotMoveCursor() {
        var st = DecoderState()
        let railed: [UInt8] = [
            26, 2, 32, 192, 168, 16, 1, 0, 0, 0,
            0, 0, 0, 0, 16, 255, 246, 78, 0, 0,
        ]
        let bounce: [UInt8] = [
            26, 33, 128, 192, 136, 149, 128, 53, 2, 8,
            17, 0, 2, 8, 112, 0, 0, 0, 0, 0,
        ]
        let before = pens(decodeBLE(railed, state: &st))
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(before[0].x, ptk870.maxX)

        XCTAssertTrue(pens(decodeBLE(bounce, state: &st)).isEmpty)

        let after = pens(decodeBLE(railed, state: &st))
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].x, before[0].x, "cursor must stay pinned at the edge")
        XCTAssertEqual(after[0].y, before[0].y)
    }

    /// Real idle-state frame (discriminator 0x02) from `ptk-870-left.txt`
    /// with the first left ExpressKey (bit 0) pressed — buttons/dial must
    /// still decode even though no pen is in proximity.
    func testRealCaptureBLELeftExpressKeyOneDecoded() {
        var st = DecoderState()
        let b: [UInt8] = [
            26, 2, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 144, 0, 0, 0, 1, 0,
        ]
        let r = decode(b, state: &st)
        let aux = r.compactMap { res -> AuxButtons? in
            if case .aux(let a) = res { return a }; return nil
        }
        XCTAssertEqual(aux.count, 1)
        XCTAssertEqual(aux[0].buttons[0], true)
        XCTAssertTrue(aux[0].buttons[1...].allSatisfy { !$0 })
        // No pen point — packetClass is idle (0x02 & 0xfc == 0x00).
        XCTAssertTrue(r.allSatisfy { if case .pen = $0 { return false }; return true })
    }

    /// Real idle-state frame with the left dial active + clockwise
    /// (byte19 == 4: bit2 set, bit3 clear).
    func testRealCaptureBLELeftDialClockwiseEmitsWheel() {
        var st = DecoderState()
        let b: [UInt8] = [
            26, 2, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 16, 0, 0, 0, 0, 4,
        ]
        let r = decode(b, state: &st)
        let wheels = r.compactMap { res -> (Int, Int)? in
            if case .wheel(let i, let d) = res { return (i, d) }; return nil
        }
        XCTAssertEqual(wheels.count, 1)
        XCTAssertEqual(wheels.first?.0, 0)
        XCTAssertEqual(wheels.first?.1, 1)
    }

    /// Real idle-state frame with the left dial active + counter-clockwise
    /// (byte19 == 12: bits 2 and 3 both set).
    func testRealCaptureBLELeftDialCounterClockwiseEmitsWheel() {
        var st = DecoderState()
        let b: [UInt8] = [
            26, 2, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 48, 0, 0, 0, 0, 12,
        ]
        let r = decode(b, state: &st)
        let wheels = r.compactMap { res -> (Int, Int)? in
            if case .wheel(let i, let d) = res { return (i, d) }; return nil
        }
        XCTAssertEqual(wheels.count, 1)
        XCTAssertEqual(wheels.first?.0, 0)
        XCTAssertEqual(wheels.first?.1, -1)
    }

    // MARK: - 0x1B battery status

    private func batteries(_ results: [DecodeResult]) -> [(Int, Bool)] {
        results.compactMap {
            if case .battery(let pct, let charging) = $0 { return (pct, charging) }
            return nil
        }
    }

    /// 20-byte 0x1B report; only byte [1] carries data.
    private func make0x1B(_ batByte: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 20)
        b[0] = 0x1B
        b[1] = batByte
        return b
    }

    /// Real capture byte from `ptk-870-bt-edge-trace.txt`: 0x64, discharging.
    func testRealCaptureBatteryFullNotCharging() {
        var st = DecoderState()
        let r = decode(make0x1B(0x64), state: &st)
        XCTAssertEqual(batteries(r).count, 1)
        XCTAssertEqual(batteries(r).first?.0, 100)
        XCTAssertEqual(batteries(r).first?.1, false)
    }

    /// Real capture byte from the `ptk-870-bt-groove-*` set: 0xCC. Masking
    /// bit7 is what makes this a valid percentage at all — unmasked it would
    /// be 204 — and those captures were taken plugged in.
    func testRealCaptureBatteryChargingMasksHighBit() {
        var st = DecoderState()
        let r = decode(make0x1B(0xCC), state: &st)
        XCTAssertEqual(batteries(r).first?.0, 76)
        XCTAssertEqual(batteries(r).first?.1, true)
    }

    /// Real capture byte from `top.txt` / `right.txt`: 0xE4 — topped off on
    /// the cable, so 100% and charging simultaneously.
    func testRealCaptureBatteryFullWhileCharging() {
        var st = DecoderState()
        let r = decode(make0x1B(0xE4), state: &st)
        XCTAssertEqual(batteries(r).first?.0, 100)
        XCTAssertEqual(batteries(r).first?.1, true)
    }

    /// The report repeats at 1 Hz whether or not the level moved, so an
    /// unchanged byte must stay silent.
    func testBatteryEmitsOnlyOnChange() {
        var st = DecoderState()
        XCTAssertEqual(batteries(decode(make0x1B(0x61), state: &st)).count, 1)
        XCTAssertEqual(batteries(decode(make0x1B(0x61), state: &st)).count, 0)
        XCTAssertEqual(batteries(decode(make0x1B(0x60), state: &st)).count, 1)
    }

    /// Unlike the pen reports, 0x1B needs only byte [1], so a report
    /// truncated below the captured 20 bytes still decodes rather than
    /// being rejected on length.
    func testBatteryShortReportStillDecodes() {
        var st = DecoderState()
        let r = decode([0x1B, 0x64], state: &st)
        XCTAssertEqual(batteries(r).first?.0, 100)
    }

    /// Plugging in changes only bit7; the dedupe keys off the whole byte, so
    /// the charging transition must still surface at an unchanged level.
    func testBatteryChargingTransitionAtSameLevelStillEmits() {
        var st = DecoderState()
        _ = decode(make0x1B(0x64), state: &st)
        let r = decode(make0x1B(0xE4), state: &st)
        XCTAssertEqual(batteries(r).count, 1)
        XCTAssertEqual(batteries(r).first?.0, 100)
        XCTAssertEqual(batteries(r).first?.1, true)
    }

    // MARK: - 0x06 standard HID Digitizer report (CTC-4110WL)

    /// 18-byte 0x06 report, byte layout per `decodeStandardDigitizerReport`.
    /// `status` bit6=in-range, bit1=button1, bit5=eraser, bit0=tip.
    private func make0x06(
        status: UInt8, x: UInt16 = 3231, y: UInt16 = 2380, pressure: UInt16 = 0
    ) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 18)
        r[0] = 0x06
        r[1] = 0x01
        r[2] = status
        r[3] = UInt8(x & 0xFF)
        r[4] = UInt8(x >> 8)
        r[5] = UInt8(y & 0xFF)
        r[6] = UInt8(y >> 8)
        r[7] = UInt8(pressure & 0xFF)
        r[8] = UInt8(pressure >> 8)
        return r
    }

    /// Real device values from `Cyzor/tablet-driver` issue #16's discovery
    /// captures: byte 2 only ever took {0, 64, 65, 66, 96} across two
    /// sessions — 66 (0x42) is in-range | button1.
    func testRealCaptureButton1DecodedFromByte2Bit1() {
        var st = DecoderState()
        let r = decode(make0x06(status: 0x42), state: &st, spec: ctc4110wl)
        XCTAssertEqual(pens(r).first?.penButton1, true)
    }

    func testRealCaptureEraserDecodedFromByte2Bit5() {
        var st = DecoderState()
        let r = decode(make0x06(status: 0x60), state: &st, spec: ctc4110wl)
        XCTAssertEqual(pens(r).first?.eraser, true)
    }

    /// This report's own descriptor declares no second-barrel-switch usage
    /// (see the decoder's doc comment) — bit2 must stay unassigned by
    /// default, not silently read as button2.
    func testButton2NotDecodedByDefault() {
        var st = DecoderState()
        let r = decode(make0x06(status: 0x46), state: &st, spec: ctc4110wl)
        XCTAssertEqual(pens(r).first?.penButton2, false)
    }

    /// `debugButton2Source` lets a diagnostic UI point at any byte/bit; here
    /// it's pointed at the same bit2 the previous test proves is otherwise
    /// ignored, confirming the override actually takes effect.
    func testDebugButton2SourceOverridesDecodedBit() {
        var spec = ctc4110wl
        spec.debugButton2Source = .init(byteIndex: 2, bitIndex: 2)
        var st = DecoderState()
        let r = decode(make0x06(status: 0x46), state: &st, spec: spec)
        XCTAssertEqual(pens(r).first?.penButton2, true)
    }

    /// A candidate the reporter picks that isn't actually set this frame
    /// must read false, not just "some value" — proves the bit read, not
    /// just the presence of an override, drives the result.
    func testDebugButton2SourceReadsFalseWhenBitClear() {
        var spec = ctc4110wl
        spec.debugButton2Source = .init(byteIndex: 2, bitIndex: 2)
        var st = DecoderState()
        let r = decode(make0x06(status: 0x42), state: &st, spec: spec)
        XCTAssertEqual(pens(r).first?.penButton2, false)
    }

    /// An out-of-range pick (past this frame's actual length) must not trap
    /// — a reporter clicking through candidates live shouldn't be able to
    /// crash the app on a bad guess.
    func testDebugButton2SourceOutOfRangeByteIsFalseNotATrap() {
        var spec = ctc4110wl
        spec.debugButton2Source = .init(byteIndex: 99, bitIndex: 0)
        var st = DecoderState()
        let r = decode(make0x06(status: 0x42), state: &st, spec: spec)
        XCTAssertEqual(pens(r).first?.penButton2, false)
    }

    func testDebugButton2SourceOutOfRangeBitIsFalseNotATrap() {
        var spec = ctc4110wl
        spec.debugButton2Source = .init(byteIndex: 2, bitIndex: 9)
        var st = DecoderState()
        let r = decode(make0x06(status: 0x42), state: &st, spec: spec)
        XCTAssertEqual(pens(r).first?.penButton2, false)
    }

    func testRealCapturePositionAndPressureDecoded() {
        var st = DecoderState()
        let r = decode(make0x06(status: 0x41, x: 3277, y: 2391, pressure: 4), state: &st, spec: ctc4110wl)
        let p = pens(r).first
        XCTAssertEqual(p?.x, 3277)
        XCTAssertEqual(p?.y, 2391)
        XCTAssertEqual(p?.pressure, 4)
        XCTAssertEqual(p?.inProximity, true)
    }

    func testOutOfRangeSynthesizesProximityExit() {
        var st = DecoderState()
        _ = decode(make0x06(status: 0x42), state: &st, spec: ctc4110wl)
        let r = decode(make0x06(status: 0x00), state: &st, spec: ctc4110wl)
        XCTAssertEqual(pens(r).first?.inProximity, false)
    }

    // MARK: - 0x1E stub frames hold rotation

    // The PTK-870 interleaves position-only "stub" frames (status 0x80, hover
    // railed at 255, tilt and rotation zeroed) among full ones. Captures on
    // 2026-09-23 ran 61.7% stubs and one September capture ran 100%, so
    // resetting rotation to 0 on each stub collapsed the barrel angle to
    // neutral between every pair of real readings. Replaying the last real
    // value across a stub is what Wacom's own driver does (CGD16ArtPen caches
    // rotation on its transducer). See project_ptk870_stub_frame_discovery.

    /// Puts the decoder in Art Pen identity, then returns a full frame
    /// carrying `rotation`, so the tests below start from a known angle.
    private func artPenState(rotation: Int16) -> (DecoderState, Double) {
        var st = DecoderState()
        st.currentToolCode = 0x0804
        let full = make0x1E(status: 0xC0, x: 30000, y: 20000, tiltX: 20, rotation: rotation)
        let p = pens(decode(full, state: &st))
        return (st, p[0].rotation)
    }

    func test0x1EStubFrameHoldsLastRotationForArtPen() {
        var (st, first) = artPenState(rotation: -252)
        XCTAssertEqual(first, 230.4, accuracy: 1e-9, "(900 - (-252)) / 5 = 230.4")

        // Stub: proximity only, hover railed, tilt and rotation zeroed.
        let stub = make0x1E(status: 0x80, x: 30010, y: 20010, hover: 255)
        let p = pens(decode(stub, state: &st))
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(
            p[0].rotation, 230.4, accuracy: 1e-9,
            "a stub carries no rotation, so the last real angle must persist rather than snapping to 0")
    }

    func test0x1EStubRotationIsNotHeldBeforeAnyRealReading() {
        var st = DecoderState()
        st.currentToolCode = 0x0804
        // Mid-surface: a stub near an edge is swallowed by the off-surface
        // gate, which is a separate behavior from the rotation hold.
        let stub = make0x1E(status: 0x80, x: 30000, y: 20000, hover: 255)
        let p = pens(decode(stub, state: &st))
        XCTAssertEqual(
            p[0].rotation, 0.0,
            "with no real reading yet there is nothing to hold; 0 is the honest answer")
    }

    func test0x1ERotationHoldDoesNotSurviveProximityExit() {
        var (st, _) = artPenState(rotation: -252)
        // Leave proximity, then re-enter and send a stub before any real frame.
        _ = decode(make0x1E(status: 0x00, x: 30000, y: 20000), state: &st)
        let stub = make0x1E(status: 0x80, x: 30000, y: 20000, hover: 255)
        let p = pens(decode(stub, state: &st))
        XCTAssertEqual(
            p[0].rotation, 0.0,
            "the held angle belonged to the pen that left; a new tool must not inherit it")
    }

    func test0x1EStubRotationNotHeldForNonArtPen() {
        var st = DecoderState()
        st.currentToolCode = 0x0802  // Pro Pen — no barrel sensor
        _ = decode(make0x1E(status: 0xC0, x: 30000, y: 20000, rotation: -252), state: &st)
        let stub = make0x1E(status: 0x80, x: 30010, y: 20010, hover: 255)
        XCTAssertEqual(
            pens(decode(stub, state: &st))[0].rotation, 0.0,
            "a pen with no rotation sensor must stay at 0 rather than holding a decoded value")
    }

    /// Raw 0 is the tablet's "no reading this frame" filler, not a real 180°.
    /// Decoding it as an angle is what made rotation flip between extremes:
    /// every filler frame wrote a fake 180° into the cache, which then
    /// replayed across the stubs around it. Real sessions carry raw 0 on
    /// 0.3-0.9% of tip-set frames and never dwell there; a session with no
    /// Art Pen twisting at all is 95% raw 0 with a single 1346-frame run.
    func test0x1ERawZeroRotationIsFillerNotNeutral() {
        var (st, first) = artPenState(rotation: -252)
        XCTAssertEqual(first, 230.4, accuracy: 1e-9)

        let filler = make0x1E(status: 0xC0, x: 30020, y: 20020, tiltX: 20, rotation: 0)
        XCTAssertEqual(
            pens(decode(filler, state: &st))[0].rotation, 230.4, accuracy: 1e-9,
            "raw 0 carries no angle, so the last real reading must persist rather than snapping to 180°")
    }

    /// Lifting the pen and bringing the *same* one back must re-announce it.
    ///
    /// `toolChanged` compares the incoming serial against `lastSerial`, and
    /// `TabletManager` only learns the tool code from a `.toolEnter`. Leaving
    /// the serial latched across an exit meant a re-entry emitted nothing, so
    /// `activeToolCode` stayed at its 0x0802 default and apps were told an Art
    /// Pen had no rotation. Two real captures minutes apart showed exactly
    /// this: one observed 0x0804, the next observed no tool codes at all while
    /// still carrying 0x0804 in its raw frames.
    func test0x1EReEntryWithSameToolReAnnouncesIt() {
        var st = DecoderState()
        // Identity lives at bytes 20-25, past make0x1E's 20-byte frame, so
        // widen to the real 34-byte report length before writing it.
        func frame(_ status: UInt8) -> [UInt8] {
            var b = make0x1E(status: status, x: 30000, y: 20000)
            b.append(contentsOf: [UInt8](repeating: 0, count: 34 - b.count))
            b[20] = 0xCE; b[21] = 0x00; b[22] = 0x80; b[23] = 0x03  // serial 0x038000CE
            b[24] = 0x04; b[25] = 0x08  // tool code 0x0804
            return b
        }
        func toolEnters(_ r: [DecodeResult]) -> [ToolIdentity] {
            r.compactMap { if case .toolEnter(let t) = $0 { return t } else { return nil } }
        }

        let first = toolEnters(decode(frame(0xC0), state: &st))
        XCTAssertEqual(first.count, 1, "first approach must announce the tool")
        XCTAssertEqual(first.first?.toolCode, 0x0804)

        // Same pen, still in range: must not re-announce on every frame.
        XCTAssertTrue(
            toolEnters(decode(frame(0xC0), state: &st)).isEmpty,
            "a tool already in range must not re-announce per frame")

        // Lift out of proximity, then bring the same pen back.
        _ = decode(make0x1E(status: 0x00, x: 30000, y: 20000), state: &st)
        let second = toolEnters(decode(frame(0xC0), state: &st))
        XCTAssertEqual(
            second.count, 1,
            "re-entry must re-announce, or the injector never learns the tool code again")
        XCTAssertEqual(second.first?.toolCode, 0x0804)
        XCTAssertEqual(second.first?.serial, 0x038000CE)
    }

    /// The counterpart: a nonzero count always wins, including one that
    /// decodes near neutral, so a genuinely centred barrel still reports.
    func test0x1ENonZeroRotationOverwritesHeldValue() {
        var (st, _) = artPenState(rotation: -252)
        // raw 1 -> (900 - 1) / 5 = 179.8, a real reading just off neutral.
        let real = make0x1E(status: 0xC0, x: 30020, y: 20020, tiltX: 20, rotation: 1)
        XCTAssertEqual(
            pens(decode(real, state: &st))[0].rotation, 179.8, accuracy: 1e-9,
            "a frame that carries a count must replace the held angle")
    }
}
