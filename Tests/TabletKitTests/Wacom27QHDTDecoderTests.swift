// SPDX-License-Identifier: GPL-3.0-or-later
//
// Wacom27QHDTDecoder fixtures (Cintiq 27QHD Touch / DTH-2700 touch sensor).
//
// Entirely synthesized — no capture exists for this device's touch
// interface. See Wacom27QHDTDecoder.swift and
// Notes/Scratch/wacom-24hdt-touch-design-2026-09-08.md for the kernel
// sources this byte layout is derived from.
import XCTest
@testable import TabletKit

final class Wacom27QHDTDecoderTests: XCTestCase {

    private let touchSpec = DigitizerSpec(
        maxX: 0, maxY: 0, maxPressure: 0,
        buttonCount: 0, hasTilt: false, hasDualRings: false,
        isPenDisplay: true, ringSlotCount: 0)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState
    ) -> [DecodeResult] {
        let decoder = Wacom27QHDTDecoder()
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: touchSpec, state: &state, deviceFamily: .cintiq)
        }
    }

    // MARK: - Helpers

    private struct Contact {
        var active: Bool
        var id: UInt8
        var x: UInt16
        var y: UInt16
    }

    /// Builds one 64-byte 0x05 report from up to 10 contact records, with
    /// the active-contact count in byte 63.
    private func makeReport(frameCount: UInt8, contacts: [Contact]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        b[0] = 0x05
        for (slot, c) in contacts.enumerated() {
            precondition(slot < 10, "at most 10 contact records per packet")
            let base = 1 + slot * 6
            b[base] = c.active ? 0x01 : 0x00
            b[base + 1] = c.id
            b[base + 2] = UInt8(c.x & 0xFF); b[base + 3] = UInt8(c.x >> 8)
            b[base + 4] = UInt8(c.y & 0xFF); b[base + 5] = UInt8(c.y >> 8)
        }
        b[63] = frameCount
        return b
    }

    // MARK: - Basic decode

    func testSingleContactDecodesImmediately() {
        var state = DecoderState()
        let report = makeReport(
            frameCount: 1,
            contacts: [Contact(active: true, id: 5, x: 100, y: 200)])
        let results = decode(report, state: &state)
        guard case .touch(let contacts)? = results.first else {
            return XCTFail("expected a single .touch result")
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].id, 5)
        XCTAssertEqual(contacts[0].x, 100)
        XCTAssertEqual(contacts[0].y, 200)
        XCTAssertNil(contacts[0].contactArea, "27QHDT records carry no width/height")
        XCTAssertNil(contacts[0].contactMinor)
    }

    func testAllTenContactsFitInOnePacket() {
        var state = DecoderState()
        let report = makeReport(
            frameCount: 10,
            contacts: (0..<10).map { Contact(active: true, id: UInt8($0), x: UInt16($0) * 10, y: 0) })
        let results = decode(report, state: &state)
        guard case .touch(let contacts)? = results.first else {
            return XCTFail("expected a single .touch result")
        }
        // Unlike WACOM_24HDT, the full 10-finger ceiling fits in one packet —
        // no multi-packet accumulator involved at all.
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(contacts.count, 10)
        XCTAssertEqual(contacts.map(\.id), Array(0..<10))
    }

    func testInactiveRecordIsOmittedFromTheFrame() {
        var state = DecoderState()
        let report = makeReport(
            frameCount: 2,
            contacts: [
                Contact(active: true, id: 0, x: 10, y: 10),
                Contact(active: false, id: 1, x: 20, y: 20),
            ])
        let results = decode(report, state: &state)
        guard case .touch(let contacts)? = results.first else {
            return XCTFail("expected a single .touch result")
        }
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].id, 0)
    }

    func testZeroFrameCountEmitsAnEmptyTouchFrame() {
        var state = DecoderState()
        let results = decode(makeReport(frameCount: 0, contacts: []), state: &state)
        guard case .touch(let contacts)? = results.first else {
            return XCTFail("expected an empty .touch result, not no result")
        }
        XCTAssertTrue(contacts.isEmpty)
    }

    // MARK: - Robustness

    func testGarbageFrameCountByteIsClampedToTenRecords() {
        var state = DecoderState()
        var report = makeReport(
            frameCount: 0,
            contacts: (0..<3).map { Contact(active: true, id: UInt8($0), x: 0, y: 0) })
        report[63] = 255
        let results = decode(report, state: &state)
        guard case .touch(let contacts)? = results.first else {
            return XCTFail("expected a single .touch result")
        }
        // Clamped to 10 records max, but only 3 were actually written —
        // the other 7 slots decode as inactive (all-zero status byte).
        XCTAssertEqual(contacts.count, 3)
    }

    func testWrongReportIDIsIgnored() {
        var state = DecoderState()
        var report = makeReport(frameCount: 1, contacts: [Contact(active: true, id: 0, x: 1, y: 1)])
        report[0] = 0x01
        XCTAssertTrue(decode(report, state: &state).isEmpty)
    }

    func testShortReportIsIgnored() {
        var state = DecoderState()
        let short = [UInt8](repeating: 0, count: 63)
        XCTAssertTrue(decode(short, state: &state).isEmpty)
    }
}
