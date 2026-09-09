// SPDX-License-Identifier: GPL-3.0-or-later
//
// Wacom ExpressKey Remote (EKR-100) decoder fixtures.
//
// Byte offsets cross-referenced 2026-09-08 against Linux mainline's
// `wacom_remote_irq` (`drivers/hid/wacom_wac.c`) and against five
// action-labeled captures in the MIT-licensed `whot/wacom-recordings`
// (button-by-button presses, ring sweeps both directions, ring-center-button
// presses). No independent hardware capture of this project's own — see
// `ExpressKeyRemoteDecoder`'s header for the full provenance note.
import XCTest
@testable import TabletKit

final class ExpressKeyRemoteDecoderTests: XCTestCase {

    private let remote = DigitizerSpec(
        maxX: 0, maxY: 0, maxPressure: 0, buttonCount: 18)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState
    ) -> [DecodeResult] {
        var decoder = ExpressKeyRemoteDecoder()
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: remote, state: &state, deviceFamily: .expressKeyRemote)
        }
    }

    /// Builds a 32-byte Report ID 0x11 frame in the confirmed layout.
    private func makeRemote(
        serial: UInt32 = 0x01B243, battery: UInt8 = 0x64,
        buttons9: UInt8 = 0, buttons10: UInt8 = 0, byte11: UInt8 = 0,
        ringByte: UInt8 = 0
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = 0x11
        bytes[3] = UInt8(serial & 0xFF)
        bytes[4] = UInt8((serial >> 8) & 0xFF)
        bytes[5] = UInt8((serial >> 16) & 0xFF)
        bytes[7] = battery
        bytes[9] = buttons9
        bytes[10] = buttons10
        bytes[11] = byte11
        bytes[12] = ringByte
        return bytes
    }

    /// Parses a space-separated hex string (verbatim capture line) into bytes.
    private func frame(_ hex: String) -> [UInt8] {
        hex.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    private func auxButtons(_ results: [DecodeResult]) -> AuxButtons? {
        for r in results { if case .aux(let a) = r { return a } }
        return nil
    }

    private func battery(_ results: [DecodeResult]) -> (percent: Int, charging: Bool)? {
        for r in results { if case .battery(let p, let c) = r { return (p, c) } }
        return nil
    }

    // MARK: - Verbatim captured frame

    /// One isolated button, pressed then released (whot/wacom-recordings
    /// `ekr.ring-button.hid`, labeled as the ring-center/mode button by that
    /// capture's own naming). The signal is byte 9 bit 0 — plain `BTN_0` per
    /// the kernel source, i.e. `buttons[0]`, the same as any other numbered
    /// key. Nothing in the kernel driver or this capture singles it out as a
    /// structurally distinct control; see the decoder's header note.
    func testCapturedButtonPressAndRelease() {
        var state = DecoderState()
        let pressed = auxButtons(decode(
            frame("11 01 00 43 b2 01 00 64 00 01 00 80 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"),
            state: &state))
        XCTAssertEqual(pressed?.buttons[0], true)
        XCTAssertEqual(pressed?.buttons.filter { $0 }.count, 1)

        let released = auxButtons(decode(
            frame("11 01 00 43 b2 01 00 64 00 00 00 80 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"),
            state: &state))
        XCTAssertEqual(released?.buttons.contains(true), false)
    }

    // MARK: - Buttons

    func testEighteenButtonsDecodeAcrossThreeBytes() {
        var state = DecoderState()
        // One bit lit in each of the three source bytes.
        let a = auxButtons(decode(makeRemote(buttons9: 0x01), state: &state))
        XCTAssertEqual(a?.buttons.count, 18)
        XCTAssertEqual(a?.buttons[0], true)
        XCTAssertEqual(a?.buttons.filter { $0 }.count, 1)

        let b = auxButtons(decode(makeRemote(buttons9: 0x80), state: &state))
        XCTAssertEqual(b?.buttons[7], true)

        let c = auxButtons(decode(makeRemote(buttons10: 0x01), state: &state))
        XCTAssertEqual(c?.buttons[8], true)

        let d = auxButtons(decode(makeRemote(buttons10: 0x80), state: &state))
        XCTAssertEqual(d?.buttons[15], true)

        let e = auxButtons(decode(makeRemote(byte11: 0x02), state: &state))
        XCTAssertEqual(e?.buttons[17], true)
        XCTAssertEqual(e?.buttons[16], false)
    }

    func testAllZeroFrameIsRelease() {
        var state = DecoderState()
        _ = decode(makeRemote(buttons9: 0xFF), state: &state)
        let release = auxButtons(decode(makeRemote(), state: &state))
        XCTAssertEqual(release?.buttons.contains(true), false)
    }

    // MARK: - Touch Ring (absolute position, not a relative delta)

    /// bit 7 = touched, bits 0–6 = position. Same wire encoding as Intuos4's
    /// pad report (see `IntuosV1Decoder.decodeIntuos4PadReport`) — same
    /// physical ring family.
    func testRingPositionDecodesWhenTouched() {
        var state = DecoderState()
        // 0x8D = touched, position (0x0D & 0x7F) = 13.
        let a = auxButtons(decode(makeRemote(ringByte: 0x8D), state: &state))
        XCTAssertEqual(a?.touchRingActive, true)
        XCTAssertEqual(a?.touchRingPosition, 13)

        // 0xC8 = touched, raw low 7 bits = 0x48 = 72 — one past the
        // documented 0-71 span. Linux subtracts 1 here (`(data[12] &
        // 0x7f) - 1`, since the wire is 1-indexed) before exposing
        // ABS_WHEEL, but no other ring-bearing decoder in this codebase
        // applies that offset (see `IntuosV1Decoder.decodeIntuos4PadReport`,
        // `ringPosition = ringByte & 0x7F`) — `AuxButtons.touchRingPosition`
        // is documented as the raw masked byte throughout. This decoder
        // follows that existing convention for consistency rather than
        // special-casing EKR-100, so raw 72 passes through unmodified; a
        // caller diffing ring position for delta motion never sees the
        // top value repeat, since 71 and 72 are still numerically distinct.
        let b = auxButtons(decode(makeRemote(ringByte: 0xC8), state: &state))
        XCTAssertEqual(b?.touchRingActive, true)
        XCTAssertEqual(b?.touchRingPosition, 0x48)
    }

    func testRingPositionIsIdleSentinelWhenNotTouched() {
        var state = DecoderState()
        let idle = auxButtons(decode(makeRemote(ringByte: 0x00), state: &state))
        XCTAssertEqual(idle?.touchRingActive, false)
        XCTAssertEqual(idle?.touchRingPosition, 0x7F)
    }

    // MARK: - Battery

    func testBatteryEmitsOnceThenDedupesUnchangedReports() {
        var state = DecoderState()
        let first = battery(decode(makeRemote(battery: 0x64), state: &state))
        XCTAssertEqual(first?.percent, 100)
        XCTAssertEqual(first?.charging, false)

        // Same battery byte again — must not re-emit.
        let second = decode(makeRemote(battery: 0x64), state: &state)
        XCTAssertNil(battery(second))

        // Charging bit set, percent drops — must emit the new reading.
        let third = battery(decode(makeRemote(battery: 0x80 | 0x32), state: &state))
        XCTAssertEqual(third?.percent, 50)
        XCTAssertEqual(third?.charging, true)
    }

    // MARK: - Robustness

    func testShortReportsRejected() {
        var state = DecoderState()
        XCTAssertTrue(decode([0x11], state: &state).isEmpty)
        XCTAssertTrue(decode([UInt8](repeating: 0, count: 12), state: &state).isEmpty)
    }

    func testWrongReportIDIsIgnored() {
        var state = DecoderState()
        var wrong = makeRemote()
        wrong[0] = 0x10  // receiver/pairing status report, not decoded here
        XCTAssertTrue(decode(wrong, state: &state).isEmpty)
    }
}
