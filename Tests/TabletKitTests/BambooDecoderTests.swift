// SPDX-License-Identifier: MPL-2.0
//
// Bamboo decoder fixtures, synthesized from the byte layouts in
// BambooDecoder.swift and the kernel's wacom_bpt_pen / wacom_bpt_touch. The
// pen range and contact tests replay reports from public hid-devices
// recordings of a CTL-460, CTL-480, and CTH-680.
import XCTest
@testable import TabletKit

final class BambooDecoderTests: XCTestCase {

    // CTH-470: 4 express keys, hasTilt, maxPressure=1023
    private let cth470 = DigitizerSpec(
        maxX: 21648, maxY: 13530, maxPressure: 1023,
        buttonCount: 4, hasTilt: true, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 0)

    private func decode(
        _ bytes: [UInt8], state: inout BambooDecoder.State,
        spec: DigitizerSpec? = nil, family: DeviceFamily = .bamboo
    ) -> [DecodeResult] {
        var decoder = BambooDecoder()
        let s = spec ?? cth470
        return HIDReport.withReport(bytes) { report in
            decoder.decode(
                report: report,
                spec: s, state: &state, deviceFamily: family)
        }
    }

    // MARK: - BAMBOO_PT report 0x02 (CTL-460 class, kernel wacom_bpt_pen)

    // CTL-460: pen-only, no express keys, no tilt, maxPressure=1023
    private let ctl460 = DigitizerSpec(
        maxX: 14720, maxY: 9200, maxPressure: 1023,
        buttonCount: 0, hasTilt: false, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 0)

    /// Build a 9-byte BAMBOO_PT report: LE16 X/Y/pressure, distance byte.
    private func makeBPT(
        status: UInt8, x: UInt16 = 0, y: UInt16 = 0,
        pressure: UInt16 = 0, distance: UInt8 = 0
    ) -> [UInt8] {
        [0x02, status,
         UInt8(x & 0xFF), UInt8(x >> 8),
         UInt8(y & 0xFF), UInt8(y >> 8),
         UInt8(pressure & 0xFF), UInt8(pressure >> 8),
         distance]
    }

