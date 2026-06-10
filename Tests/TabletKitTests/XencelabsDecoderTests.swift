// SPDX-License-Identifier: GPL-3.0-or-later
//
// Xencelabs Pen Tablet decoder fixtures.
//
// Byte layouts come from OpenTabletDriver's XenceLabsReportParser /
// XenceLabsTabletReport / XP_PenAuxReport (pinned 2026-05-15) — there is no
// hardware capture yet, so these tests lock in the *ported* semantics, not
// verified wire behavior. When a live capture lands, add real-report fixtures
// alongside these and reconcile any disagreement in the decoder, not here.
import XCTest
@testable import TabletKit

final class XencelabsDecoderTests: XCTestCase {

    private let medium = DigitizerSpec(
        maxX: 52324, maxY: 29600, maxPressure: 8191,
        buttonCount: 3, hasTilt: true)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState
    ) -> [DecodeResult] {
        var decoder = XencelabsDecoder()
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: medium, state: &state, deviceFamily: "xencelabs")
        }
    }

    /// 10-byte pen report. `status` carries the bit flags; X/Y/pressure LE16.
    private func makePen(
        status: UInt8, x: UInt16, y: UInt16, pressure: UInt16,
        tiltX: Int8 = 0, tiltY: Int8 = 0
    ) -> [UInt8] {
        [
            0x07, status,
            UInt8(x & 0xFF), UInt8(x >> 8),
            UInt8(y & 0xFF), UInt8(y >> 8),
            UInt8(pressure & 0xFF), UInt8(pressure >> 8),
            UInt8(bitPattern: tiltX), UInt8(bitPattern: tiltY),
        ]
    }

    private func penPoint(_ results: [DecodeResult]) -> TabletPoint? {
        for r in results { if case .pen(let p) = r { return p } }
        return nil
    }

    // MARK: - Pen path

    func testHoverDecodesCoordinatesAndProximity() {
        var state = DecoderState()
        // bit 5 = in range, no tip/buttons/eraser.
        let results = decode(makePen(status: 0x20, x: 26000, y: 14000, pressure: 0), state: &state)
        guard let p = penPoint(results) else { return XCTFail("no pen result") }
        XCTAssertTrue(p.inProximity)
        XCTAssertEqual(p.x, 26000)
        XCTAssertEqual(p.y, 14000)
        XCTAssertEqual(p.pressure, 0)
        XCTAssertFalse(p.eraser)
    }

    func testToolEnterFiresOnRisingEdgeOnly() {
        var state = DecoderState()
        let first = decode(makePen(status: 0x20, x: 100, y: 100, pressure: 0), state: &state)
        XCTAssertTrue(first.contains { if case .toolEnter(let t) = $0 { return !t.isEraser && !t.isMouse } else { return false } })
        let second = decode(makePen(status: 0x20, x: 101, y: 101, pressure: 0), state: &state)
        XCTAssertFalse(second.contains { if case .toolEnter = $0 { return true } else { return false } })
    }

    func testFullPressureDecodes8191() {
        var state = DecoderState()
        let results = decode(makePen(status: 0x20, x: 1, y: 1, pressure: 8191), state: &state)
        XCTAssertEqual(penPoint(results)?.pressure, 8191)
        XCTAssertEqual(penPoint(results)?.normalizedPressure ?? 0, 1.0, accuracy: 0.001)
    }

    func testEraserBitSetsEraserAndToolIdentity() {
        var state = DecoderState()
        // bit 5 in range + bit 6 eraser.
        let results = decode(makePen(status: 0x60, x: 5, y: 5, pressure: 1000), state: &state)
        XCTAssertEqual(penPoint(results)?.eraser, true)
        XCTAssertTrue(results.contains { if case .toolEnter(let t) = $0 { return t.isEraser } else { return false } })
    }

    func testBarrelButtonsMapToBits1Through3() {
        var state = DecoderState()
        _ = decode(makePen(status: 0x20, x: 0, y: 0, pressure: 0), state: &state)
        let b1 = penPoint(decode(makePen(status: 0x22, x: 0, y: 0, pressure: 0), state: &state))
        XCTAssertEqual(b1?.penButton1, true)
        XCTAssertEqual(b1?.penButton2, false)
        let b2 = penPoint(decode(makePen(status: 0x24, x: 0, y: 0, pressure: 0), state: &state))
        XCTAssertEqual(b2?.penButton2, true)
        let b3 = penPoint(decode(makePen(status: 0x28, x: 0, y: 0, pressure: 0), state: &state))
        XCTAssertEqual(b3?.penButton3, true)
    }

    func testTiltNormalizesAgainstSixtyDegrees() {
        var state = DecoderState()
        let results = decode(
            makePen(status: 0x20, x: 0, y: 0, pressure: 0, tiltX: 60, tiltY: -30),
            state: &state)
        guard let p = penPoint(results) else { return XCTFail("no pen result") }
        XCTAssertEqual(p.tiltX, 1.0, accuracy: 0.001)
        XCTAssertEqual(p.tiltY, -0.5, accuracy: 0.001)
    }

    func testProximityExitEmitsExitPointAtLastPosition() {
        var state = DecoderState()
        _ = decode(makePen(status: 0x20, x: 300, y: 400, pressure: 0), state: &state)
        // Out-of-range frame: bit 5 clear, not an aux pattern.
        let results = decode([0x07, 0x00, 0, 0, 0, 0, 0, 0, 0, 0], state: &state)
        guard let p = penPoint(results) else { return XCTFail("no exit point") }
        XCTAssertFalse(p.inProximity)
        XCTAssertEqual(p.x, 300)
        XCTAssertEqual(p.y, 400)
        XCTAssertEqual(p.pressure, 0)
        // Repeated out-of-range frames stay silent.
        XCTAssertTrue(decode([0x07, 0x00, 0, 0, 0, 0, 0, 0, 0, 0], state: &state).isEmpty)
    }

    // MARK: - Aux path

    func testAuxButtonsDecodeFromBitmask() {
        var state = DecoderState()
        // 0xF0 dispatch pattern; buttons 1 and 10 down (byte 2 bit 0, byte 3 bit 1).
        let results = decode([0x07, 0xF0, 0x01, 0x02, 0x00, 0, 0, 0x00, 0, 0], state: &state)
        guard case .aux(let aux)? = results.first else { return XCTFail("no aux result") }
        XCTAssertTrue(aux[0])
        XCTAssertTrue(aux[9])
        XCTAssertFalse(aux[1])
    }

    func testWheelPulsesEmitSignedDeltas() {
        var state = DecoderState()
        let cw = decode([0x07, 0xF0, 0, 0, 0, 0, 0, 0x01, 0, 0], state: &state)
        XCTAssertTrue(cw.contains { if case .wheel(0, 1) = $0 { return true } else { return false } })
        let ccw = decode([0x07, 0xF0, 0, 0, 0, 0, 0, 0x02, 0, 0], state: &state)
        XCTAssertTrue(ccw.contains { if case .wheel(0, -1) = $0 { return true } else { return false } })
        let wheel2 = decode([0x07, 0xF0, 0, 0, 0, 0, 0, 0x20, 0, 0], state: &state)
        XCTAssertTrue(wheel2.contains { if case .wheel(1, -1) = $0 { return true } else { return false } })
    }

    func testAuxDoesNotDisturbPenProximityState() {
        var state = DecoderState()
        _ = decode(makePen(status: 0x20, x: 50, y: 50, pressure: 0), state: &state)
        _ = decode([0x07, 0xF0, 0x01, 0, 0, 0, 0, 0, 0, 0], state: &state)
        XCTAssertTrue(state.prevInProximity)
    }

    // MARK: - Robustness

    func testShortReportsRejected() {
        var state = DecoderState()
        XCTAssertTrue(decode([0x07], state: &state).isEmpty)
        // In-range pen report shorter than 10 bytes is dropped.
        XCTAssertTrue(decode([0x07, 0x20, 0, 0, 0], state: &state).isEmpty)
        // Aux shorter than 8 bytes is dropped.
        XCTAssertTrue(decode([0x07, 0xF0, 0, 0], state: &state).isEmpty)
    }
}
