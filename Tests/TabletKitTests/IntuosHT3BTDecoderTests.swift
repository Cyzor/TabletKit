// SPDX-License-Identifier: GPL-3.0-or-later
//
// INTUOSHT3_BT (Report ID 0x81) decoder fixtures — consumer Intuos BT S/M
// over Bluetooth: CTL-4100WL (0x0377, 0x03C6) and CTL-6100WL (0x0379, 0x03C8).
//
// Every byte string below is verbatim from a 627-record hardware capture of a
// CTL-4100WL paired over Bluetooth (OTD Tablet Debugger recording, archived in
// `Notes/Scratch/Wacom-CTL-6100WL/`). That recording carries the decoded
// position/pressure/button output beside each raw record, so the expectations
// here are what real hardware produced, not what this decoder computes.
//
// Replaying the whole capture through this layout reproduced that output for
// 613 of 616 pen records; the three misses are the opening records, where
// holding the last position has no prior value to hold.
import XCTest

@testable import TabletKit

final class IntuosHT3BTDecoderTests: XCTestCase {

    /// CTL-4100WL: 15200 x 9500 at 4095 pressure, four ExpressKeys, no tilt.
    private let ctl4100 = DigitizerSpec(
        maxX: 15200, maxY: 9500, maxPressure: 4095,
        buttonCount: 4, hasTilt: false, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 0)