    func testBPTLE16CoordinatesAndPressure() {
        var st = BambooDecoder.State()
        let b = makeBPT(status: 0xE0 | 0x01, x: 0x1234, y: 0x2345, pressure: 1000)
        let r = decode(b, state: &st, spec: ctl460)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail("expected .pen") }
        XCTAssertEqual(pt.x, 0x1234)
        XCTAssertEqual(pt.y, 0x2345)
        XCTAssertEqual(pt.pressure, 1000)
        XCTAssertTrue(pt.inProximity)
    }

    func testBPTToolEnterAndBarrelButtons() {
        var st = BambooDecoder.State()
        let b = makeBPT(status: 0xE0 | 0x02 | 0x04)
        let r = decode(b, state: &st, spec: ctl460)
        guard case .toolEnter(let id)? = (r.first { if case .toolEnter = $0 { return true }; return false })
        else { return XCTFail("expected .toolEnter") }
        XCTAssertEqual(id.toolCode, 0x0802)
        XCTAssertFalse(id.isEraser)
        guard case .pen(let pt)? = (r.first { if case .pen = $0 { return true }; return false })
        else { return XCTFail("expected .pen") }
        XCTAssertTrue(pt.penButton1)
        XCTAssertTrue(pt.penButton2)
    }

    func testBPTEraserToolBit() {
        var st = BambooDecoder.State()
        let b = makeBPT(status: 0xE0 | 0x08)
        let r = decode(b, state: &st, spec: ctl460)
        guard case .toolEnter(let id)? = (r.first { if case .toolEnter = $0 { return true }; return false })
        else { return XCTFail("expected .toolEnter") }
        XCTAssertTrue(id.isEraser)
        XCTAssertEqual(id.toolCode, 0x080A)
    }

    func testBPTProximityExit() {
        var st = BambooDecoder.State()
        _ = decode(makeBPT(status: 0xE0, x: 500, y: 600), state: &st, spec: ctl460)
        XCTAssertTrue(st.prevInProximity)
        let r = decode(makeBPT(status: 0x00), state: &st, spec: ctl460)
        guard case .pen(let pt)? = (r.first { if case .pen = $0 { return true }; return false })
        else { return XCTFail("expected .pen exit") }
        XCTAssertFalse(pt.inProximity)
        XCTAssertEqual(pt.pressure, 0)
        XCTAssertEqual(pt.x, 500)
        XCTAssertEqual(pt.y, 600)
        XCTAssertFalse(st.prevInProximity)
    }

    func testBPTOutOfProximityIdleFramesProduceNothing() {
        var st = BambooDecoder.State()
        XCTAssertTrue(decode(makeBPT(status: 0x00), state: &st, spec: ctl460).isEmpty)
    }

    func testBPTHoverDistance() {
        var st = BambooDecoder.State()
        let b = makeBPT(status: 0xE0, distance: 42)
        let r = decode(b, state: &st, spec: ctl460)
        guard case .pen(let pt)? = (r.first { if case .pen = $0 { return true }; return false })
        else { return XCTFail("expected .pen") }
        XCTAssertEqual(pt.hoverDistance, 42)
    }

    func testBPTTooShortReturnsEmpty() {
        var st = BambooDecoder.State()
        XCTAssertTrue(decode(Array(makeBPT(status: 0xE0).dropLast()), state: &st, spec: ctl460).isEmpty)
    }

    // MARK: - BAMBOO_PT touch report 0x02, 20 bytes (CTH-460 class, kernel wacom_bpt_touch)

    // CTH-460: 4 express keys, 2FG touch, 480×320 wire space.
    private let cth460Touch = DigitizerSpec(
        maxX: 14720, maxY: 9200, maxPressure: 1023,
        buttonCount: 4, hasTilt: false, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 0)

    /// Build a 20-byte BAMBOO_PT touch report. `padByte` carries the stride
    /// selector (bit 7) and the 4 express keys (bits 3..0). `contacts` are
    /// (x, y) pairs, in slot order; a nil entry marks that slot lifted. X/Y
    /// are packed into 11 bits, big-endian, matching kernel's
    /// `get_unaligned_be16(...) & 0x7ff`, with the touch-down flag folded
    /// into bit 7 of the byte the mask discards.
    private func makeBPTTouch(padByte: UInt8, contacts: [(x: UInt16, y: UInt16)?]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x02
        bytes[1] = padByte
        let stride = (padByte & 0x80) != 0 ? 8 : 9
        for (i, contact) in contacts.enumerated() {
            guard let contact else { continue }
            let offset = stride * i
            let xHi = UInt8((contact.x >> 8) & 0x07) | 0x80  // touch-down bit + X bits 10:8
            bytes[offset + 3] = xHi
            bytes[offset + 4] = UInt8(contact.x & 0xFF)
            bytes[offset + 5] = UInt8((contact.y >> 8) & 0x07)
            bytes[offset + 6] = UInt8(contact.y & 0xFF)
        }
        return bytes
    }

    func testBPTTouchSingleContactStride9() {
        var st = BambooDecoder.State()
        let b = makeBPTTouch(padByte: 0x00, contacts: [(x: 300, y: 200), nil])
        let r = decode(b, state: &st, spec: cth460Touch)
        guard case .touch(let contacts)? = (r.first { if case .touch = $0 { return true }; return false })
        else { return XCTFail("expected .touch") }
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].id, 0)
        XCTAssertEqual(contacts[0].x, 300)
        XCTAssertEqual(contacts[0].y, 200)
    }

    func testBPTTouchTwoContactsStride8() {
        var st = BambooDecoder.State()
        let b = makeBPTTouch(padByte: 0x80, contacts: [(x: 10, y: 20), (x: 400, y: 300)])
        let r = decode(b, state: &st, spec: cth460Touch)
        guard case .touch(let contacts)? = (r.first { if case .touch = $0 { return true }; return false })
        else { return XCTFail("expected .touch") }
        XCTAssertEqual(contacts.count, 2)
        XCTAssertEqual(contacts[0].id, 0)
        XCTAssertEqual(contacts[0].x, 10)
        XCTAssertEqual(contacts[0].y, 20)
        XCTAssertEqual(contacts[1].id, 1)
        XCTAssertEqual(contacts[1].x, 400)
        XCTAssertEqual(contacts[1].y, 300)
    }

    func testBPTTouchAllFingersLiftedEmitsEmptyArray() {
        var st = BambooDecoder.State()
        let b = makeBPTTouch(padByte: 0x00, contacts: [nil, nil])
        let r = decode(b, state: &st, spec: cth460Touch)
        guard case .touch(let contacts)? = (r.first { if case .touch = $0 { return true }; return false })
        else { return XCTFail("expected .touch") }
        XCTAssertTrue(contacts.isEmpty)
    }

    func testBPTTouchExpressKeysFromByte1() {
        var st = BambooDecoder.State()
        // bits 3,2,1,0 → BTN_0..BTN_3; set BTN_0 and BTN_3.
        let b = makeBPTTouch(padByte: 0x09, contacts: [nil, nil])
        let r = decode(b, state: &st, spec: cth460Touch)
        guard case .aux(let buttons)? = (r.first { if case .aux = $0 { return true }; return false })
        else { return XCTFail("expected .aux") }
        XCTAssertEqual(buttons.buttons, [true, false, false, true])
    }

    func testBPTTouchNoAuxWhenButtonCountZero() {
        var st = BambooDecoder.State()
        let b = makeBPTTouch(padByte: 0x0F, contacts: [nil, nil])
        let r = decode(b, state: &st, spec: ctl460)
        let auxResult = r.first { if case .aux = $0 { return true }; return false }
        XCTAssertNil(auxResult, "pen-only CTL-460 spec should produce no aux event")
    }
}

