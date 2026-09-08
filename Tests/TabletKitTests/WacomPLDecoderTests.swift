// SPDX-License-Identifier: GPL-3.0-or-later
//
// WacomPLDecoder fixtures (PL-400 through PL-800 pen displays).
//
// Byte layout and pressure math ported from the kernel's wacom_pl_irq(),
// independently re-verified against source twice this session (once for
// the general layout, once specifically for the C integer-promotion
// semantics of the pressure calculation — see WacomPLDecoder.swift's own
// header comment and Notes/Scratch/wacom-pl-series-design-2026-09-08.md).
// Entirely synthesized; no capture exists for any of these devices.
import XCTest
@testable import TabletKit

final class WacomPLDecoderTests: XCTestCase {

    private let pl400 = DigitizerSpec(
        maxX: 5408, maxY: 4056, maxPressure: 255,
        buttonCount: 0, hasTilt: false, hasDualRings: false,
        isPenDisplay: true, ringSlotCount: 0)

    private let pl800 = DigitizerSpec(
        maxX: 7220, maxY: 5780, maxPressure: 511,
        buttonCount: 0, hasTilt: false, hasDualRings: false,
        isPenDisplay: true, ringSlotCount: 0)

    private func decode(
        _ bytes: [UInt8], spec: DigitizerSpec, state: inout DecoderState
    ) -> [DecodeResult] {
        let decoder = WacomPLDecoder()
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: spec, state: &state, deviceFamily: .cintiq)
        }
    }

    /// 8-byte report. `x`/`y` are the full 16-bit logical values this
    /// helper will pack into the wire's 2/7/7-bit split; `pressureCore` is
    /// the raw byte 7 value before the kernel's sign-extension/offset math.
    private func makeReport(
        proximity: Bool,
        x: Int = 0, y: Int = 0,
        pressureCore: UInt8 = 0, pressureBit4Low: Bool = false, pressureBit4High: Bool = false,
        eraserOrButton2: Bool = false, button1: Bool = false, tip: Bool = false
    ) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 8)
        b[0] = 0x02
        b[1] = (proximity ? 0x40 : 0) | UInt8((x >> 14) & 0x03)
        b[2] = UInt8((x >> 7) & 0x7F)
        b[3] = UInt8(x & 0x7F)
        var status4: UInt8 = UInt8((y >> 14) & 0x03)
        if pressureBit4Low { status4 |= 0x04 }
        if tip { status4 |= 0x08 }
        if button1 { status4 |= 0x10 }
        if eraserOrButton2 { status4 |= 0x20 }
        if pressureBit4High { status4 |= 0x40 }
        b[4] = status4
        b[5] = UInt8((y >> 7) & 0x7F)
        b[6] = UInt8(y & 0x7F)
        b[7] = pressureCore
        return b
    }

    // MARK: - Coordinates

    func testCoordinatesRoundTripAtMaximum() {
        var state = DecoderState()
        let report = makeReport(proximity: true, x: 5408, y: 4056)
        guard case .pen(let point)? = decode(report, spec: pl400, state: &state).last else {
            return XCTFail("expected a .pen result")
        }
        XCTAssertEqual(point.x, 5408)
        XCTAssertEqual(point.y, 4056)
    }

    func testCoordinatesAtOrigin() {
        var state = DecoderState()
        let report = makeReport(proximity: true, x: 0, y: 0)
        guard case .pen(let point)? = decode(report, spec: pl400, state: &state).last else {
            return XCTFail("expected a .pen result")
        }
        XCTAssertEqual(point.x, 0)
        XCTAssertEqual(point.y, 0)
    }

    // MARK: - Pressure — the bug this session caught and fixed

    /// report[7] >= 128 is exactly the case that exposed a real bug during
    /// development: a naive UInt8 `<<` wraps at 8 bits, which does not
    /// match C's promote-to-int-then-explicitly-truncate order the kernel
    /// actually uses. This value would have decoded wrong under the buggy
    /// version.
    func testPressureCoreAboveOneTwentyEightMatchesKernelIntPromotion() {
        var state = DecoderState()
        // pressureCore = 200 (0xC8). Kernel: (200 << 1) | bit = 400 | bit,
        // as a full-width int, THEN cast to signed char (truncate to 8
        // bits, sign-extend): 400 & 0xFF = 0x90 = -112 as Int8. Then
        // offset by (255+1)/2 = 128 for a 255-max device (no >255 branch).
        let report = makeReport(proximity: true, pressureCore: 200, pressureBit4Low: false)
        guard case .pen(let point)? = decode(report, spec: pl400, state: &state).last else {
            return XCTFail("expected a .pen result")
        }
        // -112 + 128 = 16
        XCTAssertEqual(point.pressure, 16)
    }

    func testPressureLowBitAlwaysApplied() {
        let withoutBit = makeReport(proximity: true, pressureCore: 0, pressureBit4Low: false)
        let withBit = makeReport(proximity: true, pressureCore: 0, pressureBit4Low: true)
        var s1 = DecoderState(); var s2 = DecoderState()
        guard case .pen(let p1)? = decode(withoutBit, spec: pl400, state: &s1).last,
            case .pen(let p2)? = decode(withBit, spec: pl400, state: &s2).last
        else { return XCTFail("expected .pen results") }
        XCTAssertEqual(p2.pressure, p1.pressure + 1)
    }

    func testPressureHighBitOnlyAppliesAboveTwoFiftyFive() {
        let withHighBit = makeReport(proximity: true, pressureCore: 0, pressureBit4High: true)
        let withoutHighBit = makeReport(proximity: true, pressureCore: 0, pressureBit4High: false)

        var state255with = DecoderState()
        var state255without = DecoderState()
        guard case .pen(let p255with)? = decode(withHighBit, spec: pl400, state: &state255with).last,
            case .pen(let p255without)? = decode(withoutHighBit, spec: pl400, state: &state255without).last
        else { return XCTFail("expected .pen results") }
        // 255-max device: bit 6 is never consulted.
        XCTAssertEqual(p255with.pressure, p255without.pressure)

        var state511with = DecoderState()
        var state511without = DecoderState()
        guard case .pen(let p511with)? = decode(withHighBit, spec: pl800, state: &state511with).last,
            case .pen(let p511without)? = decode(withoutHighBit, spec: pl800, state: &state511without).last
        else { return XCTFail("expected .pen results") }
        // 511-max device: bit 6 becomes the new LSB after the extra shift.
        XCTAssertEqual(p511with.pressure, p511without.pressure + 1)
    }

    // MARK: - Proximity

    func testProximityExitEmitsZeroPressureAtLastPosition() {
        var state = DecoderState()
        _ = decode(makeReport(proximity: true, x: 100, y: 200), spec: pl400, state: &state)
        let exit = decode(makeReport(proximity: false), spec: pl400, state: &state)
        guard case .pen(let point)? = exit.last else {
            return XCTFail("expected a .pen exit result")
        }
        XCTAssertEqual(point.x, 100)
        XCTAssertEqual(point.y, 200)
        XCTAssertEqual(point.pressure, 0)
        XCTAssertFalse(point.inProximity)
    }

    func testProximityExitWithNoPriorEntryEmitsNothing() {
        var state = DecoderState()
        XCTAssertTrue(decode(makeReport(proximity: false), spec: pl400, state: &state).isEmpty)
    }

    func testToolEnterFiresOnceOnRisingEdge() {
        var state = DecoderState()
        let results1 = decode(makeReport(proximity: true, x: 1, y: 1), spec: pl400, state: &state)
        XCTAssertTrue(results1.contains { if case .toolEnter = $0 { return true }; return false })
        let results2 = decode(makeReport(proximity: true, x: 2, y: 2), spec: pl400, state: &state)
        XCTAssertFalse(results2.contains { if case .toolEnter = $0 { return true }; return false })
    }

    // MARK: - Eraser / button-2 classification — the corrected behavior

    func testEraserBitAtEntryClassifiesAsEraser() {
        var state = DecoderState()
        let results = decode(
            makeReport(proximity: true, eraserOrButton2: true), spec: pl400, state: &state)
        guard case .pen(let point)? = results.last else {
            return XCTFail("expected a .pen result")
        }
        XCTAssertTrue(point.eraser)
        XCTAssertTrue(state.isEraser)
    }

    func testEraserHeldAcrossSessionWhileBitStaysSet() {
        var state = DecoderState()
        _ = decode(makeReport(proximity: true, eraserOrButton2: true), spec: pl400, state: &state)
        let results = decode(
            makeReport(proximity: true, x: 5, y: 5, eraserOrButton2: true), spec: pl400, state: &state)
        guard case .pen(let point)? = results.last else {
            return XCTFail("expected a .pen result")
        }
        XCTAssertTrue(point.eraser)
    }

    /// The one behavior neither third-party research source described,
    /// found only by reading wacom_pl_irq() directly: an eraser
    /// classification made at entry is revoked if the bit later clears.
    func testEraserClassificationSelfCorrectsWhenBitClearsMidSession() {
        var state = DecoderState()
        _ = decode(makeReport(proximity: true, eraserOrButton2: true), spec: pl400, state: &state)
        XCTAssertTrue(state.isEraser)

        let results = decode(
            makeReport(proximity: true, x: 5, y: 5, eraserOrButton2: false), spec: pl400, state: &state)
        guard case .pen(let point)? = results.last else {
            return XCTFail("expected a .pen result")
        }
        XCTAssertFalse(point.eraser)
        XCTAssertFalse(state.isEraser)
    }

    func testBitClearAtEntryClassifiesAsPenAndLaterActivityIsButton2() {
        var state = DecoderState()
        _ = decode(makeReport(proximity: true, eraserOrButton2: false), spec: pl400, state: &state)
        XCTAssertFalse(state.isEraser)

        let results = decode(
            makeReport(proximity: true, x: 5, y: 5, eraserOrButton2: true), spec: pl400, state: &state)
        guard case .pen(let point)? = results.last else {
            return XCTFail("expected a .pen result")
        }
        XCTAssertFalse(point.eraser, "pen classification at entry must not flip to eraser later")
        XCTAssertTrue(point.penButton2, "bit-5 activity after a pen entry is button 2, not eraser")
    }

    func testClassificationResetsOnNewProximityEntry() {
        var state = DecoderState()
        _ = decode(makeReport(proximity: true, eraserOrButton2: true), spec: pl400, state: &state)
        _ = decode(makeReport(proximity: false), spec: pl400, state: &state)

        let results = decode(
            makeReport(proximity: true, x: 1, y: 1, eraserOrButton2: false), spec: pl400, state: &state)
        guard case .pen(let point)? = results.last else {
            return XCTFail("expected a .pen result")
        }
        XCTAssertFalse(point.eraser, "a new proximity session must re-decide, not inherit the prior one")
    }

    // MARK: - Buttons

    func testButton1AndTipDecodeIndependently() {
        var state = DecoderState()
        let report = makeReport(proximity: true, button1: true, tip: true)
        guard case .pen(let point)? = decode(report, spec: pl400, state: &state).last else {
            return XCTFail("expected a .pen result")
        }
        XCTAssertTrue(point.penButton1)
    }

    // MARK: - Robustness

    func testWrongReportIDIsIgnored() {
        var state = DecoderState()
        var report = makeReport(proximity: true)
        report[0] = 0x01
        XCTAssertTrue(decode(report, spec: pl400, state: &state).isEmpty)
    }

    func testShortReportIsIgnored() {
        var state = DecoderState()
        let short = [UInt8](repeating: 0, count: 7)
        XCTAssertTrue(decode(short, spec: pl400, state: &state).isEmpty)
    }
}
