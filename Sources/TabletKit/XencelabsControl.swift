// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Payload builders for the Xencelabs host→device control protocol
/// (Quick Keys OLED text, dial LED color, dial sensitivity).
///
/// Decoded 2026-07-02 from dtrace captures of Xencelabs' own driver
/// (`XencelabsDriver`) during pairing, dial-mode cycling, and a structured
/// palette/brightness sweep. All writes are output reports with report
/// ID 0x02 (the same vendor tunnel the input protocol uses), padded by the
/// sender to the device's MaxOutputReportSize.
///
/// The device is never told what a key or the dial *does* — bindings are
/// interpreted host-side from input events. These writes only affect what
/// the hardware displays: OLED text fields and the dial's LED ring.
///
/// Bytes 10–15 of each payload carry a 6-byte device address. Xencelabs'
/// driver fills in the target peripheral's address (needed to route through
/// the wireless dongle, which serves up to two paired devices). Over direct
/// USB the addressed form was captured working, but zeros are used here
/// until the dongle-relay path is implemented — direct-USB firmware accepts
/// the frames either way per the captures (address echoes appear in both
/// addressed and unaddressed traffic). If a dongle path lands later, thread
/// the paired address through `address`.
public enum XencelabsControl {

    /// OLED text field selectors (payload byte 2 of an 0xB1 write).
    public enum TextField: UInt8 {
        /// Per-key label region; the key number (1–8) goes in the index field.
        case keyLabel = 0x00
        /// Profile-name line at the top of the OLED.
        case profileName = 0x05
        /// Dial-mode / status line.
        case modeName = 0x06
    }

    /// Xencelabs' factory dial-mode palette at Medium brightness, indexed by
    /// mode slot 0–3 (orange, red, yellow, green — the colors their software
    /// assigns to Modus 1–4 by default). Values are LED-calibrated RGB as
    /// captured from the vendor driver, not sRGB.
    public static let defaultSlotColors: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (0xAA, 0x2B, 0x00),  // orange
        (0xA4, 0x07, 0x00),  // red
        (0xAA, 0x64, 0x00),  // yellow
        (0x1C, 0x7D, 0x06),  // green
    ]

    /// Screen orientation write: `02 B1 <steps+1> 00 ... <addr>`.
    ///
    /// Rotates the Quick Keys OLED text in 90° steps (0 = upright,
    /// 1 = 90°, 2 = 180°, 3 = 270° — the wire byte is steps + 1). The
    /// vendor agent builds this frame in `SetRemoteDirection` and replays
    /// the saved orientation during its reconnect init, which is what
    /// earlier captures showed as a fixed `b1 01` ("upright") write.
    /// Confirmed on hardware 2026-07-10: varying the byte visibly rotates
    /// the display.
    public static func orientationPayload(
        rotationSteps: Int, address: [UInt8] = []
    ) -> [UInt8] {
        var p: [UInt8] = [0x02, 0xB1, UInt8((rotationSteps & 0x03) + 1),
                          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        p += paddedAddress(address)
        return p
    }

    /// Dial LED color write: `02 B4 01 01 00 00 R G B 00 <addr>`.
    /// Brightness is pre-scaled into the RGB values by the host (the vendor
    /// driver sends e.g. red at 0x52/0xA4/0xF7 peak for Dim/Medium/Hell).
    public static func dialColorPayload(
        r: UInt8, g: UInt8, b: UInt8, address: [UInt8] = []
    ) -> [UInt8] {
        var p: [UInt8] = [0x02, 0xB4, 0x01, 0x01, 0x00, 0x00, r, g, b, 0x00]
        p += paddedAddress(address)
        return p
    }

    /// Dial sensitivity write: `02 B4 04 01 01 <n> ... <addr>`.
    /// Observed n = 1...5; the vendor default is 3.
    public static func dialSensitivityPayload(
        _ sensitivity: UInt8, address: [UInt8] = []
    ) -> [UInt8] {
        var p: [UInt8] = [0x02, 0xB4, 0x04, 0x01, 0x01, sensitivity,
                          0x00, 0x00, 0x00, 0x00]
        p += paddedAddress(address)
        return p
    }

    /// OLED text write(s): `02 B1 <field> <idx u16 LE> <chunkLen> <remaining>
    /// 00 00 00 <addr> <UTF-16LE text, 16 bytes>`.
    ///
    /// Text longer than 8 UTF-16 code units is split into 8-unit chunks;
    /// each frame's byte 5 is the chunk's length in *bytes* and byte 6 counts
    /// the chunks remaining after it (…2, 1, 0). An empty string produces a
    /// single zero-length frame, which clears the field.
    public static func textPayloads(
        field: TextField, index: Int = 1, text: String, address: [UInt8] = []
    ) -> [[UInt8]] {
        let units = Array(text.utf16)
        // Chunk into groups of 8 UTF-16 code units (16 bytes of text area).
        var chunks: [[UInt16]] = stride(from: 0, to: max(units.count, 1), by: 8).map {
            Array(units[$0..<min($0 + 8, units.count)])
        }
        if chunks.isEmpty { chunks = [[]] }

        return chunks.enumerated().map { (i, chunk) in
            var p: [UInt8] = [
                0x02, 0xB1, field.rawValue,
                UInt8(index & 0xFF), UInt8((index >> 8) & 0xFF),
                UInt8(chunk.count * 2),
                UInt8(chunks.count - 1 - i),
                0x00, 0x00, 0x00,
            ]
            p += paddedAddress(address)
            for unit in chunk {
                p.append(UInt8(unit & 0xFF))
                p.append(UInt8(unit >> 8))
            }
            while p.count < 32 { p.append(0x00) }
            return p
        }
    }

    /// Payload sequence to sync all eight key labels (labels[0] = key 1,
    /// the top-left key in landscape orientation). Missing entries clear
    /// their key's label; extras beyond 8 are ignored.
    public static func keyLabelPayloads(
        _ labels: [String], address: [UInt8] = []
    ) -> [[UInt8]] {
        (0..<8).flatMap { i in
            textPayloads(
                field: .keyLabel, index: i + 1,
                text: i < labels.count ? labels[i] : "",
                address: address)
        }
    }

    private static func paddedAddress(_ address: [UInt8]) -> [UInt8] {
        var a = Array(address.prefix(6))
        while a.count < 6 { a.append(0x00) }
        return a
    }
}