// MARK: - Registry rows the kernel and Wacom both class as Bamboo PT

extension BambooDecoderTests {
    func testBambooPTFamilyRowsUseBambooParserAndDecodePen() throws {
        for pid in [0x00DD, 0x037A, 0x037B] {
            let row = try XCTUnwrap(WacomDeviceRegistry.spec(for: pid))
            XCTAssertEqual(row.format, .bamboo, "0x\(String(pid, radix: 16))")
            var st = BambooDecoder.State()
            let r = decode(makeBPT(status: 0xE0 | 0x01, x: 0x1234, y: 0x0567, pressure: 900),
                           state: &st, spec: row.digitizerSpec)
            guard case .pen(let pt)? = (r.first { if case .pen = $0 { return true }; return false })
            else { return XCTFail("expected .pen for 0x\(String(pid, radix: 16))") }
            XCTAssertEqual(pt.x, 0x1234)
            XCTAssertEqual(pt.pressure, 900)
            XCTAssertTrue(pt.inProximity)
        }
    }

    // MARK: - Bamboo Pad container (0x10, 32/64 bytes)

    // Bamboo Pad: 2 click buttons, 511 pressure. Synthesized from the
    // descriptors' layout; no capture exists.
    private var bambooPad: DigitizerSpec {
        DigitizerSpec(
            maxX: 10690, maxY: 6680, maxPressure: 511,
            buttonCount: 2, hasTilt: false, hasDualRings: false,
            isPenDisplay: false, ringSlotCount: 0)
    }

    private func makePad(length: Int = 64, parts: UInt8, pen: [UInt8] = [], touch: [UInt8] = []) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: length)
        r[0] = 0x10
        r[1] = parts
        for (i, b) in pen.enumerated() { r[2 + i] = b }
        for (i, b) in touch.enumerated() { r[9 + i] = b }
        return r
    }

    func testBambooPadPenDecodesLittleEndianFields() {
        var state = BambooDecoder.State()
        // Tip + barrel + in range; X 0x1234, Y 0x0567, pressure 0x0100.
        let r = makePad(parts: 0x01, pen: [0x23, 0x34, 0x12, 0x67, 0x05, 0x00, 0x01])
        let results = decode(r, state: &state, spec: bambooPad)
        XCTAssertTrue(results.contains { if case .toolEnter = $0 { return true }; return false })
        guard case .pen(let pt)? = results.last else { return XCTFail("no pen point: \(results)") }
        XCTAssertEqual(pt.x, 0x1234)
        XCTAssertEqual(pt.y, 0x0567)
        XCTAssertEqual(pt.pressure, 0x0100)
        XCTAssertTrue(pt.penButton1)
        XCTAssertFalse(pt.eraser)
        XCTAssertTrue(pt.inProximity)
    }

    func testBambooPadEraserAndWirelessLength() {
        var state = BambooDecoder.State()
        // Invert + eraser + in range, 32-byte wireless container.
        let r = makePad(length: 32, parts: 0x01, pen: [0x2C, 0x10, 0x00, 0x20, 0x00, 0x50, 0x00])
        guard case .pen(let pt)? = decode(r, state: &state, spec: bambooPad).last else {
            return XCTFail("no pen point")
        }
        XCTAssertTrue(pt.eraser)
        XCTAssertEqual(pt.pressure, 0x50)
    }

    func testBambooPadPenExitAfterRange() {
        var state = BambooDecoder.State()
        _ = decode(makePad(parts: 0x01, pen: [0x20, 0x10, 0x00, 0x20, 0x00]), state: &state, spec: bambooPad)
        let results = decode(makePad(parts: 0x00), state: &state, spec: bambooPad)
        guard case .pen(let pt)? = results.first else { return XCTFail("no exit point: \(results)") }
        XCTAssertFalse(pt.inProximity)
    }

    func testBambooPadTouchAndClickButtons() {
        var state = BambooDecoder.State()
        // Fingers 0 and 2 live, left click held. Finger 0: X 0x123, Y 0x456.
        // Finger 2: X 0xFFF, Y 0x000.
        let touch: [UInt8] = [0x45, 0x23, 0x61, 0x45, 0, 0, 0, 0xFF, 0x0F, 0x00]
        let results = decode(makePad(parts: 0x02, touch: touch), state: &state, spec: bambooPad)
        guard case .touch(let contacts)? = results.first else { return XCTFail("no touch: \(results)") }
        XCTAssertEqual(contacts.map(\.id), [0, 2])
        XCTAssertEqual(contacts[0].x, 0x123)
        XCTAssertEqual(contacts[0].y, 0x456)
        XCTAssertEqual(contacts[1].x, 0xFFF)
        XCTAssertEqual(contacts[1].y, 0)
        guard case .aux(let aux)? = results.last else { return XCTFail("no buttons") }
        XCTAssertEqual(Array(aux.buttons.prefix(2)), [true, false])
    }
}

