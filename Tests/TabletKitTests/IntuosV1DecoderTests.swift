// SPDX-License-Identifier: GPL-3.0-or-later
//
// First snapshot tests for the IntuosV1 decoder family.
// These exist to catch regressions in dispatch and proximity-state logic;
// they are NOT exhaustive coverage. Add cases as bugs are discovered or
// new behaviors are added.
import XCTest
@testable import TabletKit

final class IntuosV1DecoderTests: XCTestCase {

    // PTH-851 dimensions (intuosV1 family). Doesn't need to be exact for these tests.
    private let pth851 = DigitizerSpec(
        maxX: 31920, maxY: 19950, maxPressure: 2047,
        buttonCount: 8, hasTilt: true, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 4)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState,
        family: DeviceFamily = .intuosProGen1
    ) -> [DecodeResult] {
        var decoder = IntuosV1Decoder()
        return bytes.withUnsafeBufferPointer { buf -> [DecodeResult] in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: pth851, state: &state, deviceFamily: family)
        }
    }

    // MARK: - Dispatch & rejection

    func testEmptyReportReturnsNoResults() {
        var state = DecoderState()
        XCTAssertTrue(decode([], state: &state).isEmpty)
        XCTAssertTrue(decode([0x10], state: &state).isEmpty)
    }

    func testWrongLengthUSBPenReportIsRejected() {
        // 0x02 with length != 10 must be ignored — PTH-850 Interface 1 emits a
        // 63-byte vendor-specific touch payload using the same report ID; the
        // decoder must not interpret those bytes as pen coordinates.
        var state = DecoderState()
        let touchSizedPayload = [UInt8](repeating: 0xAA, count: 63)
        XCTAssertTrue(decode([0x02] + touchSizedPayload.dropFirst(), state: &state).isEmpty)
    }

    // MARK: - Tool-change packet

    func testToolChangePacketEmitsToolEnter() {
        // status & 0xFC == 0xC0 marks a tool-identity packet.
        // Layout (per Linux wacom_intuos_inout): byte 1 = 0xC0..0xC3 (entering),
        // bytes 2..5 hold the 32-bit serial, bytes 6..7 hold the tool code.
        var state = DecoderState()
        var bytes = [UInt8](repeating: 0, count: 10)
        bytes[0] = 0x10
        bytes[1] = 0xC2          // tool entering, low bits 0x02
        bytes[2] = 0x12; bytes[3] = 0x34; bytes[4] = 0x56; bytes[5] = 0x78  // serial
        bytes[6] = 0x08; bytes[7] = 0x02  // tool code 0x0802 (standard pen)

        let results = decode(bytes, state: &state)
        guard case .toolEnter(let tool)? = results.first else {
            return XCTFail("Expected .toolEnter as first result, got \(results)")
        }
        XCTAssertFalse(tool.isEraser)
    }

    // MARK: - Proximity exit

    func testProximityExitEmitsInProximityFalse() {
        // After the pen has been in proximity, a status byte with both prox (bit 5)
        // and confidence (bit 6) clear must produce a final .pen with inProximity=false
        // and pressure 0 — the kernel "wacom out" model.
        var state = DecoderState()
        state.prevInProximity = true
        state.lastX = 1000
        state.lastY = 2000

        let bytes: [UInt8] = [0x10, 0x00, 0, 0, 0, 0, 0, 0, 0, 0]
        let results = decode(bytes, state: &state)

        guard case .pen(let p)? = results.first else {
            return XCTFail("Expected .pen result on proximity exit, got \(results)")
        }
        XCTAssertFalse(p.inProximity)
        XCTAssertEqual(p.pressure, 0)
        XCTAssertFalse(state.prevInProximity)
    }

    // MARK: - PTK-540WL Bluetooth aggregated reports (0x03 / 0x04)

    /// Builds a 10-byte pen frame with the given X coordinate, in proximity,
    /// no tip contact. Status 0x60 = proximity + high confidence, subtype 0.
    private func penFrame(x: Int) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 10)
        frame[0] = 0x02
        frame[1] = 0x60
        let xHigh = (x >> 1) & 0xFFFF
        frame[2] = UInt8((xHigh >> 8) & 0xFF)
        frame[3] = UInt8(xHigh & 0xFF)
        frame[9] = UInt8((x & 1) << 1)
        return frame
    }

    func testBT0x03UnwrapsTwoPenFramesAndBattery() {
        var state = DecoderState()
        let report: [UInt8] = [0x03] + penFrame(x: 1000) + penFrame(x: 2000) + [0x6A]
        // power 0x6A = 0b1101010: index 2 → 30%, bit3 charging set, bit4 ext-power set
        let results = decode(report, state: &state)

        let pens = results.compactMap { result -> TabletPoint? in
            guard case .pen(let p) = result, p.inProximity else { return nil }
            return p
        }
        XCTAssertEqual(pens.map(\.x), [1000, 2000])

        guard case .battery(let percent, let charging)? = results.last else {
            return XCTFail("Expected trailing .battery, got \(results)")
        }
        XCTAssertEqual(percent, 30)
        XCTAssertTrue(charging)
    }

    func testBT0x04UnwrapsThreePenFramesAndBattery() {
        var state = DecoderState()
        let report: [UInt8] = [0x04] + penFrame(x: 100) + penFrame(x: 200) + penFrame(x: 300) + [0x07]
        // power 0x07: index 7 → 100%, not charging
        let results = decode(report, state: &state)

        let pens = results.compactMap { result -> TabletPoint? in
            guard case .pen(let p) = result, p.inProximity else { return nil }
            return p
        }
        XCTAssertEqual(pens.map(\.x), [100, 200, 300])

        guard case .battery(let percent, let charging)? = results.last else {
            return XCTFail("Expected trailing .battery, got \(results)")
        }
        XCTAssertEqual(percent, 100)
        XCTAssertFalse(charging)
    }

    func testBTAggregatedPadFrameDecodes() {
        var state = DecoderState()
        var pad = [UInt8](repeating: 0, count: 10)
        pad[0] = 0x0C
        pad[1] = 0x80 | 42   // ring active, position 42
        pad[2] = 0x01        // ring center button
        pad[3] = 0x05        // ExpressKeys 0 and 2
        let report: [UInt8] = [0x03] + penFrame(x: 500) + pad + [0x00]
        let results = decode(report, state: &state)

        guard case .aux(let aux)? = results.first(where: {
            if case .aux = $0 { return true }; return false
        }) else {
            return XCTFail("Expected .aux from embedded pad frame, got \(results)")
        }
        XCTAssertTrue(aux.touchRingActive)
        XCTAssertEqual(aux.touchRingPosition, 42)
        XCTAssertTrue(aux.touchRingButtonDown)
        XCTAssertTrue(aux.buttons[0])
        XCTAssertTrue(aux.buttons[2])
        XCTAssertFalse(aux.buttons[1])
    }

    func testBTShortAggregatedReportIsRejected() {
        // Below the kernel-pinned minimums (22 / 32): must not read the power
        // byte out of bounds. A short 0x03 still falls through to the BLE pad
        // path; a short 0x04 decodes to nothing.
        var state = DecoderState()
        XCTAssertTrue(decode([0x04] + [UInt8](repeating: 0, count: 20), state: &state).isEmpty)
    }
}
