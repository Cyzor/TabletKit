// SPDX-License-Identifier: GPL-3.0-or-later
//
// Xencelabs Pen Tablet / Pen Display decoder fixtures.
//
// The bit layout here is confirmed from a live HID report descriptor
// captured off a real Xencelabs Pen Display 2026-07-01 (Report ID 7, usage
// page 0x0D): six 1-bit flags, then 16-bit X, 16-bit Y, 16-bit pressure,
// signed 8-bit tilt X, signed 8-bit tilt Y — all bit-packed (X starts at bit
// offset 6, not byte offset 2). Pen Tablet Medium/Small are assumed to share
// this layout pending their own hardware confirmation.
//
// Report ID 2 (32-byte vendor report, express keys / wheels / touch ring) is
// not yet decoded — this device streams it concurrently with report 7 at
// high frequency, and feeding it into the pen decoder previously produced
// chaotic, unsteerable cursor motion. The decoder now ignores anything that
// isn't report 7; `testNonPenReportIDsAreIgnored` locks that in.
import XCTest
@testable import TabletKit

final class XencelabsDecoderTests: XCTestCase {

    private let display = DigitizerSpec(
        maxX: 22352, maxY: 13970, maxPressure: 8191,
        buttonCount: 2, hasTilt: true)

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

    /// Builds a 10-byte Report ID 7 packet with the confirmed bit-packed
    /// layout: bit0 tip, bit1 barrel1, bit2 eraser, bit3 barrel2, bit4 invert,
    /// bit5 inRange, bits6-21 X, bits22-37 Y, bits38-53 pressure,
    /// bits54-61 tiltX, bits62-69 tiltY.
    private func makePen(
        barrel1: Bool = false, eraser: Bool = false, barrel2: Bool = false,
        inRange: Bool, x: UInt16 = 0, y: UInt16 = 0, pressure: UInt16 = 0,
        tiltX: Int8 = 0, tiltY: Int8 = 0
    ) -> [UInt8] {
        // 70 bits total (up through tilt Y) — wider than a single 64-bit
        // accumulator, so pack directly into the byte array bit-by-bit.
        var dataBytes = [UInt8](repeating: 0, count: 9)
        func put(_ value: UInt64, at offset: Int, count: Int) {
            for i in 0..<count {
                guard (value >> UInt64(i)) & 1 != 0 else { continue }
                let bitPos = offset + i
                dataBytes[bitPos / 8] |= 1 << UInt8(bitPos % 8)
            }
        }
        put(barrel1 ? 1 : 0, at: 1, count: 1)
        put(eraser ? 1 : 0, at: 2, count: 1)
        put(barrel2 ? 1 : 0, at: 3, count: 1)
        put(inRange ? 1 : 0, at: 5, count: 1)
        put(UInt64(x), at: 6, count: 16)
        put(UInt64(y), at: 22, count: 16)
        put(UInt64(pressure), at: 38, count: 16)
        put(UInt64(UInt8(bitPattern: tiltX)), at: 54, count: 8)
        put(UInt64(UInt8(bitPattern: tiltY)), at: 62, count: 8)

        return [0x07] + dataBytes
    }

    private func penPoint(_ results: [DecodeResult]) -> TabletPoint? {
        for r in results { if case .pen(let p) = r { return p } }
        return nil
    }

    // MARK: - Pen path

    func testHoverDecodesCoordinatesAndProximity() {
        var state = DecoderState()
        let results = decode(makePen(inRange: true, x: 20000, y: 12000, pressure: 0), state: &state)
        guard let p = penPoint(results) else { return XCTFail("no pen result") }
        XCTAssertTrue(p.inProximity)
        XCTAssertEqual(p.x, 20000)
        XCTAssertEqual(p.y, 12000)
        XCTAssertEqual(p.pressure, 0)
        XCTAssertFalse(p.eraser)
    }

