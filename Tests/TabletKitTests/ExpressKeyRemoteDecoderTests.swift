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

    /// The ring-center button, pressed then released (whot/wacom-recordings
    /// `ekr.ring-button.hid`). Byte 9 bit 0; the remote's firmware switches
    /// ring modes on it, so it comes out as the ring's center button.
    func testCapturedButtonPressAndRelease() {
        var state = DecoderState()
        let pressed = auxButtons(decode(
            frame("11 01 00 43 b2 01 00 64 00 01 00 80 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"),
            state: &state))
        XCTAssertEqual(pressed?.touchRingButtonDown, true)
        XCTAssertEqual(pressed?.buttons.contains(true), false)
        XCTAssertEqual(pressed?.touchRingHardwareMode, 2)

        let released = auxButtons(decode(
            frame("11 01 00 43 b2 01 00 64 00 00 00 80 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"),
            state: &state))
        XCTAssertEqual(released?.touchRingButtonDown, false)
        XCTAssertEqual(released?.buttons.contains(true), false)
    }

    // MARK: - Buttons

    func testSeventeenKeysDecodeAcrossThreeBytes() {
        var state = DecoderState()
        let a = auxButtons(decode(makeRemote(buttons9: 0x02), state: &state))
        XCTAssertEqual(a?.buttons.count, 17)
        XCTAssertEqual(a?.buttons[0], true)
        XCTAssertEqual(a?.buttons.filter { $0 }.count, 1)

        let b = auxButtons(decode(makeRemote(buttons9: 0x80), state: &state))
        XCTAssertEqual(b?.buttons[6], true)

        let c = auxButtons(decode(makeRemote(buttons10: 0x01), state: &state))
        XCTAssertEqual(c?.buttons[7], true)

        let d = auxButtons(decode(makeRemote(buttons10: 0x80), state: &state))
        XCTAssertEqual(d?.buttons[14], true)

        let e = auxButtons(decode(makeRemote(byte11: 0x02), state: &state))
        XCTAssertEqual(e?.buttons[16], true)
        XCTAssertEqual(e?.buttons[15], false)
    }

    func testRingModeComesFromByteElevenTopBits() {
        var state = DecoderState()
        XCTAssertEqual(auxButtons(decode(makeRemote(byte11: 0x00), state: &state))?.touchRingHardwareMode, 0)
        XCTAssertEqual(auxButtons(decode(makeRemote(byte11: 0x40), state: &state))?.touchRingHardwareMode, 1)
        XCTAssertEqual(auxButtons(decode(makeRemote(byte11: 0x81), state: &state))?.touchRingHardwareMode, 2)
        XCTAssertNil(auxButtons(decode(makeRemote(byte11: 0xC0), state: &state))?.touchRingHardwareMode)
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
        // 0x8D = touched, raw low 7 bits = 0x0D = 13; kernel's
        // `(data[12] & 0x7f) - 1` (wire is 1-indexed) gives position 12.
        let a = auxButtons(decode(makeRemote(ringByte: 0x8D), state: &state))
        XCTAssertEqual(a?.touchRingActive, true)
        XCTAssertEqual(a?.touchRingPosition, 12)

        // 0xC8 = touched, raw low 7 bits = 0x48 = 72 → position 71, the
        // top of the documented 0-71 span (72 positions, 5° resolution).
        let b = auxButtons(decode(makeRemote(ringByte: 0xC8), state: &state))
        XCTAssertEqual(b?.touchRingActive, true)
        XCTAssertEqual(b?.touchRingPosition, 71)
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
        wrong[0] = 0x7F  // neither 0x10 nor 0x11
        XCTAssertTrue(decode(wrong, state: &state).isEmpty)
    }

    // MARK: - Report 0x10 — receiver pairing table

    private func pairing(_ results: [DecodeResult]) -> [RemotePairingSlot]? {
        results.compactMap {
            if case .remotePairing(let slots) = $0 { return slots } else { return nil }
        }.first
    }

    /// Occupancy is the serial being nonzero, nothing else. The kernel's
    /// `wacom_remote_status_irq` reads only the serial out of each 6-byte slot
    /// and keys every later decision off it; bytes j+1..j+3 are never
    /// examined. This decoder once treated j+2 as an occupancy flag and
    /// credited the kernel for it, so pin the real rule: a slot carrying a
    /// nonzero j+2 but no serial is empty.
    func testSlotOccupancyFollowsSerialNotByteTwo() {
        var state = DecoderState()
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = 0x10
        bytes[2] = 0x01  // would have read as "occupied" under the old rule
        guard let slots = pairing(decode(bytes, state: &state)) else {
            return XCTFail("expected a pairing table")
        }
        XCTAssertFalse(slots[0].connected, "no serial means the slot is empty")
        XCTAssertEqual(slots[0].serial, 0)
    }

    /// The exact 32 bytes from `DTH-2700-0x0331_20260917_155547.json` — all 34
    /// samples in that capture were byte-for-byte identical. One remote paired
    /// in slot 0 with serial 23547, which is the evidence that this user's
    /// pairing was healthy while report 0x11 never fired.
    func testCapturedFrameDecodesOnePairedRemote() {
        var state = DecoderState()
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = 0x10
        bytes[2] = 0x01
        bytes[4] = 0xFB
        bytes[5] = 0x5B

        let slots = pairing(decode(bytes, state: &state))
        XCTAssertEqual(slots?.count, 5)
        XCTAssertEqual(slots?[0].serial, 23547)
        XCTAssertEqual(slots?[0].connected, true)
        // Every other slot empty — the receiver reports all five regardless.
        XCTAssertEqual(slots?.dropFirst().filter { $0.connected }.count, 0)
        XCTAssertEqual(slots?.dropFirst().filter { $0.serial != 0 }.count, 0)
    }

    /// Slot stride is 6 bytes, so slot N's serial sits at 6N+4...6N+6.
    func testAllFiveSlotsDecodeIndependently() {
        var state = DecoderState()
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = 0x10
        for index in 0..<5 {
            let base = index * 6
            bytes[base + 2] = 1
            bytes[base + 4] = UInt8(index + 1)
            bytes[base + 5] = 0x02
            bytes[base + 6] = 0x03
        }

        let slots = pairing(decode(bytes, state: &state))
        XCTAssertEqual(slots?.count, 5)
        for index in 0..<5 {
            XCTAssertEqual(slots?[index].index, index)
            XCTAssertEqual(slots?[index].connected, true)
            XCTAssertEqual(slots?[index].serial, 0x030200 + UInt32(index + 1))
        }
    }

    /// A frame too short for all five slots yields only the slots it can hold,
    /// rather than reading past the end or inventing empty ones.
    func testShortPairingFrameTruncatesRatherThanGuessing() {
        var state = DecoderState()
        var bytes = [UInt8](repeating: 0, count: 15)
        bytes[0] = 0x10
        bytes[2] = 0x01
        bytes[4] = 0x09

        let slots = pairing(decode(bytes, state: &state))
        // Slot 2 would need byte 18; slot 1 needs byte 12. So slots 0 and 1.
        XCTAssertEqual(slots?.count, 2)
        XCTAssertEqual(slots?[0].serial, 9)
        XCTAssertEqual(slots?[0].connected, true)
        XCTAssertEqual(slots?[1].connected, false)
    }

    func testPairingFrameTooShortForAnySlotEmitsNothing() {
        var state = DecoderState()
        XCTAssertTrue(decode([0x10, 0x00, 0x01], state: &state).isEmpty)
    }
}
