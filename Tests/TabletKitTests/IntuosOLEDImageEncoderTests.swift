// SPDX-License-Identifier: MPL-2.0
//
// Intuos4 OLED packing, against hand-built images. Not hardware-verified.
import XCTest
@testable import TabletKit

final class IntuosOLEDImageEncoderTests: XCTestCase {

    private let w = IntuosOLEDImageEncoder.width
    private let h = IntuosOLEDImageEncoder.height

    func testInterleaveRowsRejectsWrongLength() {
        XCTAssertNil(IntuosOLEDImageEncoder.interleaveRows([UInt8](repeating: 0, count: 10)))
        XCTAssertNil(IntuosOLEDImageEncoder.interleaveRows([]))
    }

    func testInterleaveRowsProducesExpectedLength() {
        let grayscale = [UInt8](repeating: 0, count: w * h)
        let packed = IntuosOLEDImageEncoder.interleaveRows(grayscale)
        XCTAssertEqual(packed?.count, 1024, "64*32/2 = 1024 bytes for 4-bit-per-pixel packing")
    }

    private func pixel(_ g: [UInt8], row: Int, x: Int) -> UInt8 { g[row * w + x] }

    func testRowPairPacksUpperRowIntoLowNibble() {
        var g = [UInt8](repeating: 0, count: w * h)
        for x in 0..<w {
            g[0 * w + x] = 0xFF
            g[1 * w + x] = 0x80
        }
        let packed = IntuosOLEDImageEncoder.interleaveRows(g)!
        for i in 0..<w { XCTAssertEqual(packed[i], 0x8F, "byte \(i)") }
    }

    func testColumnsRunRightToLeft() {
        var g = [UInt8](repeating: 0, count: w * h)
        for x in 0..<w {
            g[0 * w + x] = UInt8(x * 4)
            g[1 * w + x] = UInt8(255 - x * 4)
        }
        let packed = IntuosOLEDImageEncoder.interleaveRows(g)!
        for i in 0..<w {
            let x = w - 1 - i
            XCTAssertEqual(packed[i], (pixel(g, row: 1, x: x) & 0xF0) | (pixel(g, row: 0, x: x) >> 4), "byte \(i)")
        }
    }

    func testRowPairsRunTopDown() {
        var g = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h { for x in 0..<w { g[row * w + x] = UInt8((row % 16) << 4) } }
        let packed = IntuosOLEDImageEncoder.interleaveRows(g)!
        for pair in 0..<(h / 2) {
            let expected = (pixel(g, row: 2 * pair + 1, x: w - 1) & 0xF0) | (pixel(g, row: 2 * pair, x: w - 1) >> 4)
            XCTAssertEqual(packed[pair * w], expected, "row pair \(pair)")
        }
    }

    func testRotated180IsTheRightHandedLayoutOfTheTurnedImage() {
        var g = [UInt8](repeating: 0, count: w * h)
        var rng: UInt64 = 7
        for i in g.indices {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            g[i] = UInt8(truncatingIfNeeded: rng >> 33)
        }
        let turned = Array(g.reversed())
        XCTAssertEqual(IntuosOLEDImageEncoder.interleaveRows(g, rotated180: true),
                       IntuosOLEDImageEncoder.interleaveRows(turned))
    }

    func testRenderTextLabelProducesCorrectBufferSize() {
        let buffer = IntuosOLEDImageEncoder.renderTextLabel("Ctrl")
        XCTAssertEqual(buffer.count, w * h)
    }

    func testRenderTextLabelEmptyStringIsBlank() {
        let buffer = IntuosOLEDImageEncoder.renderTextLabel("")
        XCTAssertEqual(buffer, [UInt8](repeating: 0, count: w * h))
    }

    func testRenderTextLabelNonEmptyStringProducesSomeNonZeroPixels() {
        let buffer = IntuosOLEDImageEncoder.renderTextLabel("A")
        XCTAssertTrue(buffer.contains { $0 > 0 }, "expected at least one lit pixel for a non-empty label")
    }

    func testFullPipelineTextToChunkedPayloadsRoundTripsWithoutCrashing() {
        // Label to bitmap to packed image to chunks; composition only.
        let bitmap = IntuosOLEDImageEncoder.renderTextLabel("Zoom")
        let packed = IntuosOLEDImageEncoder.interleaveRows(bitmap)
        XCTAssertNotNil(packed)
        let payloads = WacomOutputProtocol.keyImagePayloadsUSB(image: packed!, buttonID: 2)
        XCTAssertEqual(payloads.count, 4)
    }
}
