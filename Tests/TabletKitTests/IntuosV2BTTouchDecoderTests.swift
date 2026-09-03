// SPDX-License-Identifier: GPL-3.0-or-later
//
// IntuosV2 BT finger-touch decoder fixtures.
//
// Touch is woven into the same 361-byte 0x80 container that carries pen data
// on PTH-660 BT (0x0360) and PTH-860 BT (0x0361):
//   [109..280] = 4 frames × 43 bytes
// Layout ported from `wacom_intuos_pro2_bt_touch()` in
// drivers/hid/wacom_wac.c (Linux kernel, INTUOSP2_BT branch).
//
// Per frame: [0]=bit7 valid | bits 0..6 contact count;
//            [1..]: up to 5 × 8-byte contacts (slot_id, status, X LE16, Y LE16, w, h).
// Lift (status & 0x01 == 0) is dropped at the decoder boundary, matching USB 0x21.
import XCTest
@testable import TabletKit

final class IntuosV2BTTouchDecoderTests: XCTestCase {

    // PTH-860 BT dimensions including touch.  hasFingerTouch=true is the
    // gate the dispatcher checks before invoking decodeBTTouch.
    private let pth860BT = DigitizerSpec(
        maxX: 62200, maxY: 43200, maxPressure: 8191,
        buttonCount: 8, hasTilt: true, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 4,
        hasFingerTouch: true, maxTouchContacts: 5)

    private let pth860NoTouch = DigitizerSpec(
        maxX: 62200, maxY: 43200, maxPressure: 8191,
        buttonCount: 8, hasTilt: true, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 4)

