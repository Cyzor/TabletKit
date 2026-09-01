// SPDX-License-Identifier: GPL-3.0-or-later
//
// Intuos4 OLED bitmap-encoding fixtures.
//
// Not hardware-verified — see WacomOutputProtocolTests's header for why.
// These tests pin the row-interleaving arithmetic against the kernel doc's
// stated rule ("low nibble = first line, high nibble = second line") using
// hand-constructed inputs, since no captured reference image exists.
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

    func testInterleaveRowsPacksRowPairIntoLowHighNibbles() {
        // All-black image except row 0 is full white (0xF0, top 4 bits used)
        // and row 1 is mid-gray (0x80). Per the kernel doc, byte 0 of the
        // packed output should carry row 0 in its LOW nibble and row 1 in
        // its HIGH nibble — i.e. low = 0xF, high = 0x8 -> byte = 0x8F.
        var grayscale = [UInt8](repeating: 0, count: w * h)
        for x in 0..<w {
            grayscale[0 * w + x] = 0xFF  // row 0: white
            grayscale[1 * w + x] = 0x80  // row 1: mid-gray
        }
        let packed = IntuosOLEDImageEncoder.interleaveRows(grayscale)!

        for x in 0..<w {
            let low = 0xFF >> 4       // 0xF
            let high = UInt8(0x80) & 0xF0  // 0x80
            XCTAssertEqual(packed[x], UInt8(high | UInt8(low)), "column \(x) of first row-pair chunk")
        }
    }

    func testInterleaveRowsDoesNotMixColumnsWithinARowPair() {
        // Distinct per-column values in row 0 and row 1 must stay aligned to
        // their own column in the packed output, not smear across columns.
        var grayscale = [UInt8](repeating: 0, count: w * h)
        for x in 0..<w {
            grayscale[0 * w + x] = UInt8(x * 4)       // row 0: ramp
            grayscale[1 * w + x] = UInt8(255 - x * 4) // row 1: inverse ramp
        }
        let packed = IntuosOLEDImageEncoder.interleaveRows(grayscale)!

        for x in 0..<w {
            let low = grayscale[0 * w + x] >> 4
            let high = grayscale[1 * w + x] & 0xF0
            XCTAssertEqual(packed[x], high | low, "column \(x)")
        }
    }

    func testInterleaveRowsCoversAllRowPairs() {
        // Each of the 16 row-pairs (32 rows / 2) should land in its own
        // 64-byte chunk of the packed output, in row-pair order.
        var grayscale = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            // Encode the row index itself as the pixel value (capped to 4
            // bits' worth of distinguishable values via the low/high split).
            for x in 0..<w {
                grayscale[row * w + x] = UInt8((row % 16) << 4)
            }
        }
        let packed = IntuosOLEDImageEncoder.interleaveRows(grayscale)!

        for rowPair in 0..<(h / 2) {
            let chunkStart = rowPair * w
            // Derive the expectation from the SAME source values the
            // grayscale buffer was populated with, applying the encoder's
            // own documented rule (low nibble = row 2n, high nibble = row
            // 2n+1) — rather than re-deriving the row value a second way,
            // which is exactly the kind of double-transform that produced
            // a wrong expectation here on the first pass of this test.
            let sourceLowRow = grayscale[(rowPair * 2) * w]
            let sourceHighRow = grayscale[(rowPair * 2 + 1) * w]
            let expected = (sourceHighRow & 0xF0) | (sourceLowRow >> 4)
            XCTAssertEqual(packed[chunkStart], expected, "row-pair \(rowPair)")
        }
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
        // Weak assertion by design — this only proves the renderer draws
        // *something*, not that it looks right. No reference image exists
        // to compare against without hardware to view the result on.
        let buffer = IntuosOLEDImageEncoder.renderTextLabel("A")
        XCTAssertTrue(buffer.contains { $0 > 0 }, "expected at least one lit pixel for a non-empty label")
    }

    func testFullPipelineTextToChunkedPayloadsRoundTripsWithoutCrashing() {
        // End-to-end smoke test of the phase-1 flow: label -> bitmap ->
        // interleave -> chunk. Confirms the pieces compose; says nothing
        // about correctness of the final image without hardware to view it.
        let bitmap = IntuosOLEDImageEncoder.renderTextLabel("Zoom")
        let packed = IntuosOLEDImageEncoder.interleaveRows(bitmap)
        XCTAssertNotNil(packed)
        let payloads = WacomOutputProtocol.keyImagePayloadsUSB(image: packed!, buttonID: 2)
        XCTAssertEqual(payloads.count, 4)
    }
}
