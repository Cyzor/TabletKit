// SPDX-License-Identifier: GPL-3.0-or-later
//
// Xencelabs Pen Tablet / Pen Display decoder fixtures.
//
// Layout confirmed 2026-07-02 from 10k+ live report-2 frames captured off a
// real Xencelabs Pen Display (both pens, driver present and absent): tag
// bitfield at byte 1 (bit0 tip, bits1–3 barrel buttons, bit4 aux/puck,
// bit6 eraser, bit7 driver-initialized, 0xC0 out of range), X/Y/pressure as
// u16 LE at bytes 2/4/6, signed-byte tilt at 8/9. The hex fixtures below are
// verbatim frames from those captures. Report ID 7 (the bit-packed digitizer
// collection an earlier decoder revision targeted) never carries live data
// and must be ignored.
import XCTest
@testable import TabletKit

final class XencelabsDecoderTests: XCTestCase {

    private let display = DigitizerSpec(
        maxX: 65535, maxY: 65535, maxPressure: 8191,
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
        tag: UInt8, x: UInt16 = 0, y: UInt16 = 0, pressure: UInt16 = 0,
        tiltX: Int8 = 0, tiltY: Int8 = 0
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = 0x02
        bytes[1] = tag
        bytes[2] = UInt8(x & 0xFF); bytes[3] = UInt8(x >> 8)
        bytes[4] = UInt8(y & 0xFF); bytes[5] = UInt8(y >> 8)
        bytes[6] = UInt8(pressure & 0xFF); bytes[7] = UInt8(pressure >> 8)
        bytes[8] = UInt8(bitPattern: tiltX)
        bytes[9] = UInt8(bitPattern: tiltY)
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

    /// Right-edge overflow captured live 2026-07-02: a slow drag off the
    /// physical right edge climbs steadily to x=65469, then the very next
    /// sample reads x=13 — a raw mod-65536 wraparound in the wire field,
    /// not a real jump back to the left edge. Left uncorrected this snapped
    /// the cursor across the whole screen ("Pac-Man" wraparound).
    func testRightEdgeWireWraparoundClampsToMax() {
        var state = DecoderState()
        _ = decode(makePen(tag: 0x20, x: 65469, y: 24833), state: &state)
        let results = decode(makePen(tag: 0x20, x: 13, y: 24824), state: &state)
        guard let p = penPoint(results) else { return XCTFail("no pen result") }
        XCTAssertEqual(p.x, 65535)
    }

    /// Captured live 2026-07-02 (xencelabs-middle-to-right-edge.txt): held off
    /// the physical edge after a wrap, the raw wire value keeps free-running
    /// upward for hundreds of samples (still climbing ~50/sample) rather than
    /// saturating, eventually crossing back over the halfway threshold a
    /// one-shot clamp would use to decide "this looks real again" — while the
    /// pen is still off the drawable surface the whole time. The edge latch
    /// must hold through that entire climb and only release on proximity
    /// loss/re-entry, not once the creeping value looks plausible again.
    func testEdgeLatchHoldsThroughSustainedWireCreepAfterWrap() {
        var state = DecoderState()
        _ = decode(makePen(tag: 0x20, x: 65516, y: 27358), state: &state)
        // The wrap itself.
        var results = decode(makePen(tag: 0x20, x: 23, y: 27358), state: &state)
        XCTAssertEqual(penPoint(results)?.x, 65535)
        // Simulate the creep climbing for hundreds of samples, well past
        // where a one-shot delta clamp would have released (maxX/2).
        var creepingX: UInt16 = 23
        for _ in 0..<900 {
            creepingX = creepingX &+ 50
            results = decode(makePen(tag: 0x20, x: creepingX, y: 27358), state: &state)
        }
        XCTAssertEqual(penPoint(results)?.x, 65535, "latch must hold despite the raw value creeping back above maxX/2")
        // A genuine proximity loss + re-entry releases the latch.
        _ = decode(makePen(tag: 0xC0), state: &state)
        results = decode(makePen(tag: 0x20, x: 39464, y: 26991), state: &state)
        XCTAssertEqual(penPoint(results)?.x, 39464)
    }

    /// Same wraparound, mirrored at the left/top edge (synthetic — the sensor
    /// wrapping the other direction hasn't been captured live, but the guard
    /// is symmetric by construction).
    func testLeftEdgeWireWraparoundClampsToZero() {
        var state = DecoderState()
        _ = decode(makePen(tag: 0x20, x: 60, y: 100), state: &state)
        let results = decode(makePen(tag: 0x20, x: 65500, y: 100), state: &state)
        guard let p = penPoint(results) else { return XCTFail("no pen result") }
        XCTAssertEqual(p.x, 0)
    }

    /// A large jump right after entering proximity must not be clamped —
    /// there's no valid "previous" position to compare against yet.
    func testWraparoundGuardDoesNotFireOnProximityEnter() {
        var state = DecoderState()
        let results = decode(makePen(tag: 0x20, x: 65000, y: 100), state: &state)
        guard let p = penPoint(results) else { return XCTFail("no pen result") }
        XCTAssertEqual(p.x, 65000)
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

    // MARK: - QuickKeys puck (aux frames)

    /// Verbatim captured one-hot button frames: byte 2 bits 0–7 are puck
    /// buttons 1–8, byte 3 bits 0–1 are buttons 9–10.
    func testPuckButtonsDecodeOneHot() {
        var state = DecoderState()
        var press = makePen(tag: 0xF0)
        press[2] = 0x10 // button 5
        guard let a = auxButtons(decode(press, state: &state)) else { return XCTFail("no aux result") }
        XCTAssertEqual(a.buttons.count, 10)
        XCTAssertTrue(a.buttons[4])
        XCTAssertEqual(a.buttons.filter { $0 }.count, 1)

        var press9 = makePen(tag: 0xF0)
        press9[3] = 0x01 // button 9
        XCTAssertEqual(auxButtons(decode(press9, state: &state))?.buttons[8], true)

        // All-zero frame = release.
        let release = auxButtons(decode(makePen(tag: 0xF0), state: &state))
        XCTAssertEqual(release?.buttons.contains(true), false)
    }

    /// Dial rotation: byte 7 = 1 or 2, one event per click.
    func testPuckDialEmitsWheelSteps() {
        var state = DecoderState()
        var cw = makePen(tag: 0xF0)
        cw[7] = 0x01
        var results = decode(cw, state: &state)
        XCTAssertTrue(results.contains { if case .wheel(0, 1) = $0 { return true } else { return false } })
        var ccw = makePen(tag: 0xF0)
        ccw[7] = 0x02
        results = decode(ccw, state: &state)
        XCTAssertTrue(results.contains { if case .wheel(0, -1) = $0 { return true } else { return false } })
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
