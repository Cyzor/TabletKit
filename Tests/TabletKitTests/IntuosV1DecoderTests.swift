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

    // MARK: - Airbrush fingerwheel (kernel type 0x0a)
    //
    // Frames constructed, not captured — hardware unowned. Status 0x74 =
    // subtype 0x0A, proximity + confidence set.

    /// No pressure in this packet, so a `.pen` here would read as a tip release.
    func testAirbrushWheelPacketEmitsNoPenPoint() {
        var state = DecoderState()
        _ = decode([0x02, 0x60, 0, 100, 0, 100, 0, 0, 0, 0], state: &state)
        let wheel = decode([0x02, 0x74, 0, 0, 0, 0, 0xFF, 0xC0, 0, 0], state: &state)
        XCTAssertFalse(wheel.contains { if case .pen = $0 { return true }; return false })
    }

    /// Kernel: `(data[6] << 2) | ((data[7] >> 6) & 3)` — absolute 0...1023.
    func testAirbrushWheelValueMatchesKernelFormula() {
        var state = DecoderState()
        _ = decode([0x02, 0x74, 0, 0, 0, 0, 0xFF, 0xC0, 0, 0], state: &state)
        let p = penPoint(decode([0x02, 0x60, 0, 100, 0, 100, 0, 0, 0, 0], state: &state))
        XCTAssertEqual(p?.airbrushWheel, 1023)

        _ = decode([0x02, 0x74, 0, 0, 0, 0, 0x00, 0x00, 0, 0], state: &state)
        let zero = penPoint(decode([0x02, 0x60, 0, 100, 0, 100, 0, 0, 0, 0], state: &state))
        XCTAssertEqual(zero?.airbrushWheel, 0)

        // 0x80 << 2 | (0x40 >> 6) == 512 | 1
        _ = decode([0x02, 0x74, 0, 0, 0, 0, 0x80, 0x40, 0, 0], state: &state)
        let mid = penPoint(decode([0x02, 0x60, 0, 100, 0, 100, 0, 0, 0, 0], state: &state))
        XCTAssertEqual(mid?.airbrushWheel, 513)
    }

    /// Wheel and pressure arrive in different packets; the cache must survive.
    func testAirbrushWheelPersistsAcrossPenReports() {
        var state = DecoderState()
        _ = decode([0x02, 0x74, 0, 0, 0, 0, 0x40, 0x00, 0, 0], state: &state)
        for _ in 0..<3 {
            let p = penPoint(decode([0x02, 0x60, 0, 100, 0, 100, 0x20, 0, 0, 0], state: &state))
            XCTAssertEqual(p?.airbrushWheel, 256)
        }
    }

    /// A wheel position must not follow the next tool into proximity.
    func testAirbrushWheelClearsOnProximityExit() {
        var state = DecoderState()
        _ = decode([0x02, 0x74, 0, 0, 0, 0, 0xFF, 0xC0, 0, 0], state: &state)
        _ = decode([0x02, 0x60, 0, 100, 0, 100, 0, 0, 0, 0], state: &state)
        _ = decode([0x02, 0x00, 0, 0, 0, 0, 0, 0, 0, 0], state: &state)  // exit
        let after = penPoint(decode([0x02, 0x60, 0, 100, 0, 100, 0, 0, 0, 0], state: &state))
        XCTAssertNil(after?.airbrushWheel)
    }

    /// nil, not 0 — lets a consumer tell "no wheel" from "wheel at zero".
    func testNonAirbrushToolsReportNilWheel() {
        var state = DecoderState()
        let p = penPoint(decode([0x02, 0x60, 0, 100, 0, 100, 0x40, 0, 0, 0], state: &state))
        XCTAssertNil(p?.airbrushWheel)
    }

    // MARK: - GD-0608-U capture (2026-09-22)

    /// Intuos 6×8 spec, for the capture-backed cases below. 1023-level
    /// pressure exercises `decodeUSBPen`'s 10-bit right-shift branch, which
    /// the PTH-851 spec above (2047) does not.
    private let gd0608 = DigitizerSpec(
        maxX: 40640, maxY: 32480, maxPressure: 1023,
        buttonCount: 0, hasTilt: true, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 4)

    private func decodeGD0608(_ bytes: [UInt8], state: inout DecoderState) -> [DecodeResult] {
        var decoder = IntuosV1Decoder()
        return bytes.withUnsafeBufferPointer { buf -> [DecodeResult] in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: gd0608, state: &state, deviceFamily: .intuosProGen1)
        }
    }

    /// The tip and eraser ends of one GD-series Grip Pen, byte-for-byte from
    /// the 2026-09-22 capture's two 0xC2 tool-change samples. They differ only
    /// in byte 3's high nibble and must decode to a matching pair — same
    /// serial, eraser bit set on exactly one — and both resolve in the tool
    /// catalog, which before this capture knew neither code.
    func testGD0608ToolCodesDecodeAndResolve() {
        for (byte3, expected, isEraser) in [
            (UInt8(41), UInt16(0x8822), false),
            (UInt8(169), UInt16(0x882A), true),
        ] {
            var state = DecoderState()
            let bytes: [UInt8] = [0x02, 0xC2, 130, byte3, 152, 0, 94, 88, 0, 168]
            guard case .toolEnter(let tool)? = decodeGD0608(bytes, state: &state).first else {
                return XCTFail("expected .toolEnter for 0x\(String(expected, radix: 16))")
            }
            XCTAssertEqual(tool.toolCode, expected)
            XCTAssertEqual(tool.isEraser, isEraser)
            XCTAssertFalse(tool.isMouse)
            XCTAssertEqual(tool.serial, 0x9980_05E5, "both ends share one pen body")

            let spec = WacomToolCatalog.spec(forToolCodeRaw: expected)
            XCTAssertNotNil(spec, "0x\(String(expected, radix: 16)) should be catalogued")
            XCTAssertEqual(spec?.toolCode, expected, "must match exactly, not via eraser-bit fallback")
            XCTAssertEqual(spec?.toolType, isEraser ? .eraser : .stylus)
        }
    }

    /// Hover reports (status 0xA0 — proximity set, confidence clear) carry
    /// small non-zero pressure on this hardware: the sensor noise behind
    /// Cyzor/tablet-driver#4. The decoder must pass it through unchanged
    /// rather than silently zeroing it — rejecting it is the injector's job,
    /// via the dead zone in `WacomDeviceSpec.defaultPressureThreshold`.
    /// Byte values are the capture's observed A0 extremes.
    func testGD0608HoverNoiseDecodesAsSmallNonZeroPressure() {
        var state = DecoderState()
        // b6=2, b7=174 — the loudest hover sample in the capture.
        let loudest = penPoint(
            decodeGD0608([0x02, 0xA0, 0, 100, 0, 100, 2, 174, 0, 0], state: &state))
        XCTAssertEqual(loudest?.pressure, 10, "11-bit raw 20, right-shifted for a 1023 channel")
        XCTAssertEqual(loudest?.inProximity, true, "hover is still proximity")

        // b6=0, b7=34 — a quiet hover sample, genuinely zero.
        var quietState = DecoderState()
        let quiet = penPoint(
            decodeGD0608([0x02, 0xA0, 0, 100, 0, 100, 0, 34, 0, 0], state: &quietState))
        XCTAssertEqual(quiet?.pressure, 0)
    }

    /// The capture's heaviest press (b6=216, b7=241) must land inside the
    /// 1023 channel — a 10-bit shift bug would put it near 1734, well past
    /// `maxPressure`, and clip every firm stroke.
    func testGD0608MaxObservedPressureStaysInRange() {
        var state = DecoderState()
        let p = penPoint(decodeGD0608([0x02, 0xE0, 0, 100, 0, 100, 216, 241, 0, 0], state: &state))
        XCTAssertEqual(p?.pressure, 867)
        XCTAssertLessThanOrEqual(p!.pressure, gd0608.maxPressure)
    }

    /// The fix for Cyzor/tablet-driver#5: coordinates carry a 1-bit fractional
    /// extension from byte 9, so the decoded value is twice a plain BE16 read.
    /// Without it, a full-scale sample decodes to half of `maxX`/`maxY` and
    /// only the tablet's top-left quadrant reaches the whole screen.
    func testGD0608CoordinatesUseFractionalExtension() {
        var state = DecoderState()
        // X bytes 0x4F/0x60 = 20320 (maxX/2), Y bytes 0x3F/0x70 = 16240 (maxY/2).
        // Byte 9 bit 1 sets X's fractional bit, bit 0 sets Y's.
        let p = penPoint(
            decodeGD0608([0x02, 0xE0, 0x4F, 0x60, 0x3F, 0x70, 0, 0, 0, 0b11], state: &state))
        XCTAssertEqual(p?.x, 40641, "2×20320 + 1 — spans the full maxX, not half of it")
        XCTAssertEqual(p?.y, 32481, "2×16240 + 1 — spans the full maxY, not half of it")

        // Same coordinate bytes, fractional bits clear: still full-scale.
        var evenState = DecoderState()
        let even = penPoint(
            decodeGD0608([0x02, 0xE0, 0x4F, 0x60, 0x3F, 0x70, 0, 0, 0, 0], state: &evenState))
        XCTAssertEqual(even?.x, 40640)
        XCTAssertEqual(even?.y, 32480)
    }

    private func penPoint(_ results: [DecodeResult]) -> TabletPoint? {
        for r in results { if case .pen(let p) = r { return p } }
        return nil
    }

    // MARK: - In-range state (status 0x20)

    /// In-range frames carry zeroed tilt/hover bytes; decoding them produced
    /// tilt -1.02 and hover 63 — the PTH-850 wireless chatter.
    func testInRangeFrameDoesNotDecodeItsZeroedFields() {
        var state = DecoderState()
        // Enter proximity with a real frame first, so there's a position to hold.
        _ = decode([0x02, 0xE0, 0x57, 0xF3, 0x1E, 0xAF, 0x00, 0x17, 0xCB, 0xA1], state: &state)
        let held = penPoint(
            decode([0x02, 0xE0, 0x57, 0xF3, 0x1E, 0xAF, 0x00, 0x17, 0xCB, 0xA1], state: &state))

        // Verbatim in-range frame from that capture: note the 00 00 00 tail.
        let inRange = penPoint(
            decode([0x02, 0x20, 0x51, 0xA9, 0x20, 0x06, 0x00, 0x00, 0x00, 0xFC], state: &state))

        XCTAssertNotNil(inRange, "mid-stroke in-range frames still flush")
        XCTAssertEqual(inRange?.tiltX, 0, "must not decode the zeroed tilt bytes")
        XCTAssertEqual(inRange?.tiltY, 0, "must not decode the zeroed tilt bytes")
        XCTAssertEqual(inRange?.pressure, 0, "tip is lifted for the flush")
        XCTAssertEqual(inRange?.inProximity, true, "the tool has not left proximity")
        XCTAssertEqual(inRange?.x, held?.x, "position holds — X is absent from the flush")
        XCTAssertEqual(inRange?.y, held?.y, "position holds — Y is absent from the flush")
    }

    /// Before proximity entry, nothing to flush — the kernel's `return 1`.
    func testInRangeFrameWithNoPriorProximityReportsNothing() {
        var state = DecoderState()
        let results = decode(
            [0x02, 0x20, 0x51, 0xA9, 0x20, 0x06, 0x00, 0x00, 0x00, 0xFC], state: &state)
        XCTAssertNil(penPoint(results), "no stroke in progress, nothing to flush")
    }

    /// 0xA0 is also proximity-set/confidence-clear but carries real data —
    /// only bit 7 separates it from in-range.
    func testOrdinaryHoverIsNotTreatedAsInRange() {
        var state = DecoderState()
        let hover = penPoint(
            decode([0x02, 0xA0, 0x57, 0xF3, 0x1E, 0xAF, 0x02, 0xAE, 0x00, 0xA1], state: &state))
        XCTAssertNotNil(hover, "0xA0 still decodes normally")
        XCTAssertNotEqual(
            hover?.pressure, 0, "0xA0 carries real pressure — see the GD-0608 hover-noise test")
    }
}
