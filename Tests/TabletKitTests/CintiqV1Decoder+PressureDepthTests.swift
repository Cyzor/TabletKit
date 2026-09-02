// SPDX-License-Identifier: GPL-3.0-or-later
//
// CintiqV1 pressure-depth normalization.
//
// The decoder computes the 11-bit kernel form (d6<<3)|((d7&0xC0)>>5)|(d1&1).
// On 10-bit hardware that overshoots by exactly 2× and bit 0 of the status byte
// is not a pressure LSB, so it must be halved — the same correction
// IntuosV1Decoder applies.
//
// Without it, real captures of the Cintiq 12WX (0x00C6) and 21UX (0x003F) emit
// up to 1192 and 1280 against a declared maximum of 1023. That reads as a
// registry error but is not one: the parity of emitted values on those two is
// almost entirely even (158/161 and 101/104 nonzero frames), while genuinely
// 2048-level hardware (21UX2, 0x00CC) is mixed (208/484).
import XCTest

@testable import TabletKit

final class CintiqV1DecoderPressureDepthTests: XCTestCase {

    /// Cintiq 12WX / 21UX — 1024 pressure levels.
    private let tenBit = DigitizerSpec(
        maxX: 53020, maxY: 33440, maxPressure: 1023,
        buttonCount: 10, hasTilt: true, isPenDisplay: true)

    /// Cintiq 21UX2 — genuinely 2048 levels, the control case.
    private let elevenBit = DigitizerSpec(
        maxX: 87200, maxY: 65600, maxPressure: 2047,
        buttonCount: 8, hasTilt: true, isPenDisplay: true)

    private func seededState() -> DecoderState {
        var state = DecoderState()
        state.currentToolCode = 0x0842
        state.toolIsSupported = true
        return state
    }

    /// General pen packet with an explicit raw pressure field.
    /// The 11-bit raw value is (d6<<3) | ((d7 & 0xC0) >> 5) | (d1 & 1).
    private func packet(rawHigh: UInt8, statusLSB: Bool = false) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 10)
        bytes[0] = 0x02
        bytes[1] = 0xE0 | (statusLSB ? 0x01 : 0x00)
        bytes[2] = 0x01; bytes[3] = 0xF4
        bytes[4] = 0x07; bytes[5] = 0xD0
        bytes[6] = rawHigh
        bytes[7] = 0x20
        bytes[8] = 0x40
        bytes[9] = 0
        return bytes
    }

    private func decode(_ bytes: [UInt8], spec: DigitizerSpec) -> TabletPoint? {
        var decoder = CintiqV1Decoder()
        var state = seededState()
        let results = bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: spec, state: &state, deviceFamily: .cintiq)
        }
        for r in results { if case .pen(let p) = r { return p } }
        return nil
    }

    /// 0xFF << 3 = 2040 raw, which must land inside a 1023-level range.
    func testTenBitPressureStaysInRange() {
        let p = decode(packet(rawHigh: 0xFF), spec: tenBit)
        XCTAssertEqual(p?.pressure, 1020)
        XCTAssertLessThanOrEqual(p!.pressure, tenBit.maxPressure)
    }

    /// The same bytes on 2048-level hardware keep the full 11-bit value.
    func testElevenBitPressureIsNotHalved() {
        let p = decode(packet(rawHigh: 0xFF), spec: elevenBit)
        XCTAssertEqual(p?.pressure, 2040)
        XCTAssertLessThanOrEqual(p!.pressure, elevenBit.maxPressure)
    }

    /// Reproduces the observed 12WX overshoot: raw 1192 must normalize to 596.
    func testObserved12WXOvershootNormalizes() {
        let p = decode(packet(rawHigh: 149), spec: tenBit)  // 149 << 3 = 1192
        XCTAssertEqual(p?.pressure, 596)
    }

    /// Status bit 0 is not a pressure LSB on 10-bit hardware — setting it must
    /// not change the normalized result.
    func testStatusLSBDoesNotPerturbTenBitPressure() {
        let without = decode(packet(rawHigh: 149, statusLSB: false), spec: tenBit)
        let with = decode(packet(rawHigh: 149, statusLSB: true), spec: tenBit)
        XCTAssertEqual(without?.pressure, with?.pressure)
    }
}
