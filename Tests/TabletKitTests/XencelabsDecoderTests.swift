// SPDX-License-Identifier: GPL-3.0-or-later
//
// Xencelabs Pen Tablet / Pen Display decoder fixtures.
//
// Layout confirmed 2026-07-02 from 10k+ live report-2 frames captured off a
// real Xencelabs Pen Display (both pens, driver present and absent): tag
// bitfield at byte 1 (bit0 tip, bits1–3 barrel buttons, bit4 aux/puck,
// bit6 eraser, bit7 driver-initialized, 0xC0 out of range), X/Y as 24-bit LE
// (low words at bytes 2/4, high bytes at 10/11 — the Pen Display's X range
// of 0–105000 needs the third byte), pressure u16 LE at 6, signed-byte tilt
// at 8/9. The hex fixtures below are verbatim frames from those captures.
// Report ID 7 (the bit-packed digitizer collection an earlier decoder
// revision targeted) never carries live data and must be ignored.
import XCTest
@testable import TabletKit

final class XencelabsDecoderTests: XCTestCase {

    private let display = DigitizerSpec(
        maxX: 105000, maxY: 59000, maxPressure: 8191,
        buttonCount: 3, hasTilt: true)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState
    ) -> [DecodeResult] {
        var decoder = XencelabsDecoder()
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: display, state: &state, deviceFamily: "xencelabs")
        }
    }

    /// Builds a 32-byte Report ID 2 frame in the confirmed layout.
    private func makePen(
        tag: UInt8, x: UInt32 = 0, y: UInt32 = 0, pressure: UInt16 = 0,
        tiltX: Int8 = 0, tiltY: Int8 = 0
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = 0x02
        bytes[1] = tag
        bytes[2] = UInt8(x & 0xFF); bytes[3] = UInt8((x >> 8) & 0xFF)
        bytes[4] = UInt8(y & 0xFF); bytes[5] = UInt8((y >> 8) & 0xFF)
        bytes[6] = UInt8(pressure & 0xFF); bytes[7] = UInt8(pressure >> 8)
        bytes[8] = UInt8(bitPattern: tiltX)
        bytes[9] = UInt8(bitPattern: tiltY)
        bytes[10] = UInt8((x >> 16) & 0xFF)
        bytes[11] = UInt8((y >> 16) & 0xFF)
        return bytes
    }

    /// Parses a space-separated hex string (verbatim capture line) into bytes.
    private func frame(_ hex: String) -> [UInt8] {
        hex.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    private func penPoint(_ results: [DecodeResult]) -> TabletPoint? {
        for r in results { if case .pen(let p) = r { return p } }
        return nil
    }

    private func auxButtons(_ results: [DecodeResult]) -> AuxButtons? {
        for r in results { if case .aux(let a) = r { return a } }
        return nil
    }

    // MARK: - Verbatim captured frames

    /// Driverless hover frame from xencelabs-pressure.txt.
    func testCapturedHoverFrame() {
        var state = DecoderState()
        let results = decode(
            frame("02 20 d5 05 a1 e3 00 00 11 21 00 00 47 38 43 35 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"),
            state: &state)
        guard let p = penPoint(results) else { return XCTFail("no pen result") }
        XCTAssertTrue(p.inProximity)
        XCTAssertEqual(p.x, 0x05d5)
        XCTAssertEqual(p.y, 0xe3a1)
        XCTAssertEqual(p.pressure, 0)
        XCTAssertFalse(p.eraser)
        // tilt 0x11 = +17°, 0x21 = +33° against the ±60° scale
        XCTAssertEqual(p.tiltX, 17.0 / 60.0, accuracy: 0.001)
        XCTAssertEqual(p.tiltY, 33.0 / 60.0, accuracy: 0.001)
    }

    /// Pen-down frame (tag 0x21) from the confirmed pressure-onset sequence.
    func testCapturedPenDownFrame() {
        var state = DecoderState()
        let results = decode(
            frame("02 21 41 04 fe e3 17 00 00 23 00 00 47 38 43 35 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"),
            state: &state)
        guard let p = penPoint(results) else { return XCTFail("no pen result") }
        XCTAssertEqual(p.pressure, 0x17)
        XCTAssertTrue(p.inProximity)
    }

    /// Driver-initialized barrel-button frame (tag 0xa4) from
    /// xencelabs-native-input.txt — bit7 must not change pen decoding.
    func testCapturedBarrelButtonFrame() {
        var state = DecoderState()
        let results = decode(
            frame("02 a4 e1 1c 99 d1 00 00 13 13 01 00 47 38 43 35 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"),
            state: &state)
        guard let p = penPoint(results) else { return XCTFail("no pen result") }
        XCTAssertTrue(p.penButton1)
        XCTAssertFalse(p.penButton2)
        XCTAssertFalse(p.penButton3)
        XCTAssertFalse(p.eraser)
    }

    // MARK: - Pen path

    func testToolEnterFiresOnRisingEdgeOnly() {
        var state = DecoderState()
        let first = decode(makePen(tag: 0x20, x: 100, y: 100), state: &state)
        XCTAssertTrue(first.contains { if case .toolEnter(let t) = $0 { return !t.isEraser && !t.isMouse } else { return false } })
        let second = decode(makePen(tag: 0x20, x: 101, y: 101), state: &state)
        XCTAssertFalse(second.contains { if case .toolEnter = $0 { return true } else { return false } })
    }

    func testFullPressureDecodes8191() {
        var state = DecoderState()
        let results = decode(makePen(tag: 0x21, x: 1, y: 1, pressure: 8191), state: &state)
        XCTAssertEqual(penPoint(results)?.pressure, 8191)
        XCTAssertEqual(penPoint(results)?.normalizedPressure ?? 0, 1.0, accuracy: 0.001)
    }

    func testEraserBitSetsEraserAndToolIdentity() {
        var state = DecoderState()
        // 0x61 = eraser + tip, verbatim tag from both pens' captures.
        let results = decode(makePen(tag: 0x61, x: 5, y: 5, pressure: 1000), state: &state)
        XCTAssertEqual(penPoint(results)?.eraser, true)
        XCTAssertTrue(results.contains { if case .toolEnter(let t) = $0 { return t.isEraser } else { return false } })
    }

    func testPenToEraserFlipReemitsToolEnter() {
        var state = DecoderState()
        _ = decode(makePen(tag: 0x20, x: 1, y: 1), state: &state)
        let flipped = decode(makePen(tag: 0x60, x: 1, y: 1), state: &state)
        XCTAssertTrue(flipped.contains { if case .toolEnter(let t) = $0 { return t.isEraser } else { return false } })
    }

    /// Tag bits 1–3 are the three barrel buttons by physical position: the
    /// slim pen uses bits 2–3 (penButton1/2); the 3-button pen adds bit 1,
    /// mapped to penButton3.
    func testBarrelButtonsMapToTagBits() {
        var state = DecoderState()
        _ = decode(makePen(tag: 0x20), state: &state)
        let b1 = penPoint(decode(makePen(tag: 0x24), state: &state))
        XCTAssertEqual(b1?.penButton1, true)
        XCTAssertEqual(b1?.penButton2, false)
        XCTAssertEqual(b1?.penButton3, false)
        let b2 = penPoint(decode(makePen(tag: 0x28), state: &state))
        XCTAssertEqual(b2?.penButton1, false)
        XCTAssertEqual(b2?.penButton2, true)
        let b3 = penPoint(decode(makePen(tag: 0x22), state: &state))
        XCTAssertEqual(b3?.penButton3, true)
        XCTAssertEqual(b3?.penButton1, false)
    }

    func testTiltNormalizesAgainstSixtyDegrees() {
        var state = DecoderState()
        let results = decode(makePen(tag: 0x20, tiltX: 60, tiltY: -30), state: &state)
        guard let p = penPoint(results) else { return XCTFail("no pen result") }
        XCTAssertEqual(p.tiltX, 1.0, accuracy: 0.001)
        XCTAssertEqual(p.tiltY, -0.5, accuracy: 0.001)
    }

    /// Verbatim adjacent frames from a live mid-screen right sweep
    /// (xencelabs-middle-to-right-edge.txt): the low X word wraps 65516→23
    /// while byte 10 flips 0→1. Reading only 16 bits made X wrap mod 65536
    /// in the middle of the screen ("Pac-Man" cursor); with the high byte
    /// the coordinates are continuous.
    func testXHighByteDecodesContinuouslyAcrossLowWordWrap() {
        var state = DecoderState()
        let before = penPoint(decode(
            frame("02 20 ec ff de 6a 00 00 1c 11 00 00 47 38 43 35 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"),
            state: &state))
        let after = penPoint(decode(
            frame("02 20 17 00 de 6a 00 00 1c 11 01 00 47 38 43 35 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"),
            state: &state))
        XCTAssertEqual(before?.x, 65516)
        XCTAssertEqual(after?.x, 65536 + 23)
        XCTAssertEqual(after?.y, 0x6ade)
    }

    /// The right-edge maximum observed live is a round firmware clamp at
    /// exactly 105000 (byte 10 = 1, low word = 105000 - 65536 = 39464).
    func testFullRangeXDecodesToFirmwareCeiling() {
        var state = DecoderState()
        let results = decode(makePen(tag: 0x20, x: 105000, y: 59000), state: &state)
        guard let p = penPoint(results) else { return XCTFail("no pen result") }
        XCTAssertEqual(p.x, 105000)
        XCTAssertEqual(p.y, 59000)
    }

    /// Values past the spec maxima (never observed live — firmware clamps
    /// first) must not escape the spec'd range.
    func testCoordinatesClampToSpecMaxima() {
        var state = DecoderState()
        let results = decode(makePen(tag: 0x20, x: 120000, y: 70000), state: &state)
        guard let p = penPoint(results) else { return XCTFail("no pen result") }
        XCTAssertEqual(p.x, 105000)
        XCTAssertEqual(p.y, 59000)
    }

    func testProximityExitEmitsExitPointAtLastPosition() {
        var state = DecoderState()
        _ = decode(makePen(tag: 0x20, x: 300, y: 400), state: &state)
        let results = decode(makePen(tag: 0xC0), state: &state)
        guard let p = penPoint(results) else { return XCTFail("no exit point") }
        XCTAssertFalse(p.inProximity)
        XCTAssertEqual(p.x, 300)
        XCTAssertEqual(p.y, 400)
        XCTAssertEqual(p.pressure, 0)
        // Repeated out-of-range frames stay silent.
        XCTAssertTrue(decode(makePen(tag: 0xC0), state: &state).isEmpty)
    }

    /// Verbatim vendor feature-report echoes captured off a Pen Display's own
    /// init handshake (2026-07-05): 0xb4/0xb5 opcodes happen to have bit 4 set,
    /// which used to make decodeAux() misread them as a QuickKeys aux frame
    /// and latch a phantom express-key/mode-button press — with no puck even
    /// connected. Must decode to nothing.
    func testConfigEchoFramesAreNotMisreadAsAux() {
        var state = DecoderState()
        let echo1 = frame("02 b5 00 10 06 01 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        XCTAssertTrue(decode(echo1, state: &state).isEmpty)
        let echo2 = frame("02 b5 00 05 09 00 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        XCTAssertTrue(decode(echo2, state: &state).isEmpty)
        let echo3 = frame("02 b4 01 01 00 00 aa 2b 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        XCTAssertTrue(decode(echo3, state: &state).isEmpty)
    }

    /// Verbatim frame captured off the wireless dongle's own connect-time
    /// status/announcement traffic (2026-07-06): tag 0xF8 shares bit 4 (the
    /// aux-frame bit) with real button data (tag 0xF0) but isn't a button
    /// press. Used to decode as a phantom express-key + mode button press
    /// with no matching release, sticking a mapped modifier down. Must
    /// decode to nothing.
    func testDongleStatusFrameIsNotMisreadAsAux() {
        var state = DecoderState()
        let status1 = frame("02 f8 02 01 20 00 00 00 00 00 aa 67 82 b9 35 f4 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        XCTAssertTrue(decode(status1, state: &state).isEmpty)
    }

    /// The frame previously filed alongside the dongle status frame above
    /// (tag 0xF2, byte[2] == 0x01, byte[3] == 0x63 == 99) isn't a status/
    /// announcement frame at all — it's the solicited battery GET reply
    /// (confirmed 2026-07-14 via a live capture against a wireless puck,
    /// where byte[3] == 0x5a == 90% matched the reported charge level).
    /// Must decode to `.battery(percent: 99, charging: false)`.
    func testBatteryReplyDecodesPercent() {
        var state = DecoderState()
        let reply = frame("02 f2 01 63 00 00 00 00 00 00 00 00 aa 67 82 b9 35 f4 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        let results = decode(reply, state: &state)
        XCTAssertEqual(results.count, 1)
        guard case .battery(let percent, let charging) = results.first else {
            return XCTFail("expected .battery result")
        }
        XCTAssertEqual(percent, 99)
        XCTAssertFalse(charging)
    }

    // MARK: - QuickKeys puck (aux frames)

    /// Verbatim captured one-hot button frames: byte 2 bits 0–7 are puck
    /// buttons 1–8, byte 3 bits 0–1 are buttons 9–10.
    func testPuckButtonsDecodeOneHot() {
        var state = DecoderState()
        var press = makePen(tag: 0xF0)
        press[2] = 0x10 // button 5
        guard let a = auxButtons(decode(press, state: &state)) else { return XCTFail("no aux result") }
        XCTAssertEqual(a.buttons.count, 9)
        XCTAssertTrue(a.buttons[4])
        XCTAssertEqual(a.buttons.filter { $0 }.count, 1)
        XCTAssertFalse(a.touchRingButtonDown)

        var pressMode = makePen(tag: 0xF0)
        pressMode[3] = 0x01 // bottom mode button
        XCTAssertEqual(auxButtons(decode(pressMode, state: &state))?.buttons[8], true)

        // Dial center click reports via touchRingButtonDown, not the array.
        var pressDialCenter = makePen(tag: 0xF0)
        pressDialCenter[3] = 0x02
        let dialCenter = auxButtons(decode(pressDialCenter, state: &state))
        XCTAssertEqual(dialCenter?.touchRingButtonDown, true)
        XCTAssertEqual(dialCenter?.buttons.contains(true), false)

        // All-zero frame = release.
        let release = auxButtons(decode(makePen(tag: 0xF0), state: &state))
        XCTAssertEqual(release?.buttons.contains(true), false)
        XCTAssertEqual(release?.touchRingButtonDown, false)
    }

    /// Dial rotation: byte 7 = 1 (CCW) or 2 (CW), one event per click. Positive
    /// delta means physically clockwise (confirmed on hardware 2026-08-06).
    func testPuckDialEmitsWheelSteps() {
        var state = DecoderState()
        var ccw = makePen(tag: 0xF0)
        ccw[7] = 0x01
        var results = decode(ccw, state: &state)
        XCTAssertTrue(results.contains { if case .wheel(0, -1) = $0 { return true } else { return false } })
        var cw = makePen(tag: 0xF0)
        cw[7] = 0x02
        results = decode(cw, state: &state)
        XCTAssertTrue(results.contains { if case .wheel(0, 1) = $0 { return true } else { return false } })
    }

    /// Aux frames must not disturb pen proximity state.
    func testAuxFrameDoesNotAffectPenState() {
        var state = DecoderState()
        _ = decode(makePen(tag: 0x20, x: 10, y: 10), state: &state)
        _ = decode(makePen(tag: 0xF0), state: &state)
        XCTAssertTrue(state.prevInProximity)
        // Next pen frame does not re-fire toolEnter.
        let next = decode(makePen(tag: 0x20, x: 11, y: 11), state: &state)
        XCTAssertFalse(next.contains { if case .toolEnter = $0 { return true } else { return false } })
    }

    // MARK: - Report-ID isolation

    /// Report ID 7 (the declared-but-unused digitizer collection) and other
    /// report IDs must be ignored — only report 2 carries live data.
    func testNonVendorReportIDsAreIgnored() {
        var state = DecoderState()
        var report7 = [UInt8](repeating: 0, count: 10)
        report7[0] = 0x07
        report7[1] = 0x25 // inRange + tip in the report-7 bit layout
        XCTAssertTrue(decode(report7, state: &state).isEmpty)
    }

    // MARK: - Robustness

    func testShortReportsRejected() {
        var state = DecoderState()
        XCTAssertTrue(decode([0x02], state: &state).isEmpty)
        XCTAssertTrue(decode([0x02, 0x21, 0, 0, 0], state: &state).isEmpty)
    }
}
