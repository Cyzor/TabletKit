// SPDX-License-Identifier: GPL-3.0-or-later
//
// Xencelabs host→device control payload fixtures.
//
// Expected bytes are verbatim SetReport frames captured via dtrace from
// Xencelabs' own driver (XencelabsDriver, 2026-07-02) during dial-mode
// cycling, a structured palette/brightness sweep, and label syncs. The
// captured frames carry the puck's paired address at bytes 10–15; fixtures
// reproduce that via the `address` parameter. MockTab sends zeros there on
// the direct-USB path.
import XCTest
@testable import TabletKit

final class XencelabsControlTests: XCTestCase {

    /// The test puck's device address as captured ("Clicky").
    private let addr: [UInt8] = [0xAA, 0x67, 0x82, 0xB9, 0x35, 0xF4]

    private func hex(_ s: String) -> [UInt8] {
        s.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    // MARK: - Screen orientation

    func testUprightOrientationMatchesCapturedFrame() {
        // Captured (formerly misread as "reset labels"): 02 b1 01 00 ... <addr>
        XCTAssertEqual(
            XencelabsControl.orientationPayload(rotationSteps: 0, address: addr),
            hex("02 b1 01 00 00 00 00 00 00 00 aa 67 82 b9 35 f4"))
    }

    func testOrientationMapsStepsToWireBytesOneThroughFour() {
        // Hardware-confirmed 2026-07-10: bytes 1–4 rotate the OLED text in
        // 90° increments.
        for steps in 0..<4 {
            XCTAssertEqual(
                XencelabsControl.orientationPayload(rotationSteps: steps)[2],
                UInt8(steps + 1))
        }
    }

    // MARK: - Dial LED color

    func testDialColorMatchesCapturedOrangeFrame() {
        // Captured: 02 b4 01 01 00 00 aa 2b 00 00 <addr> (orange, Medium)
        XCTAssertEqual(
            XencelabsControl.dialColorPayload(r: 0xAA, g: 0x2B, b: 0x00, address: addr),
            hex("02 b4 01 01 00 00 aa 2b 00 00 aa 67 82 b9 35 f4"))
    }

    func testDialColorUnaddressedZeroFills() {
        XCTAssertEqual(
            XencelabsControl.dialColorPayload(r: 0x1C, g: 0x7D, b: 0x06),
            hex("02 b4 01 01 00 00 1c 7d 06 00 00 00 00 00 00 00"))
    }

    func testDefaultSlotColorsMatchVendorModePalette() {
        // Xencelabs Modus 1–4 factory colors: orange, red, yellow, green.
        let expected: [(UInt8, UInt8, UInt8)] = [
            (0xAA, 0x2B, 0x00), (0xA4, 0x07, 0x00),
            (0xAA, 0x64, 0x00), (0x1C, 0x7D, 0x06),
        ]
        XCTAssertEqual(XencelabsControl.defaultSlotColors.count, 4)
        for (i, e) in expected.enumerated() {
            XCTAssertEqual(XencelabsControl.defaultSlotColors[i].r, e.0)
            XCTAssertEqual(XencelabsControl.defaultSlotColors[i].g, e.1)
            XCTAssertEqual(XencelabsControl.defaultSlotColors[i].b, e.2)
        }
    }

    // MARK: - Dial sensitivity

    func testSensitivityMatchesCapturedDefaultFrame() {
        // Captured companion frame on every mode cycle: 02 b4 04 01 01 03 ...
        XCTAssertEqual(
            XencelabsControl.dialSensitivityPayload(3, address: addr),
            hex("02 b4 04 01 01 03 00 00 00 00 aa 67 82 b9 35 f4"))
    }

    // MARK: - OLED text

    func testShortModeNameMatchesCapturedZoomenFrame() {
        // Captured: 02 b1 06 01 00 0c 00 00 00 00 <addr> "Zoomen" UTF-16LE
        let frames = XencelabsControl.textPayloads(
            field: .modeName, text: "Zoomen", address: addr)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(
            frames[0],
            hex("02 b1 06 01 00 0c 00 00 00 00 aa 67 82 b9 35 f4")
                + hex("5a 00 6f 00 6f 00 6d 00 65 00 6e 00 00 00 00 00"))
    }

    func testChunkedKeyLabelMatchesCapturedRueckgaengigFrames() {
        // "Rückgängig machen" (17 UTF-16 units) captured as three key-1 frames
        // with chunks-remaining 02, 01, 00 and lengths 0x10, 0x10, 0x02.
        let frames = XencelabsControl.textPayloads(
            field: .keyLabel, index: 1, text: "Rückgängig machen", address: addr)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(
            frames[0],
            hex("02 b1 00 01 00 10 02 00 00 00 aa 67 82 b9 35 f4")
                + hex("52 00 fc 00 63 00 6b 00 67 00 e4 00 6e 00 67 00"))
        XCTAssertEqual(
            frames[1],
            hex("02 b1 00 01 00 10 01 00 00 00 aa 67 82 b9 35 f4")
                + hex("69 00 67 00 20 00 6d 00 61 00 63 00 68 00 65 00"))
        XCTAssertEqual(
            frames[2],
            hex("02 b1 00 01 00 02 00 00 00 00 aa 67 82 b9 35 f4")
                + hex("6e 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))
    }

    func testEmptyTextClearsField() {
        let frames = XencelabsControl.textPayloads(field: .keyLabel, index: 5, text: "")
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0][5], 0)   // zero chunk length
        XCTAssertEqual(frames[0][6], 0)   // final chunk
        XCTAssertEqual(frames[0][3], 5)   // key index preserved
        XCTAssertTrue(frames[0][16...].allSatisfy { $0 == 0 })
    }

    func testKeyLabelPayloadsCoverAllEightKeys() {
        let frames = XencelabsControl.keyLabelPayloads(["Undo", "Redo"])
        // 2 real labels (1 frame each, ≤8 units) + 6 clears.
        XCTAssertEqual(frames.count, 8)
        XCTAssertEqual(Array(frames.map { $0[3] }), [1, 2, 3, 4, 5, 6, 7, 8])
        // Frames all pad to the full 32-byte report.
        XCTAssertTrue(frames.allSatisfy { $0.count == 32 })
    }
}
