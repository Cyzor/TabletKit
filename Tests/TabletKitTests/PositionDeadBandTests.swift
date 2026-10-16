// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import TabletKit

final class PositionDeadBandTests: XCTestCase {

    private func run(_ band: inout PositionDeadBand, _ xs: [Int]) -> [Int] {
        xs.map { band.apply(x: $0, y: 500, maxX: 1000, maxY: 1000).x }
    }

    func testSmallMovesHoldTheOutput() {
        var band = PositionDeadBand(width: 10)
        XCTAssertEqual(run(&band, [500, 503, 497, 510, 490]), [500, 500, 500, 500, 500])
    }

    func testLargeMovesTrailByTheWidth() {
        var band = PositionDeadBand(width: 10)
        XCTAssertEqual(run(&band, [500, 520, 540, 545, 535]), [500, 510, 530, 535, 535])
        // Reversing costs twice the width before the output moves.
        XCTAssertEqual(run(&band, [526, 524, 515]), [535, 534, 525])
    }

    func testEdgesSnap() {
        var band = PositionDeadBand(width: 10)
        XCTAssertEqual(run(&band, [5, 0, 4, 1000, 995]), [5, 0, 0, 1000, 1000])
    }

    func testAxesAreIndependent() {
        var band = PositionDeadBand(width: 6)
        _ = band.apply(x: 100, y: 100, maxX: 1000, maxY: 1000)
        let out = band.apply(x: 120, y: 104, maxX: 1000, maxY: 1000)
        XCTAssertEqual(out.x, 114)
        XCTAssertEqual(out.y, 100)
    }

    func testZeroWidthAndResetPassThrough() {
        var band = PositionDeadBand()
        XCTAssertEqual(run(&band, [500, 501, 499]), [500, 501, 499])
        band.width = 10
        _ = run(&band, [500])
        band.reset()
        XCTAssertEqual(run(&band, [507]), [507])
    }
}