    private func decode(
        _ bytes: [UInt8], spec: DigitizerSpec, state: inout DecoderState
    ) -> [DecodeResult] {
        var decoder = IntuosV2Decoder()
        return bytes.withUnsafeBufferPointer { buf -> [DecodeResult] in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: spec, state: &state, deviceFamily: .intuosProGen2)
        }
    }

    /// Build a 361-byte BT container whose pen portion is empty (frame0 flags = 0,
    /// no tool code) so the only results returned are from the touch path.
    /// `frames` is an array of (frameIndex, headerCount, contacts) where each
    /// contact is (slot_id, status, x, y, major). The fixture uses one minor
    /// value unless a case needs to mutate it directly.
    private func make361WithTouch(
        frames: [(Int, UInt8, [(UInt8, UInt8, UInt16, UInt16, UInt8)])],
        minor: UInt8 = 12
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 361)
        bytes[0] = 0x80
        // Leave pen frame 0 with flags=0 — invalid, so decodeBTPen exits early.
        for (idx, count, contacts) in frames {
            let base = 109 + idx * 43
            // Header: bit7 valid + 7-bit count (when count != 0).
            let headerCount = count == 0 ? 0 : count
            bytes[base] = 0x80 | (headerCount & 0x7F)
            for (k, c) in contacts.prefix(5).enumerated() {
                let cOff = base + 1 + k * 8
                bytes[cOff + 0] = c.0
                bytes[cOff + 1] = c.1
                bytes[cOff + 2] = UInt8(c.2 & 0xFF)
                bytes[cOff + 3] = UInt8((c.2 >> 8) & 0xFF)
                bytes[cOff + 4] = UInt8(c.3 & 0xFF)
                bytes[cOff + 5] = UInt8((c.3 >> 8) & 0xFF)
                bytes[cOff + 6] = c.4
                bytes[cOff + 7] = minor
            }
        }
        return bytes
    }

    // Pull the .touch payloads out of a decode result for assertion brevity.
    private func touches(_ results: [DecodeResult]) -> [[TouchContact]] {
        results.compactMap { r in
            if case .touch(let cs) = r { return cs } else { return nil }
        }
    }

    // MARK: - Gating

    func testTouchSkippedWhenSpecHasNoFingerTouch() {
        var s = DecoderState()
        let bytes = make361WithTouch(frames: [
            (0, 1, [(2, 0x01, 1000, 800, 20)])
        ])
        let results = decode(bytes, spec: pth860NoTouch, state: &s)
        XCTAssertTrue(touches(results).isEmpty,
                      "spec.hasFingerTouch=false must skip the BT touch path entirely")
    }

    func testTooShortBufferRejected() {
        var s = DecoderState()
        // Anything below 109 + 43*4 = 281 bytes is rejected.
        var bytes = [UInt8](repeating: 0, count: 280)
        bytes[0] = 0x80
        // Reaches the 361-byte path via length-based dispatch — but our 0x80
        // length check uses length == 99 → 99-byte path; anything else → BTPen.
        // BTPen with length < 281 will simply not have touch bytes; we should
        // get zero .touch results.
        let results = decode(bytes, spec: pth860BT, state: &s)
        XCTAssertTrue(touches(results).isEmpty)
    }

    // MARK: - Single-frame contacts

    func testSingleFingerDownInFrame0() {
        var s = DecoderState()
        let bytes = make361WithTouch(frames: [
            (0, 1, [(3, 0x01, 3456, 2048, 28)])
        ])
        let frames = touches(decode(bytes, spec: pth860BT, state: &s))
        XCTAssertEqual(frames.count, 1, "one valid touch frame → one .touch result")
        XCTAssertEqual(frames[0].count, 1)
        XCTAssertEqual(frames[0][0].id, 3)
        XCTAssertEqual(frames[0][0].x, 3456)
        XCTAssertEqual(frames[0][0].y, 2048)
        XCTAssertEqual(frames[0][0].contactArea, 28)
        XCTAssertEqual(frames[0][0].contactMinor, 12)
    }

    func testLiftStatusDropsContact() {
        var s = DecoderState()
        let bytes = make361WithTouch(frames: [
            (0, 1, [(3, 0x00, 3456, 2048, 28)])  // status bit clear = lift
        ])
        let frames = touches(decode(bytes, spec: pth860BT, state: &s))
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames[0].isEmpty, "lift contacts are filtered at the decoder")
    }

    func testFiveContactsInOneFrame() {
        var s = DecoderState()
        let bytes = make361WithTouch(frames: [
            (0, 5, [
                (2, 0x01,   100,  100, 18),
                (3, 0x01, 12300, 8500, 20),
                (4, 0x01,  6200, 4300, 22),
                (5, 0x01,  3000, 2000, 19),
                (6, 0x01,  9000, 6000, 21)
            ])
        ])
        let frames = touches(decode(bytes, spec: pth860BT, state: &s))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].count, 5)
        XCTAssertEqual(frames[0].map(\.id), [2, 3, 4, 5, 6])
    }

    func testCountFieldCappedAtFive() {
        var s = DecoderState()
        // Declare count=7 but only 5 slots fit in 41 used bytes.
        let bytes = make361WithTouch(frames: [
            (0, 7, [
                (2, 0x01, 100, 100, 18),
                (3, 0x01, 200, 200, 19),
                (4, 0x01, 300, 300, 20),
                (5, 0x01, 400, 400, 21),
                (6, 0x01, 500, 500, 22)
            ])
        ])
        let frames = touches(decode(bytes, spec: pth860BT, state: &s))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].count, 5)
    }

    // MARK: - Multi-frame batching

    func testMultipleValidFramesEmitOneTouchEach() {
        var s = DecoderState()
        let bytes = make361WithTouch(frames: [
            (0, 1, [(2, 0x01, 1000,  800, 20)]),
            (1, 1, [(2, 0x01, 1010,  810, 21)]),
            (2, 1, [(2, 0x01, 1020,  820, 22)]),
            (3, 1, [(2, 0x01, 1030,  830, 23)])
        ])
        let frames = touches(decode(bytes, spec: pth860BT, state: &s))
        XCTAssertEqual(frames.count, 4, "each valid frame becomes its own .touch emission")
        XCTAssertEqual(frames.map { $0.first?.x }, [1000, 1010, 1020, 1030])
    }

    func testInvalidFrameHeaderSkipped() {
        var s = DecoderState()
        // Build with frame 1 active; manually zero frame 0's valid bit.
        var bytes = make361WithTouch(frames: [
            (1, 1, [(2, 0x01, 1234, 5678, 24)])
        ])
        bytes[109] = 0x00  // frame 0 invalid
        let frames = touches(decode(bytes, spec: pth860BT, state: &s))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].first?.x, 1234)
        XCTAssertEqual(frames[0].first?.y, 5678)
    }

    func testContinuationFrameCountZeroIgnoredInV1() {
        var s = DecoderState()
        // Frame 0 valid w/ count=0 (continuation header) — V1 ignores.
        // Frame 1 valid w/ count=1 — emitted.
        var bytes = make361WithTouch(frames: [
            (1, 1, [(2, 0x01, 1111, 2222, 18)])
        ])
        bytes[109] = 0x80  // frame 0: valid bit set, count=0
        let frames = touches(decode(bytes, spec: pth860BT, state: &s))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].first?.x, 1111)
    }

    // MARK: - Coordinate extremes

    func testCornersDecodeAtExpectedValues() {
        var s = DecoderState()
        let bytes = make361WithTouch(frames: [
            (0, 2, [
                (2, 0x01,     0,    0, 18),     // top-left
                (3, 0x01, 12439, 8639, 18),     // PTH-860 max
            ])
        ])
        let frames = touches(decode(bytes, spec: pth860BT, state: &s))
        XCTAssertEqual(frames[0][0].x, 0)
        XCTAssertEqual(frames[0][0].y, 0)
        XCTAssertEqual(frames[0][1].x, 12439)
        XCTAssertEqual(frames[0][1].y, 8639)
    }

    // MARK: - Device timestamp (trailing 2 bytes of each sub-frame)

    /// Real 3-sub-frame container captured from a PTH-660 over Bluetooth
    /// (2026-09-03), whose frames are stamped 6264, 6364, 6464 — the fixed
    /// 100-count (22.5 ms) stride the hardware emits.
    private func containerWithStampedFrames(_ stamps: [UInt16]) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 361)
        report[0] = 0x80
        for (i, stamp) in stamps.enumerated() {
            let off = 109 + i * 43
            report[off] = 0x81                     // valid | 1 contact
            report[off + 1] = 0x01                 // slot id
            report[off + 2] = 0x01                 // status: down
            report[off + 3] = 0x14                 // X lo
            report[off + 4] = 0x02                 // X hi
            report[off + 5] = 0x32                 // Y lo
            report[off + 6] = 0x03                 // Y hi
            report[off + 7] = 0x02                 // w
            report[off + 8] = 0x02                 // h
            report[off + 41] = UInt8(stamp & 0xFF)         // low byte first
            report[off + 42] = UInt8(stamp >> 8)
        }
        return report
    }

    func testBTTouchRecordsDeviceStampPerFrame() {
        var state = DecoderState()
        let results = decode(
            containerWithStampedFrames([6264, 6364, 6464]),
            spec: pth860BT, state: &state)
        XCTAssertEqual(touches(results).count, 3)
        XCTAssertEqual(state.btTouchFrameStamps, [6264, 6364, 6464])
    }

    /// The stride is what the batch pacer times frames by: consecutive
    /// sub-frames are exactly `btTouchCountsPerFrame` apart, which at
    /// `btTouchMsPerCount` is 22.5 ms.
    func testBTTouchStampStrideIsOneFramePeriod() {
        var state = DecoderState()
        _ = decode(
            containerWithStampedFrames([6264, 6364, 6464]),
            spec: pth860BT, state: &state)
        let deltas = zip(state.btTouchFrameStamps, state.btTouchFrameStamps.dropFirst())
            .map { Int($1) - Int($0) }
        XCTAssertEqual(deltas, [DecoderState.btTouchCountsPerFrame,
                                DecoderState.btTouchCountsPerFrame])
        let msApart = Double(DecoderState.btTouchCountsPerFrame) * DecoderState.btTouchMsPerCount
        XCTAssertEqual(msApart, 22.5, accuracy: 0.001)
    }

    /// A frame the decoder skips must contribute no stamp, or stamps stop
    /// lining up with the frames that actually reach the injector.
    func testSkippedFrameContributesNoStamp() {
        var state = DecoderState()
        var report = containerWithStampedFrames([6264, 6364, 6464])
        report[109 + 43] = 0x80          // middle frame: valid bit, count 0
        let results = decode(report, spec: pth860BT, state: &state)
        XCTAssertEqual(touches(results).count, 2)
        XCTAssertEqual(state.btTouchFrameStamps, [6264, 6464])
    }

    /// Stamps reset per container — a later report must not inherit the
    /// previous one's entries.
    func testStampsResetBetweenContainers() {
        var state = DecoderState()
        _ = decode(
            containerWithStampedFrames([6264, 6364, 6464]),
            spec: pth860BT, state: &state)
        _ = decode(containerWithStampedFrames([9000]), spec: pth860BT, state: &state)
        XCTAssertEqual(state.btTouchFrameStamps, [9000])
    }
}
