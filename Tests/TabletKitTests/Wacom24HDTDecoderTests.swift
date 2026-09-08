// SPDX-License-Identifier: GPL-3.0-or-later
//
// Wacom24HDTDecoder fixtures (DTH-1300/DTH-2400 touch sensors).
//
// Entirely synthesized — no capture exists for either device's touch
// interface. See Wacom24HDTDecoder.swift and
// Notes/Scratch/wacom-24hdt-touch-design-2026-09-08.md for the kernel/OTD
// sources this byte layout is derived from and the open questions a real
// capture would need to settle.
import XCTest
@testable import TabletKit

final class Wacom24HDTDecoderTests: XCTestCase {

    private let touchSpec = DigitizerSpec(
        maxX: 0, maxY: 0, maxPressure: 0,
        buttonCount: 0, hasTilt: false, hasDualRings: false,
        isPenDisplay: true, ringSlotCount: 0)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState
    ) -> [DecodeResult] {
        let decoder = Wacom24HDTDecoder()
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
        var width: UInt16 = 0
        var height: UInt16 = 0
    }

    /// Builds one 62-byte 0x01 report from up to 4 contact records, with the
    /// given total-frame count in byte 61.
    private func makeReport(frameCount: UInt8, contacts: [Contact]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 62)
        b[0] = 0x01
        for (slot, c) in contacts.enumerated() {
            precondition(slot < 4, "at most 4 contact records per packet")
            let base = 1 + slot * 14
            b[base] = c.active ? 0x01 : 0x00
            b[base + 1] = c.id
            b[base + 2] = UInt8(c.x & 0xFF); b[base + 3] = UInt8(c.x >> 8)
            b[base + 6] = UInt8(c.y & 0xFF); b[base + 7] = UInt8(c.y >> 8)
            b[base + 10] = UInt8(c.width & 0xFF); b[base + 11] = UInt8(c.width >> 8)
            b[base + 12] = UInt8(c.height & 0xFF); b[base + 13] = UInt8(c.height >> 8)
        }
        b[61] = frameCount
        return b
    }

    // MARK: - Single-packet frames (≤4 fingers)

    func testSingleContactCompletesImmediately() {
        var state = DecoderState()
        let report = makeReport(
            frameCount: 1,
            contacts: [Contact(active: true, id: 5, x: 100, y: 200, width: 10, height: 12)])
        let results = decode(report, state: &state)
        guard case .touch(let contacts)? = results.first else {
            return XCTFail("expected a single .touch result")
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].id, 5)
        XCTAssertEqual(contacts[0].x, 100)
        XCTAssertEqual(contacts[0].y, 200)
        // touchMajor/Minor both derive from min(width, height) per the kernel.
        XCTAssertEqual(contacts[0].contactArea, 10)
        XCTAssertEqual(contacts[0].contactMinor, 10)
        XCTAssertEqual(state.wacom24HDTRemainingContacts, 0)
        XCTAssertTrue(state.wacom24HDTPendingContacts.isEmpty)
    }

    func testFourContactsInOnePacketCompleteImmediately() {
        var state = DecoderState()
        let report = makeReport(
            frameCount: 4,
            contacts: [
                Contact(active: true, id: 0, x: 10, y: 10),
                Contact(active: true, id: 1, x: 20, y: 20),
                Contact(active: true, id: 2, x: 30, y: 30),
                Contact(active: true, id: 3, x: 40, y: 40),
            ])
        let results = decode(report, state: &state)
        guard case .touch(let contacts)? = results.first else {
            return XCTFail("expected a single .touch result")
        }
        XCTAssertEqual(contacts.count, 4)
        XCTAssertEqual(contacts.map(\.id), [0, 1, 2, 3])
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
        // The frame count says 2 records were sent, but only the active one
        // is surfaced — matching how IntuosV2Decoder's touch path already
        // filters inactive slots.
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].id, 0)
    }

    // MARK: - Multi-packet frames (>4 fingers)

    func testSevenFingerFrameSplitsAcrossTwoPackets() {
        var state = DecoderState()

        let packet1 = makeReport(
            frameCount: 7,
            contacts: (0..<4).map { Contact(active: true, id: UInt8($0), x: UInt16($0) * 10, y: 0) })
        let firstResults = decode(packet1, state: &state)
        XCTAssertTrue(firstResults.isEmpty, "frame should not complete until all 7 records arrive")
        XCTAssertEqual(state.wacom24HDTRemainingContacts, 3)
        XCTAssertEqual(state.wacom24HDTPendingContacts.count, 4)

        let packet2 = makeReport(
            frameCount: 0,
            contacts: (4..<7).map { Contact(active: true, id: UInt8($0), x: UInt16($0) * 10, y: 0) })
        let secondResults = decode(packet2, state: &state)
        guard case .touch(let contacts)? = secondResults.first else {
            return XCTFail("expected the frame to complete on the second packet")
        }
        XCTAssertEqual(secondResults.count, 1)
        XCTAssertEqual(contacts.count, 7)
        XCTAssertEqual(contacts.map(\.id), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(state.wacom24HDTRemainingContacts, 0)
        XCTAssertTrue(state.wacom24HDTPendingContacts.isEmpty)
    }

    func testTenFingerFrameSplitsAcrossThreePackets() {
        var state = DecoderState()

        _ = decode(
            makeReport(frameCount: 10, contacts: (0..<4).map { Contact(active: true, id: UInt8($0), x: 0, y: 0) }),
            state: &state)
        XCTAssertEqual(state.wacom24HDTRemainingContacts, 6)

        _ = decode(
            makeReport(frameCount: 0, contacts: (4..<8).map { Contact(active: true, id: UInt8($0), x: 0, y: 0) }),
            state: &state)
        XCTAssertEqual(state.wacom24HDTRemainingContacts, 2)

        let final = decode(
            makeReport(frameCount: 0, contacts: (8..<10).map { Contact(active: true, id: UInt8($0), x: 0, y: 0) }),
            state: &state)
        guard case .touch(let contacts)? = final.first else {
            return XCTFail("expected the frame to complete on the third packet")
        }
        XCTAssertEqual(contacts.count, 10)
    }

    // MARK: - Robustness

    func testFreshNonzeroCountResetsAStalledAccumulation() {
        var state = DecoderState()
        // Start a 7-finger frame but only ever deliver the first packet
        // (simulating a dropped packet mid-frame).
        _ = decode(
            makeReport(frameCount: 7, contacts: (0..<4).map { Contact(active: true, id: UInt8($0), x: 0, y: 0) }),
            state: &state)
        XCTAssertEqual(state.wacom24HDTRemainingContacts, 3)

        // A fresh nonzero count must reset, not add to, the stalled frame —
        // otherwise one dropped packet wedges the accumulator forever.
        let recovered = decode(
            makeReport(frameCount: 1, contacts: [Contact(active: true, id: 9, x: 5, y: 5)]),
            state: &state)
        guard case .touch(let contacts)? = recovered.first else {
            return XCTFail("expected the new frame to complete on its own")
        }
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].id, 9)
    }

    func testGarbageFrameCountByteIsClampedToPlausibleMax() {
        var state = DecoderState()
        // A corrupt byte 61 (e.g. 255) must not be trusted as a legitimate
        // frame size — this hardware family tops out at 10 fingers per the
        // kernel, and an unclamped count would accumulate state across many
        // packets before any reset could occur.
        var report = makeReport(
            frameCount: 0,
            contacts: (0..<4).map { Contact(active: true, id: UInt8($0), x: 0, y: 0) })
        report[61] = 255
        _ = decode(report, state: &state)
        XCTAssertEqual(state.wacom24HDTRemainingContacts, 6, "clamped to 10 total, minus the 4 just consumed")
    }

    func testZeroFrameCountWithNoAccumulationInProgressEmitsNothing() {
        var state = DecoderState()
        let results = decode(makeReport(frameCount: 0, contacts: []), state: &state)
        XCTAssertTrue(results.isEmpty)
    }

    func testWrongReportIDIsIgnored() {
        var state = DecoderState()
        var report = makeReport(frameCount: 1, contacts: [Contact(active: true, id: 0, x: 1, y: 1)])
        report[0] = 0x02
        XCTAssertTrue(decode(report, state: &state).isEmpty)
    }

    func testShortReportIsIgnored() {
        var state = DecoderState()
        let short = [UInt8](repeating: 0, count: 61)
        XCTAssertTrue(decode(short, state: &state).isEmpty)
    }
}