// MARK: - Range, position, and contact follow the tablet's own bits

extension BambooDecoderTests {
    private func hexReport(_ s: String) -> [UInt8] {
        s.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    private func pens(_ reports: [String], pid: Int) throws -> [TabletPoint?] {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: pid)).digitizerSpec
        var st = BambooDecoder.State()
        return reports.map { report in
            let r = decode(hexReport(report), state: &st, spec: spec)
            guard case .pen(let pt)? = (r.first { if case .pen = $0 { return true }; return false })
            else { return nil }
            return pt
        }
    }

    /// CTL-480: pressure reaches 59 while the tablet never sets its tip bit.
    func testPressureWithoutTipBitIsNotContact() throws {
        let p = try pens([
            "02 f0 c0 2a 51 0e 00 00 29 00",
            "02 f0 c1 2a 52 0e 3b 00 29 00",
            "02 f0 c9 2a 59 0e 3b 00 29 00",
            "02 f0 ce 2a 63 0e 06 00 29 00",
            "02 f0 e3 2a 70 0e 00 00 29 00",
        ], pid: 0x030E)
        XCTAssertEqual(p.map { $0?.pressure }, [0, 0, 0, 0, 0])
    }

    /// CTH-680: the tablet lifts for two reports at pressure 39 and 34, so
    /// one stroke becomes two.
    func testLiftBetweenStrokesFollowsTipBit() throws {
        let p = try pens([
            "02 e1 70 11 7a 17 3e 00 2b 00",
            "02 e0 7b 11 78 17 27 00 2b 00",
            "02 e0 88 11 73 17 22 00 2b 00",
            "02 e1 59 11 ba 17 7f 01 2b 00",
        ], pid: 0x0303)
        XCTAssertEqual(p.map { $0?.pressure }, [62, 0, 0, 383])
    }

    /// CTL-480: high in the hover the tablet sends a position without the
    /// ready bit. The pen arrives and moves; pressure stays 0.
    func testPositionWithoutReadyBitBringsPenIn() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x030E)).digitizerSpec
        var st = BambooDecoder.State()
        let r = decode(hexReport("02 d0 45 31 75 10 00 00 27 00"), state: &st, spec: spec)
        guard case .toolEnter(let id)? = r.first else { return XCTFail("expected .toolEnter") }
        XCTAssertFalse(id.isEraser)
        guard case .pen(let pt)? = r.last else { return XCTFail("expected .pen") }
        XCTAssertTrue(pt.inProximity)
        XCTAssertEqual(pt.x, 0x3145)
        XCTAssertEqual(pt.y, 0x1075)
        XCTAssertEqual(pt.pressure, 0)
    }

    /// CTL-460: range alone, before any position, isn't an arrival.
    func testRangeWithoutPositionDoesNotBringPenIn() {
        var st = BambooDecoder.State()
        XCTAssertTrue(decode(hexReport("02 80 00 00 00 00 00 00 00"), state: &st, spec: ctl460).isEmpty)
        XCTAssertFalse(st.prevInProximity)
    }

    /// CTL-460: once in, the pen stays through range-only reports at its
    /// last position, and leaves when range clears.
    func testRangeOnlyHoldsPenUntilRangeClears() throws {
        let p = try pens([
            "02 e0 80 39 9c 10 01 00 09",
            "02 80 00 00 00 00 00 00 00",
            "02 00 00 00 00 00 00 00 00",
        ], pid: 0x00D4)
        XCTAssertEqual(p.map { $0?.inProximity }, [true, true, false])
        XCTAssertEqual(p.map { $0?.x }, [0x3980, 0x3980, 0x3980])
        XCTAssertEqual(p.map { $0?.pressure }, [0, 0, 0])
    }

    /// Barrel buttons count only with the ready bit, as in the kernel.
    func testBarrelButtonsNeedReadyBit() {
        var st = BambooDecoder.State()
        let r = decode(makeBPT(status: 0xC0 | 0x02 | 0x04, x: 100, y: 100), state: &st, spec: ctl460)
        guard case .pen(let pt)? = r.last else { return XCTFail("expected .pen") }
        XCTAssertFalse(pt.penButton1)
        XCTAssertFalse(pt.penButton2)
    }
}
