// SPDX-License-Identifier: GPL-3.0-or-later
//
// BPT3 touch/pad container fixtures (Report ID 0x02, 64 bytes) for the
// IntuosV1 decoder path — CTH-690 Intuos Art (PID 0x033E), INTUOSHT2 family.
//
// Format confirmed by user discovery capture 2026-07-03: up to 7 × 8-byte
// messages at offset 2; message count in byte 1 bits 2:0. Finger messages
// use slot keys 2–17 with 12-bit X/Y; the express-key message is 0x80.
// Containers carry only changed contacts, so slot state must persist.
import XCTest

@testable import TabletKit

final class IntuosV1DecoderBPT3TouchTests: XCTestCase {

    private let cth690 = DigitizerSpec(
        maxX: 21600, maxY: 13500, maxPressure: 2047,
        buttonCount: 4, hasFingerTouch: true, maxTouchContacts: 16)

    private func decode(
        _ bytes: [UInt8], spec: DigitizerSpec? = nil, state: inout DecoderState
    ) -> [DecodeResult] {
        var decoder = IntuosV1Decoder()
        let spec = spec ?? cth690
        return bytes.withUnsafeBufferPointer { buf -> [DecodeResult] in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: spec, state: &state, deviceFamily: "intuosConsumer")
        }
    }

    /// Build a 64-byte BPT3 container from 8-byte messages.
    private func makeContainer(_ messages: [[UInt8]]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x02
        bytes[1] = UInt8(messages.count)
        for (i, msg) in messages.prefix(7).enumerated() {
            for (j, b) in msg.prefix(8).enumerated() {
                bytes[2 + i * 8 + j] = b
            }
        }
        return bytes
    }

    /// Touch message: slot key, down flag, 12-bit X/Y, width, height.
    private func touchMsg(
        slot: UInt8, down: Bool, x: Int, y: Int, width: UInt8 = 3, height: UInt8 = 3
    ) -> [UInt8] {
        [
            slot,
            down ? 0x80 : 0x00,
            UInt8((x >> 4) & 0xFF),
            UInt8((y >> 4) & 0xFF),
            UInt8(((x & 0x0F) << 4) | (y & 0x0F)),
            width, height, 0,
        ]
    }

    private func contacts(_ results: [DecodeResult]) -> [TouchContact]? {
        for result in results {
            if case .touch(let list) = result { return list }
        }
        return nil
    }

    // MARK: - Capture fixture

    /// First sampled container from the 2026-07-03 CTH-690 discovery capture:
    /// slot 2 lifting plus slot 5 down at (1301, 1335).
    func testCaptureFirstSample() {
        var s = DecoderState()
        var bytes = [UInt8](repeating: 0, count: 64)
        let head: [UInt8] = [
            0x02, 0x02,
            0x02, 0x20, 0x57, 0x4D, 0x9E, 0x02, 0x02, 0x00,
            0x05, 0x88, 0x51, 0x53, 0x57, 0x03, 0x03, 0x00,
        ]
        bytes.replaceSubrange(0..<head.count, with: head)
        let results = decode(bytes, state: &s)
        guard let list = contacts(results) else {
            return XCTFail("expected .touch, got \(results)")
        }
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, 5)
        XCTAssertEqual(list[0].x, 1301)
        XCTAssertEqual(list[0].y, 1335)
    }

    // MARK: - Gating

    func testRejectedWithoutFingerTouch() {
        var s = DecoderState()
        let penOnly = DigitizerSpec(
            maxX: 21600, maxY: 13500, maxPressure: 2047, buttonCount: 4)
        let bytes = makeContainer([touchMsg(slot: 2, down: true, x: 100, y: 200)])
        XCTAssertTrue(decode(bytes, spec: penOnly, state: &s).isEmpty)
        XCTAssertTrue(s.bpt3TouchSlots.isEmpty)
    }

    // MARK: - Slot state

    func testSlotStatePersistsAcrossContainers() {
        var s = DecoderState()
        _ = decode(makeContainer([touchMsg(slot: 2, down: true, x: 1000, y: 500)]), state: &s)
        // Second container mentions only slot 3; slot 2 must remain active.
        let results = decode(
            makeContainer([touchMsg(slot: 3, down: true, x: 2000, y: 800)]), state: &s)
        guard let list = contacts(results) else { return XCTFail("expected .touch") }
        XCTAssertEqual(list.map(\.id), [2, 3])
        XCTAssertEqual(list[0].x, 1000)
        XCTAssertEqual(list[1].x, 2000)
    }

    func testReleaseRemovesContact() {
        var s = DecoderState()
        _ = decode(
            makeContainer([
                touchMsg(slot: 2, down: true, x: 1000, y: 500),
                touchMsg(slot: 3, down: true, x: 2000, y: 800),
            ]), state: &s)
        let results = decode(
            makeContainer([touchMsg(slot: 2, down: false, x: 0, y: 0)]), state: &s)
        guard let list = contacts(results) else { return XCTFail("expected .touch") }
        XCTAssertEqual(list.map(\.id), [3])
    }

    func testTwelveBitCoordinateExtremes() {
        var s = DecoderState()
        let results = decode(
            makeContainer([touchMsg(slot: 2, down: true, x: 4095, y: 4095)]), state: &s)
        guard let list = contacts(results) else { return XCTFail("expected .touch") }
        XCTAssertEqual(list[0].x, 4095)
        XCTAssertEqual(list[0].y, 4095)
    }

    // MARK: - Pen arbitration

    func testPenProximitySuppressesNewContacts() {
        var s = DecoderState()
        s.prevInProximity = true
        let results = decode(
            makeContainer([touchMsg(slot: 2, down: true, x: 1000, y: 500)]), state: &s)
        guard let list = contacts(results) else { return XCTFail("expected .touch") }
        XCTAssertTrue(list.isEmpty)
    }

    func testPenProximityReleasesActiveContacts() {
        var s = DecoderState()
        _ = decode(makeContainer([touchMsg(slot: 2, down: true, x: 1000, y: 500)]), state: &s)
        s.prevInProximity = true  // pen entered proximity via 0x10 report
        // Pad-only container — no touch messages — must still flush contacts.
        let results = decode(makeContainer([[0x80, 0x00, 0, 0, 0, 0, 0, 0]]), state: &s)
        guard let list = contacts(results) else { return XCTFail("expected .touch") }
        XCTAssertTrue(list.isEmpty)
        XCTAssertTrue(s.bpt3TouchSlots.isEmpty)
    }

    /// A pen proximity-exit report that never arrives must not disable touch
    /// forever. Once containers pile up without any pen report, the flag is
    /// treated as stale and contacts are accepted again.
    func testStaleProximityUnlatchesAfterSilentPenInterface() {
        var s = DecoderState()
        s.prevInProximity = true  // latched, and no exit report will follow

        let container = makeContainer([touchMsg(slot: 2, down: true, x: 1000, y: 500)])
        for _ in 0..<BPT3ContainerDecoder.staleProximityAfterContainers {
            guard let list = contacts(decode(container, state: &s)) else {
                return XCTFail("expected .touch")
            }
            XCTAssertTrue(list.isEmpty, "suppressed while proximity is still fresh")
        }

        guard let list = contacts(decode(container, state: &s)) else {
            return XCTFail("expected .touch")
        }
        XCTAssertEqual(list.count, 1, "stale proximity must stop suppressing touch")
        XCTAssertEqual(list[0].x, 1000)
    }

    /// The unlatch must not fire while the pen really is there: a pen in
    /// proximity streams reports, and each one resets the staleness counter.
    func testInterleavedPenReportsKeepSuppressionAlive() {
        var s = DecoderState()
        // Report 0x10 in proximity — the INTUOSHT2 pen shape.
        var penReport = [UInt8](repeating: 0, count: 10)
        penReport[0] = 0x10
        penReport[1] = 0xE0

        let container = makeContainer([touchMsg(slot: 2, down: true, x: 1000, y: 500)])
        for _ in 0..<(BPT3ContainerDecoder.staleProximityAfterContainers * 3) {
            _ = decode(penReport, state: &s)
            XCTAssertTrue(s.prevInProximity, "pen report should hold proximity")
            guard let list = contacts(decode(container, state: &s)) else {
                return XCTFail("expected .touch")
            }
            XCTAssertTrue(list.isEmpty, "pen is live; touch must stay suppressed")
        }
    }

    // MARK: - Express keys (pad message 0x80)

    func testPadMessageAllFourKeys() {
        var s = DecoderState()
        let results = decode(makeContainer([[0x80, 0x0F, 0, 0, 0, 0, 0, 0]]), state: &s)
        guard case .aux(let aux)? = results.first else {
            return XCTFail("expected .aux, got \(results)")
        }
        XCTAssertEqual(aux.buttons, [true, true, true, true])
    }

    func testPadMessageSingleKeyBits() {
        for (bit, index) in [(UInt8(0x01), 0), (0x02, 1), (0x04, 2), (0x08, 3)] {
            var s = DecoderState()
            let results = decode(makeContainer([[0x80, bit, 0, 0, 0, 0, 0, 0]]), state: &s)
            guard case .aux(let aux)? = results.first else {
                return XCTFail("expected .aux for bit \(bit)")
            }
            var expected = [false, false, false, false]
            expected[index] = true
            XCTAssertEqual(aux.buttons, expected)
        }
    }

    // MARK: - Pen report sanity (capture fixture)

    /// First pen report from the capture ("10 E0 10 82 15 4F 00 00 00 FF"):
    /// classic Intuos packet — confirms the existing intuosV1 pen path fits
    /// the CTH-690 without changes.
    func testCapturePenSample() {
        var s = DecoderState()
        let bytes: [UInt8] = [0x10, 0xE0, 0x10, 0x82, 0x15, 0x4F, 0x00, 0x00, 0x00, 0xFF]
        let results = decode(bytes, state: &s)
        guard case .pen(let point)? = results.last else {
            return XCTFail("expected .pen, got \(results)")
        }
        XCTAssertEqual(point.x, 8453)  // (0x1082 << 1) | 1
        XCTAssertEqual(point.y, 10911)  // (0x154F << 1) | 1
        XCTAssertEqual(point.pressure, 0)
        XCTAssertTrue(point.inProximity)
    }
}
