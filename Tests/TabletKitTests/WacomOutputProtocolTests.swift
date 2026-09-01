// SPDX-License-Identifier: GPL-3.0-or-later
//
// Wacom Intuos4 OLED image protocol fixtures.
//
// UNLIKE XencelabsOutputProtocolTests, these are NOT captured frames — no
// Intuos4 has been available to capture against. Expected bytes here are
// derived directly from the Linux kernel's wacom_led_putimage
// (drivers/hid/wacom_sys.c) and its WAC_CMD_ICON_* constants
// (drivers/hid/wacom_wac.h), which is the authoritative source these
// builders were written from. These tests pin the encoder's OWN internal
// consistency and the kernel-cited byte layout, not agreement with a real
// device. Re-verify against a live capture before trusting on hardware.
import XCTest
@testable import TabletKit

final class WacomOutputProtocolTests: XCTestCase {

    // MARK: - Start / stop

    func testImageStartPayload() {
        XCTAssertEqual(WacomOutputProtocol.imageStartPayload(), [0x21, 0x01])
    }

    func testImageStopPayload() {
        XCTAssertEqual(WacomOutputProtocol.imageStopPayload(), [0x21, 0x00])
    }

    // MARK: - Chunked image transfer

    func testKeyImagePayloadsUSBProducesFourChunksOfCorrectSize() {
        let image = (0..<1024).map { UInt8($0 & 0xFF) }
        let payloads = WacomOutputProtocol.keyImagePayloadsUSB(image: image, buttonID: 3)

        XCTAssertEqual(payloads.count, 4, "kernel splits the 1024-byte image into 4 chunks")
        for payload in payloads {
            // 3 header bytes (xfer_id, button, chunk index) + 256 bytes of image data.
            XCTAssertEqual(payload.count, 259)
        }
    }

    func testKeyImagePayloadsUSBHeaderBytes() {
        let image = [UInt8](repeating: 0xAB, count: 1024)
        let payloads = WacomOutputProtocol.keyImagePayloadsUSB(image: image, buttonID: 5)

        for (index, payload) in payloads.enumerated() {
            XCTAssertEqual(payload[0], 0x23, "WAC_CMD_ICON_XFER (USB)")
            XCTAssertEqual(payload[1], 5, "button_id & 0x07")
            XCTAssertEqual(payload[2], UInt8(index), "chunk index 0...3")
        }
    }

    func testKeyImagePayloadsUSBButtonIDIsMaskedTo3Bits() {
        // Kernel: `buf[1] = button_id & 0x07`.
        let image = [UInt8](repeating: 0, count: 1024)
        let payloads = WacomOutputProtocol.keyImagePayloadsUSB(image: image, buttonID: 0x0F)
        XCTAssertEqual(payloads.first?[1], 0x07)
    }

    func testKeyImagePayloadsUSBChunksReassembleToOriginalImage() {
        let image = (0..<1024).map { UInt8($0 % 256) }
        let payloads = WacomOutputProtocol.keyImagePayloadsUSB(image: image, buttonID: 0)

        var reassembled: [UInt8] = []
        for payload in payloads {
            reassembled += payload[3...]
        }
        XCTAssertEqual(reassembled, image)
    }

    func testKeyImagePayloadsUSBRejectsWrongLength() {
        XCTAssertTrue(WacomOutputProtocol.keyImagePayloadsUSB(image: [UInt8](repeating: 0, count: 100), buttonID: 0).isEmpty)
        XCTAssertTrue(WacomOutputProtocol.keyImagePayloadsUSB(image: [], buttonID: 0).isEmpty)
    }
}
