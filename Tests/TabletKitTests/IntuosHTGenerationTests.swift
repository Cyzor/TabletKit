// SPDX-License-Identifier: GPL-3.0-or-later
//
// INTUOSHT generation (2013: CTH-480/680, CTL-480/680) — pen reports on
// ID 0x02 / 10 bytes / little-endian, plus the 64-byte BPT3 container shared
// with their INTUOSHT2 successors.
//
// These PIDs were assigned .intuosV1 until 2026-07-29, which reads coordinates
// big-endian and decoded every position to ~130,600 regardless of tablet size.
// Reports are synthesized here rather than lifted from the captures that
// established the layout, matching how the CTL-460 work handled provenance.
//
// The container fixtures mirror our own CTH-690 discovery capture (2026-07-03),
// which is what established that the container is identical across both
// generations — see BPT3ContainerDecoder.
//
// Named by hardware generation rather than <TypeName>Tests because it
// exercises both BambooDecoder and IntuosV1Decoder against the same
// PID range; there is no single type to name it after.
import XCTest

@testable import TabletKit

final class IntuosHTGenerationTests: XCTestCase {

    /// CTL-680 — pen-only, four express keys, no touch sensor.
    private let ctl680 = DigitizerSpec(
        maxX: 21600, maxY: 13500, maxPressure: 1023, buttonCount: 4)

    /// CTH-690 — INTUOSHT2 sibling, touch enabled. Same container, different pen path.
    private let cth690 = DigitizerSpec(
        maxX: 21600, maxY: 13500, maxPressure: 2047,
        buttonCount: 4, hasFingerTouch: true, maxTouchContacts: 16)