    private func decode(_ bytes: [UInt8], state: inout DecoderState) -> [DecodeResult] {
        var decoder = IntuosV2Decoder()
        return bytes.withUnsafeBufferPointer { buf -> [DecodeResult] in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: ctl4100, state: &state, deviceFamily: .intuosProGen2)
        }
    }

    private func hex(_ s: String) -> [UInt8] {
        s.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    private func pens(_ results: [DecodeResult]) -> [TabletPoint] {
        results.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }
    }

    // MARK: - Pen

    /// Tip down mid-stroke. Three valid frames; the last one is what the host
    /// sees as the current position, and pressure is well into the range.
    func testTipDownStrokeDecodesLastFrame() {
        var state = DecoderState()
        let r = decode(
            hex(
                "81 E1 22 22 43 18 A3 0B 11 E1 26 22 5F 18 20 0C 11 E1 2A 22 7F 18 B3 0C 11 "
                    + "00 00 00 00 00 00 00 00 96 40 80 04 62 08 10 00 62 08 00 00 15 00 00 00 00 00"),
            state: &state)
        let p = pens(r)
        XCTAssertEqual(p.count, 3, "three valid frames should each emit a sample")
        XCTAssertEqual(p.last?.x, 8746)
        XCTAssertEqual(p.last?.y, 6271)
        XCTAssertEqual(p.last?.pressure, 3251)
        XCTAssertEqual(p.last?.inProximity, true)
        XCTAssertEqual(p.last?.eraser, false)
    }

    /// Barrel button 1 held while drawing — status 0xE3 sets bit 1 on top of
    /// valid/prox/range.
    func testBarrelButtonOne() {
        var state = DecoderState()
        let r = decode(
            hex(
                "81 E1 54 26 91 16 DF 07 14 E1 56 26 9C 16 05 08 13 E3 5B 26 AE 16 26 08 13 "
                    + "00 00 00 00 00 00 00 00 96 40 80 04 62 08 10 00 62 08 00 00 14 00 00 00 00 00"),
            state: &state)
        let p = pens(r)
        XCTAssertEqual(p.last?.penButton1, true)
        XCTAssertEqual(p.last?.penButton2, false)
        XCTAssertEqual(p.last?.x, 9819)
        XCTAssertEqual(p.last?.pressure, 2086)
    }

    /// Hovering out of coordinate range (status 0xC0: prox set, range clear).
    /// The frame's coordinate bytes are stale here, so the decoder must hold
    /// the last known position — reporting the raw bytes is what produced
    /// cursor jumps to (0,0) in an earlier third-party implementation.
    func testOutOfRangeHoldsLastPosition() {
        var state = DecoderState()
        // Establish a position with an in-range frame first.
        _ = decode(
            hex(
                "81 E0 F0 26 D7 17 00 00 3A E0 EC 26 C8 17 00 00 3A 00 00 00 00 00 00 00 00 "
                    + "00 00 00 00 00 00 00 00 96 40 80 04 62 08 10 00 62 08 00 00 14 00 00 00 00 00"),
            state: &state)
        let r = decode(
            hex(
                "81 C0 23 27 FD 16 00 00 3F C0 23 27 FD 16 00 00 3F 00 00 00 00 00 00 00 00 "
                    + "00 00 00 00 00 00 00 00 96 40 80 04 62 08 10 00 62 08 00 00 14 00 00 00 00 00"),
            state: &state)
        let p = pens(r)
        XCTAssertFalse(p.isEmpty)
        XCTAssertEqual(p.last?.x, 9964, "out-of-range frame must not move the cursor")
        XCTAssertEqual(p.last?.y, 6088)
    }

    // MARK: - ExpressKeys

    /// Byte 44 bits 0-3 are the four ExpressKeys. All 622 aux-bearing records
    /// in the capture matched this mapping.
    func testExpressKeyBitmap() {
        for (bit, index) in [(UInt8(0x01), 0), (0x02, 1), (0x04, 2), (0x08, 3)] {
            var state = DecoderState()
            var bytes = [UInt8](repeating: 0, count: 51)
            bytes[0] = 0x81
            bytes[44] = bit
            let aux = decode(bytes, state: &state).compactMap {
                if case .aux(let a) = $0 { return a } else { return nil }
            }
            XCTAssertEqual(aux.count, 1)
            XCTAssertEqual(
                aux.first?.buttons[index], true, "bit \(bit) should map to ExpressKey \(index + 1)")
        }
    }

    /// An ExpressKey pressed with the pen away: no frame has the valid bit, so
    /// there is no pen sample — but the key must still report. Suppressing the
    /// whole container when no pen frame is valid makes the keys die whenever
    /// the pen is out of range.
    func testAuxOnlyReportEmitsNoPenSample() {
        var state = DecoderState()
        let r = decode(
            hex(
                "81 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 "
                    + "00 00 00 00 00 00 00 00 96 40 80 04 62 08 10 00 62 08 00 08 14 00 00 00 00 00"),
            state: &state)
        XCTAssertTrue(pens(r).isEmpty, "no valid pen frame must not fabricate a (0,0) sample")
        let aux = r.compactMap { if case .aux(let a) = $0 { return a } else { return nil } }
        XCTAssertEqual(aux.first?.buttons[3], true, "ExpressKey 4 still reports with the pen away")
    }

    // MARK: - Battery

    /// Byte 45: bit 7 charging, bits 0-6 percent. The capture ran on battery at
    /// 20-21%, bit 7 clear throughout.
    func testBatteryFromCapture() {
        var state = DecoderState()
        let r = decode(
            hex(
                "81 C0 23 27 FD 16 00 00 3F 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 "
                    + "00 00 00 00 00 00 00 00 96 40 80 04 62 08 10 00 62 08 00 00 14 00 00 00 00 00"),
            state: &state)
        let batteries = r.compactMap { result -> (Int, Bool)? in
            if case .battery(let pct, let charging) = result { return (pct, charging) }
            return nil
        }
        XCTAssertEqual(batteries.count, 1)
        XCTAssertEqual(batteries.first?.0, 20)
        XCTAssertEqual(batteries.first?.1, false)
    }

    func testChargingBitSetsFlag() {
        var state = DecoderState()
        var bytes = [UInt8](repeating: 0, count: 51)
        bytes[0] = 0x81
        bytes[45] = 0x80 | 55
        let r = decode(bytes, state: &state)
        let batteries = r.compactMap { result -> (Int, Bool)? in
            if case .battery(let pct, let charging) = result { return (pct, charging) }
            return nil
        }
        XCTAssertEqual(batteries.first?.0, 55)
        XCTAssertEqual(batteries.first?.1, true)
    }

    // MARK: - Length guard

    /// The kernel accepts this family from 46 bytes; below that, bytes 44/45
    /// don't exist and the container must be rejected rather than read past.
    func testShortReportRejected() {
        var state = DecoderState()
        var bytes = [UInt8](repeating: 0, count: 45)
        bytes[0] = 0x81
        XCTAssertTrue(decode(bytes, state: &state).isEmpty)
    }
}
