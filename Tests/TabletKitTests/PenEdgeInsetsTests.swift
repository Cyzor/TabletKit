// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 TabletKit contributors
// SPDX-License-Identifier: MPL-2.0
//
// Pen displays whose descriptors fix the margins beyond the screen.
import XCTest
@testable import TabletKit

final class PenEdgeInsetsTests: XCTestCase {

    private func point(x: Int, y: Int, maxX: Int, maxY: Int) -> TabletPoint {
        TabletPoint(x: x, y: y, maxX: maxX, maxY: maxY, pressure: 0, maxPressure: 8191,
                    tiltX: 0, tiltY: 0, penButton1: false, penButton2: false, eraser: false,
                    inProximity: true, hoverDistance: 0)
    }

    func testOnlyModelsWithFixedMarginsGetThem() throws {
        for pid in [0x0350, 0x034D] {
            XCTAssertEqual(try XCTUnwrap(WacomDeviceRegistry.spec(for: pid)).digitizerSpec.penEdgeInsets,
                           PenEdgeInsets(left: 400, top: 400, right: 400, bottom: 400), "0x\(String(pid, radix: 16))")
        }
        // No descriptor for these yet.
        for pid in [0x034E, 0x034F, 0x0398] {
            XCTAssertNil(try XCTUnwrap(WacomDeviceRegistry.spec(for: pid)).digitizerSpec.penEdgeInsets)
        }
    }

    func testTrimMapsScreenEdgesToTheRange() {
        let insets = PenEdgeInsets(left: 400, top: 400, right: 400, bottom: 400)
        let corner = insets.trim(point(x: 400, y: 400, maxX: 69920, maxY: 39680))
        XCTAssertEqual([corner.x, corner.y, corner.maxX, corner.maxY], [0, 0, 69120, 38880])
        let far = insets.trim(point(x: 69520, y: 39280, maxX: 69920, maxY: 39680))
        XCTAssertEqual([far.x, far.y], [69120, 38880])
    }

    func testPointsInAMarginLandOnTheEdge() {
        let insets = PenEdgeInsets(left: 400, top: 400, right: 400, bottom: 400)
        let low = insets.trim(point(x: 10, y: 0, maxX: 69920, maxY: 39680))
        XCTAssertEqual([low.x, low.y], [0, 0])
        let high = insets.trim(point(x: 69920, y: 39680, maxX: 69920, maxY: 39680))
        XCTAssertEqual([high.x, high.y], [69120, 38880])
    }
}
