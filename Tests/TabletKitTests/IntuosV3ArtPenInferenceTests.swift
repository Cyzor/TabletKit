// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import TabletKit

/// The Bluetooth "twisted barrel means Art Pen" rule, moved from MockTab.
final class IntuosV3ArtPenInferenceTests: XCTestCase {

    private func pen(rotation: Double, inRange: Bool = true) -> DecodeResult {
        var point = TabletPoint(
            x: 100, y: 100, maxX: 1000, maxY: 1000, pressure: 0, maxPressure: 8191,
            tiltX: 0, tiltY: 0, penButton1: false, penButton2: false,
            eraser: false, inProximity: inRange, hoverDistance: 0)
        point.rotation = rotation
        return .pen(point)
    }

    private func infer(
        _ result: DecodeResult, currentTool: UInt16 = 0x0842, validRotation: Bool = true
    ) -> (results: [DecodeResult], state: IntuosV3Decoder.State) {
        var state = IntuosV3Decoder.State()
        state.currentToolCode = currentTool
        state.hasValidRotationFrame = validRotation
        var results = [result]
        IntuosV3Decoder.inferArtPenFromRotation(&results, state: &state)
        return (results, state)
    }

    private func announcedTool(_ results: [DecodeResult]) -> UInt16? {
        if case .toolEnter(let identity) = results.first { return identity.toolCode }
        return nil
    }

    func testTwistedBarrelAnnouncesAnArtPen() {
        let (results, state) = infer(pen(rotation: 90))
        XCTAssertEqual(announcedTool(results), 0x0804)
        XCTAssertEqual(results.count, 2, "the pen point stays, after the announcement")
        XCTAssertEqual(state.currentToolCode, 0x0804)
        XCTAssertEqual(state.lastToolCode, 0, "the announcement latch is left alone")
    }

    func testNeutralBarrelChangesNothing() {
        XCTAssertNil(announcedTool(infer(pen(rotation: 181)).results))
    }

    func testAPenWithoutARotationSensorIsNotAnArtPen() {
        // Rotation reads 0 until a valid frame, which is 180° off neutral.
        XCTAssertNil(announcedTool(infer(pen(rotation: 0), validRotation: false).results))
    }

    func testAnArtPenAlreadyAnnouncedIsLeftAlone() {
        XCTAssertNil(announcedTool(infer(pen(rotation: 90), currentTool: 0x0804).results))
        XCTAssertNil(announcedTool(infer(pen(rotation: 90), currentTool: 0x1108).results))
    }

    func testOutOfRangeChangesNothing() {
        XCTAssertNil(announcedTool(infer(pen(rotation: 90, inRange: false)).results))
    }

    func testReportsWithoutAPenChangeNothing() {
        XCTAssertNil(announcedTool(infer(.none).results))
    }
}
