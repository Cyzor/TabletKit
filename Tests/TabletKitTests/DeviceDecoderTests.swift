// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import TabletKit

final class DeviceDecoderTests: XCTestCase {

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// The wrapper must decode exactly what the format's decoder does when the
    /// caller carries the spec, state, and family itself.
    func testMatchesTheRawDecoderForEveryRegistryRow() {
        var rng = SplitMix64(state: 7)
        for spec in WacomDeviceRegistry.knownDevices {
            compare(spec.format.decoder(), against: spec, rng: &rng)
        }
    }

    private func compare<Raw: TabletReportDecoder>(_ raw: Raw, against spec: TabletSpec, rng: inout SplitMix64) {
        var raw = raw
        var wrapped = spec.makeDecoder()
        var state = Raw.State()
        for _ in 0..<200 {
            let ids: [UInt8] = [0x02, 0x03, 0x06, 0x0C, 0x10, 0x11, 0x1A, 0x1E, 0x1F, 0x20, 0x21, 0x80, 0x81]
            var bytes = (0..<64).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            bytes[0] = ids[Int(rng.next() % UInt64(ids.count))]
            bytes = Array(bytes.prefix(Int(rng.next() % 64) + 1))
            let a = HIDReport.withReport(bytes) { wrapped.decode($0) }
            let b = HIDReport.withReport(bytes) {
                raw.decode(report: $0, spec: spec.digitizerSpec, state: &state, deviceFamily: spec.family)
            }
            XCTAssertEqual(String(describing: a), String(describing: b), "\(spec.name)")
        }
        XCTAssertEqual(wrapped.penInRange, state.prevInProximity, spec.name)
    }

    func testResetForgetsThePen() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x0357))  // PTH-660, USB
        var decoder = spec.makeDecoder()
        // Report 0x10: in range (status 0x40) at a real position.
        var bytes = [UInt8](repeating: 0, count: 27)
        bytes[0] = 0x10; bytes[1] = 0xE0; bytes[2] = 0x10; bytes[3] = 0x27; bytes[5] = 0x10; bytes[6] = 0x27
        _ = HIDReport.withReport(bytes) { decoder.decode($0) }
        XCTAssertTrue(decoder.penInRange)
        decoder.reset()
        XCTAssertFalse(decoder.penInRange)
    }

    func testSpecSuppliesFormatRangesAndFamily() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x0357))
        let decoder = spec.makeDecoder()
        XCTAssertEqual(decoder.family, spec.family)
        XCTAssertEqual(decoder.digitizer.maxX, spec.maxX)
        XCTAssertNil(decoder.silenceTimeout)
    }

    func testFixedLayoutTouchCoversOnlyItsSensors() throws {
        let touch = DigitizerSpec(maxX: 100, maxY: 100, maxPressure: 0, hasFingerTouch: true)
        XCTAssertNil(DeviceDecoder.fixedLayoutTouch(productID: 0x00F4, digitizer: touch, family: .cintiq))
        var entry = try XCTUnwrap(
            DeviceDecoder.fixedLayoutTouch(productID: 0x00F6, digitizer: touch, family: .cintiq))
        XCTAssertEqual(entry.reportID, 0x01)
        // One active contact, id 5, at (100, 200); the frame count is last.
        var report = [UInt8](repeating: 0, count: 62)
        report[0] = 0x01
        report[1] = 0x01; report[2] = 5
        report[3] = 100; report[7] = 200
        report[61] = 1
        let events = HIDReport.withReport(report) { entry.decoder.events($0) }
        guard case .touch(let frame)? = events.first else { return XCTFail("expected a touch frame") }
        XCTAssertEqual(frame.contacts.map { [$0.id, $0.x, $0.y] }, [[5, 100, 200]])
    }
}
