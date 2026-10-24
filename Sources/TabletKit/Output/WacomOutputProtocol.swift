// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Payload builders for the Wacom Intuos4 host→device OLED image protocol.
///
/// Sourced from the Linux kernel (`drivers/hid/wacom_sys.c`,
/// `wacom_led_putimage` and its `WAC_CMD_ICON_*` constants in
/// `wacom_wac.h`) and the kernel's own sysfs ABI documentation (quoted in
/// `sanette/intuos4-oled`'s `intuos4oled.py`, an independent third-party
/// tool built against that same documented interface).
///
/// The USB framing is confirmed on a PTK-640.
///
/// Intuos4-exclusive: `TabletSpec.hasKeyOLEDs` gates this. The kernel
/// applies it to every Intuos4, but the PTK-440 has no key displays.
/// Intuos5 and Intuos Pro share the same `.intuosV1` wire *decoder* but have
/// no per-key OLED hardware at all.
///
/// Unlike `XencelabsOutputProtocol`, these are HID **feature** reports, not
/// output reports — sent via `IOHIDDeviceSetReport` with
/// `kIOHIDReportTypeFeature` (`hidSetReport`'s default type).
public enum WacomOutputProtocol: Sendable {

    /// Intuos4 OLED image transfer commands (`wacom_wac.h`).
    public enum ImageCommand {
        /// `WAC_CMD_ICON_START` — brackets a transfer (byte 1 = 1 to start,
        /// 0 to stop). Same command value for both start and stop frames;
        /// only the second byte differs.
        public static let iconStart: UInt8 = 0x21
        /// `WAC_CMD_ICON_XFER` — chunk-transfer command over USB.
        public static let iconXferUSB: UInt8 = 0x23
        /// `WAC_CMD_ICON_BT_XFER` — chunk-transfer command over Bluetooth.
        /// Not currently used: `keyImagePayloadsUSB` only implements the USB
        /// image encoding (4-bit grayscale). Bluetooth uses a different
        /// encoding (1-bit monochrome plus a bit-scramble) not implemented
        /// here — see `keyImagePayloadsUSB`'s doc for detail.
        public static let iconXferBT: UInt8 = 0x26
    }

    /// The "begin an OLED image transfer" feature report: `21 01`.
    /// Must precede the chunk payloads from `keyImagePayloadsUSB`.
    public static func imageStartPayload() -> [UInt8] {
        [ImageCommand.iconStart, 0x01]
    }

    /// The "end an OLED image transfer" feature report: `21 00`.
    /// Must follow the chunk payloads from `keyImagePayloadsUSB`.
    public static func imageStopPayload() -> [UInt8] {
        [ImageCommand.iconStart, 0x00]
    }

    /// Chunked feature-report payloads for one key's OLED image, USB
    /// transport only.
    ///
    /// Wire format per the kernel's `wacom_led_putimage` (`wacom_sys.c`):
    /// the 1024-byte USB image is split into 4 chunks of 256 bytes, each
    /// sent as its own feature report `[0x23, buttonID & 0x07, chunkIndex,
    /// <256 bytes>]`. `image` must already be in the device's expected
    /// **4-bit grayscale, row-interleaved** byte order — see
    /// `IntuosOLEDImageEncoder` for producing that from a bitmap. This
    /// function does no image processing, only chunking; a wrongly-encoded
    /// `image` will chunk without error and simply display garbled.
    ///
    /// Full transfer sequence for one key: `imageStartPayload()`, then all
    /// four payloads from this function in order, then `imageStopPayload()`.
    ///
    /// - Parameters:
    ///   - image: exactly 1024 bytes, USB 4-bit-grayscale row-interleaved
    ///     format. Any other length returns an empty array rather than
    ///     sending malformed chunks.
    ///   - buttonID: 0–7, the target key index.
    public static func keyImagePayloadsUSB(image: [UInt8], buttonID: Int) -> [[UInt8]] {
        let expectedLength = 1024
        guard image.count == expectedLength else { return [] }
        let chunkLength = expectedLength / 4  // 256 bytes/chunk, per wacom_led_putimage

        return (0..<4).map { chunkIndex in
            var payload: [UInt8] = [
                ImageCommand.iconXferUSB,
                UInt8(buttonID & 0x07),
                UInt8(chunkIndex),
            ]
            let start = chunkIndex * chunkLength
            payload += image[start..<(start + chunkLength)]
            return payload
        }
    }
}