    func testToolEnterFiresOnRisingEdgeOnly() {
        var state = DecoderState()
        let first = decode(makePen(inRange: true, x: 100, y: 100), state: &state)
        XCTAssertTrue(first.contains { if case .toolEnter(let t) = $0 { return !t.isEraser && !t.isMouse } else { return false } })
        let second = decode(makePen(inRange: true, x: 101, y: 101), state: &state)
        XCTAssertFalse(second.contains { if case .toolEnter = $0 { return true } else { return false } })
    }

    func testFullPressureDecodes8191() {
        var state = DecoderState()
        let results = decode(makePen(inRange: true, x: 1, y: 1, pressure: 8191), state: &state)
        XCTAssertEqual(penPoint(results)?.pressure, 8191)
        XCTAssertEqual(penPoint(results)?.normalizedPressure ?? 0, 1.0, accuracy: 0.001)
    }

    func testEraserBitSetsEraserAndToolIdentity() {
        var state = DecoderState()
        let results = decode(makePen(eraser: true, inRange: true, x: 5, y: 5, pressure: 1000), state: &state)
        XCTAssertEqual(penPoint(results)?.eraser, true)
        XCTAssertTrue(results.contains { if case .toolEnter(let t) = $0 { return t.isEraser } else { return false } })
    }

    func testBarrelButtonsMapToBits1And3() {
        var state = DecoderState()
        _ = decode(makePen(inRange: true), state: &state)
        let b1 = penPoint(decode(makePen(barrel1: true, inRange: true), state: &state))
        XCTAssertEqual(b1?.penButton1, true)
        XCTAssertEqual(b1?.penButton2, false)
        let b2 = penPoint(decode(makePen(barrel2: true, inRange: true), state: &state))
        XCTAssertEqual(b2?.penButton1, false)
        XCTAssertEqual(b2?.penButton2, true)
    }

    func testTiltNormalizesAgainstSixtyDegrees() {
        var state = DecoderState()
        let results = decode(
            makePen(inRange: true, x: 0, y: 0, pressure: 0, tiltX: 60, tiltY: -30),
            state: &state)
        guard let p = penPoint(results) else { return XCTFail("no pen result") }
        XCTAssertEqual(p.tiltX, 1.0, accuracy: 0.001)
        XCTAssertEqual(p.tiltY, -0.5, accuracy: 0.001)
    }

    func testProximityExitEmitsExitPointAtLastPosition() {
        var state = DecoderState()
        _ = decode(makePen(inRange: true, x: 300, y: 400, pressure: 0), state: &state)
        let results = decode(makePen(inRange: false), state: &state)
        guard let p = penPoint(results) else { return XCTFail("no exit point") }
        XCTAssertFalse(p.inProximity)
        XCTAssertEqual(p.x, 300)
        XCTAssertEqual(p.y, 400)
        XCTAssertEqual(p.pressure, 0)
        // Repeated out-of-range frames stay silent.
        XCTAssertTrue(decode(makePen(inRange: false), state: &state).isEmpty)
    }

    // MARK: - Report-ID isolation

    /// This device streams a second, concurrent, high-frequency report
    /// (ID 2, 32 bytes) whose layout is undecoded. Feeding it into the pen
    /// decoder previously produced chaotic, unsteerable cursor motion — the
    /// decoder must ignore anything that isn't Report ID 7.
    func testNonPenReportIDsAreIgnored() {
        var state = DecoderState()
        var report2 = [UInt8](repeating: 0, count: 32)
        report2[0] = 0x02
        report2[1] = 0xA0
        XCTAssertTrue(decode(report2, state: &state).isEmpty)
    }

    // MARK: - Robustness

    func testShortReportsRejected() {
        var state = DecoderState()
        XCTAssertTrue(decode([0x07], state: &state).isEmpty)
        // In-range pen report shorter than 10 bytes is dropped.
        XCTAssertTrue(decode([0x07, 0x20, 0, 0, 0], state: &state).isEmpty)
    }
}