    private func decodeBamboo(
        _ bytes: [UInt8], spec: DigitizerSpec, state: inout DecoderState
    ) -> [DecodeResult] {
        var decoder = BambooDecoder()
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: spec, state: &state, deviceFamily: "intuosConsumer")
        }
    }

    /// 10-byte INTUOSHT pen report: LE16 X/Y/pressure, status bits per wacom_bpt_pen.
    private func penReport(
        status: UInt8, x: Int, y: Int, pressure: Int, distance: UInt8 = 0
    ) -> [UInt8] {
        [
            0x02, status,
            UInt8(x & 0xFF), UInt8((x >> 8) & 0xFF),
            UInt8(y & 0xFF), UInt8((y >> 8) & 0xFF),
            UInt8(pressure & 0xFF), UInt8((pressure >> 8) & 0xFF),
            distance, 0,
        ]
    }

    private func makeContainer(_ messages: [[UInt8]]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x02
        bytes[1] = UInt8(messages.count)
        for (i, msg) in messages.prefix(7).enumerated() {
            for (j, b) in msg.prefix(8).enumerated() { bytes[2 + i * 8 + j] = b }
        }
        return bytes
    }

    private func point(_ results: [DecodeResult]) -> TabletPoint? {
        for r in results { if case .pen(let p) = r { return p } }
        return nil
    }

    private func aux(_ results: [DecodeResult]) -> AuxButtons? {
        for r in results { if case .aux(let a) = r { return a } }
        return nil
    }

    private func touches(_ results: [DecodeResult]) -> [TouchContact]? {
        for r in results { if case .touch(let t) = r { return t } }
        return nil
    }

    // MARK: - Pen decode (the reassignment)

    /// The boundary case that identified the misassignment: a pen at the far
    /// corner must decode to exactly maxX/maxY, not the ~130,600 the big-endian
    /// IntuosV1 path produced for every position regardless of tablet size.
    func testPenAtFarCornerDecodesToRegisteredMaximum() {
        var state = DecoderState()
        let results = decodeBamboo(
            penReport(status: 0xF0, x: 21600, y: 13035, pressure: 0),
            spec: ctl680, state: &state)
        let p = point(results)
        XCTAssertEqual(p?.x, 21600)
        XCTAssertEqual(p?.y, 13035)
        XCTAssertLessThanOrEqual(p!.x, ctl680.maxX)
        XCTAssertLessThanOrEqual(p!.y, ctl680.maxY)
    }

    func testPenCoordinatesAreLittleEndian() {
        var state = DecoderState()
        // 0x1744 = 5956. A big-endian read of the same bytes gives 0x4417<<1 = 34862.
        let results = decodeBamboo(
            penReport(status: 0xF0, x: 0x1744, y: 0x0D48, pressure: 0),
            spec: ctl680, state: &state)
        XCTAssertEqual(point(results)?.x, 5956)
        XCTAssertEqual(point(results)?.y, 3400)
    }

    func testTipContactReportsPressureAndBarrelButtons() {
        var state = DecoderState()
        _ = decodeBamboo(
            penReport(status: 0xF0, x: 100, y: 100, pressure: 0), spec: ctl680, state: &state)
        // 0xF3 = in proximity (0x20) + tip (0x01) + barrel 1 (0x02).
        let results = decodeBamboo(
            penReport(status: 0xF3, x: 100, y: 100, pressure: 918),
            spec: ctl680, state: &state)
        let p = point(results)
        XCTAssertEqual(p?.pressure, 918)
        XCTAssertTrue(p?.penButton1 == true)
        XCTAssertFalse(p?.penButton2 == true)
    }

    func testEraserStatusBitDecodes() {
        var state = DecoderState()
        let results = decodeBamboo(
            penReport(status: 0xF8, x: 100, y: 100, pressure: 0), spec: ctl680, state: &state)
        XCTAssertTrue(point(results)?.eraser == true)
    }

    // MARK: - Container routing (the blocker this fix had to clear)

    /// Pen and container share report ID 0x02 and are told apart only by length.
    /// Before the length guard, a 64-byte container decoded as pen coordinates.
    func testContainerIsNotDecodedAsPenCoordinates() {
        var state = DecoderState()
        let container = makeContainer([[0x80, 0x0F, 0, 0, 0, 0, 0, 0]])
        let results = decodeBamboo(container, spec: ctl680, state: &state)
        XCTAssertNil(point(results), "64-byte container must not produce a pen point")
        XCTAssertNotNil(aux(results), "64-byte container must produce pad buttons")
    }

    /// Pen-only models still have four express keys. Gating container entry on
    /// hasFingerTouch (as the IntuosV1 path used to) would leave these dead.
    func testPadButtonsDecodeOnPenOnlyModel() {
        var state = DecoderState()
        XCTAssertFalse(ctl680.hasFingerTouch)
        let results = decodeBamboo(
            makeContainer([[0x80, 0x0F, 0, 0, 0, 0, 0, 0]]), spec: ctl680, state: &state)
        XCTAssertEqual(aux(results)?.buttons, [true, true, true, true])
    }

    func testPadButtonsDecodeIndividually() {
        var state = DecoderState()
        let results = decodeBamboo(
            makeContainer([[0x80, 0x02, 0, 0, 0, 0, 0, 0]]), spec: ctl680, state: &state)
        XCTAssertEqual(aux(results)?.buttons, [false, true, false, false])
    }

    /// Touch must stay gated on hasFingerTouch even though container entry is not.
    func testTouchMessagesIgnoredWithoutFingerTouch() {
        var state = DecoderState()
        let touchMsg: [UInt8] = [0x05, 0x80, 0x51, 0x53, 0x57, 3, 3, 0]
        let results = decodeBamboo(
            makeContainer([touchMsg]), spec: ctl680, state: &state)
        XCTAssertNil(touches(results), "pen-only spec must not emit touch contacts")
    }

    /// Same container bytes, touch-capable spec: contacts decode. This is the
    /// cross-generation claim — one container implementation, two pen formats.
    func testSameContainerDecodesTouchOnTouchCapableSpec() {
        var state = DecoderState()
        let touchMsg: [UInt8] = [0x05, 0x80, 0x51, 0x53, 0x57, 3, 3, 0]
        var decoder = IntuosV1Decoder()
        let container = makeContainer([touchMsg])
        let results = container.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: container.count,
                spec: cth690, state: &state, deviceFamily: "intuosConsumer")
        }
        let contacts = touches(results)
        XCTAssertEqual(contacts?.count, 1)
        XCTAssertEqual(contacts?.first?.id, 5)
        XCTAssertEqual(contacts?.first?.x, 1301)
        XCTAssertEqual(contacts?.first?.y, 1335)
    }
}
