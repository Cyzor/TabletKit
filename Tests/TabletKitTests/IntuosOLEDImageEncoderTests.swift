// SPDX-License-Identifier: MPL-2.0
//
// Intuos4 OLED packing, against hand-built images.
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

    // MARK: Layout

    /// Lit bounding box of a rendered bitmap, or nil when nothing is lit.
    private func inkBox(_ buffer: [UInt8]) -> (x0: Int, x1: Int, y0: Int, y1: Int)? {
        var x0 = w, x1 = -1, y0 = h, y1 = -1
        for row in 0..<h {
            for x in 0..<w where buffer[row * w + x] > 0 {
                x0 = min(x0, x); x1 = max(x1, x)
                y0 = min(y0, row); y1 = max(y1, row)
            }
        }
        return x1 < 0 ? nil : (x0, x1, y0, y1)
    }

    /// Dark rows inside the ink box; any means the label wrapped.
    private func blankRowsInside(_ buffer: [UInt8], _ box: (x0: Int, x1: Int, y0: Int, y1: Int)) -> [Int] {
        (box.y0...box.y1).filter { row in
            !buffer[(row * w)..<(row * w + w)].contains { $0 > 0 }
        }
    }

    /// "Toggle Display" used to clip to `gle Disp`.
    func testRenderTextLabelLongLabelWrapsInsteadOfClipping() {
        let buffer = IntuosOLEDImageEncoder.renderTextLabel("Toggle Display")
        guard let box = inkBox(buffer) else {
            return XCTFail("expected a long label to render something")
        }
        XCTAssertGreaterThan(box.x0, 0, "ink should keep a left margin, not run off the display")
        XCTAssertLessThan(box.x1, w - 1, "ink should keep a right margin, not run off the display")
        XCTAssertGreaterThan(box.y0, 0, "ink should keep a top margin")
        XCTAssertLessThan(box.y1, h - 1, "ink should keep a bottom margin")
        XCTAssertFalse(blankRowsInside(buffer, box).isEmpty,
                       "a label too wide for one line should wrap, leaving a blank row between lines")
    }

    func testRenderTextLabelShortLabelStaysOnOneLine() {
        let buffer = IntuosOLEDImageEncoder.renderTextLabel("Ctrl")
        guard let box = inkBox(buffer) else {
            return XCTFail("expected a short label to render something")
        }
        XCTAssertTrue(blankRowsInside(buffer, box).isEmpty,
                      "a label that fits should stay on a single line")
    }

    /// A word that fits on one line shrinks rather than splitting mid-word.
    func testRenderTextLabelSingleWordShrinksRatherThanSplits() {
        let buffer = IntuosOLEDImageEncoder.renderTextLabel("Fullscreen")
        guard let box = inkBox(buffer) else {
            return XCTFail("expected a label to render")
        }
        XCTAssertTrue(blankRowsInside(buffer, box).isEmpty,
                      "a single word that fits should stay on one line")
    }

    func testRenderTextLabelKeepsMarginsOnEveryEdge() {
        for label in ["Toggle Display", "Ctrl+Alt+Delete", "X", "P"] {
            guard let box = inkBox(IntuosOLEDImageEncoder.renderTextLabel(label)) else {
                XCTFail("\(label) should render"); continue
            }
            XCTAssertTrue(box.x0 > 0 && box.x1 < w - 1, "\(label) should keep side margins")
            XCTAssertTrue(box.y0 > 0 && box.y1 < h - 1, "\(label) should keep top and bottom margins")
        }
    }

    /// Width of each line's ink, split at the blank row.
    private func lineBandWidths(_ buffer: [UInt8], _ box: (x0: Int, x1: Int, y0: Int, y1: Int)) -> [Int]? {
        guard let blank = blankRowsInside(buffer, box).first else { return nil }
        func width(of rows: Range<Int>) -> Int {
            var x0 = w, x1 = -1
            for row in rows {
                for x in 0..<w where buffer[row * w + x] > 0 {
                    x0 = min(x0, x); x1 = max(x1, x)
                }
            }
            return x1 < 0 ? 0 : x1 - x0 + 1
        }
        return [width(of: box.y0..<blank), width(of: (blank + 1)..<(box.y1 + 1))]
    }

    /// The first word goes on the upper line.
    func testRenderTextLabelFirstLineDrawsOnTop() {
        for label in ["A LongerWord", "LongerWord A"] {
            let buffer = IntuosOLEDImageEncoder.renderTextLabel(label)
            guard let box = inkBox(buffer), let widths = lineBandWidths(buffer, box) else {
                return XCTFail("\(label) should render on two lines")
            }
            let narrowIsOnTop: Bool
            if label == "A LongerWord" {
                narrowIsOnTop = widths[0] < widths[1]
            } else {
                narrowIsOnTop = widths[0] > widths[1]
            }
            XCTAssertTrue(narrowIsOnTop,
                          "\(label): upper line width \(widths[0]), lower \(widths[1]) — the first word should be on top")
        }
    }

    /// Each line is centered on its own, not left-aligned.
    func testRenderTextLabelCentersEachLineIndependently() {
        let buffer = IntuosOLEDImageEncoder.renderTextLabel("A LongerWord")
        guard let box = inkBox(buffer) else {
            return XCTFail("expected a label to render")
        }
        let blank = blankRowsInside(buffer, box).first
        guard let blank else { return XCTFail("expected two lines") }

        func horizontalCenter(_ rows: Range<Int>) -> (CGFloat, Int) {
            var x0 = w, x1 = -1
            for row in rows {
                for x in 0..<w where buffer[row * w + x] > 0 {
                    x0 = min(x0, x); x1 = max(x1, x)
                }
            }
            return (CGFloat(x0 + x1) / 2, x1 - x0 + 1)
        }
        let (topCenter, _) = horizontalCenter(box.y0..<blank)
        let (bottomCenter, _) = horizontalCenter((blank + 1)..<(box.y1 + 1))

        // Slack for side bearings, well short of a word's width.
        XCTAssertLessThanOrEqual(abs(topCenter - bottomCenter), 4,
                                 "each line should be centered, not left-aligned")
    }
}
