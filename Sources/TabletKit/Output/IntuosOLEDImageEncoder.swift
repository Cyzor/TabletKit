// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import CoreGraphics
import CoreText

/// Encodes bitmap data for the Wacom Intuos4's per-key OLED, USB transport.
///
/// **Not hardware-verified.** Encoding rules sourced from the Linux
/// kernel's sysfs ABI documentation (quoted in `sanette/intuos4-oled`'s
/// `intuos4oled.py`, which independently implements the same documented
/// format): 64×32 pixels, 4-bit grayscale, packed 1024 bytes total. Only
/// the USB encoding is implemented — Bluetooth additionally bit-scrambles
/// the packed bytes (`76543210`→`GECA6420`) on top of a different (1-bit)
/// bit depth, which this encoder does not produce. See
/// `Notes/Scratch/intuos4-oled-image-design.md` for the full protocol
/// writeup this was built from.
public enum IntuosOLEDImageEncoder {

    public static let width = 64
    public static let height = 32

    /// Row-interleaves a 64×32 8-bit grayscale buffer into the Intuos4's
    /// USB wire format: 1024 bytes, where each byte packs two vertically
    /// adjacent pixels from the SAME column — low nibble from row `2n`, high
    /// nibble from row `2n+1` — not two horizontally adjacent pixels. This
    /// matches the kernel doc's "each 64-byte chunk encodes two consecutive
    /// lines... low nibble contains the first line, high nibble the second."
    ///
    /// - Parameter grayscale: exactly `width * height` (2048) bytes, one
    ///   8-bit grayscale sample per pixel in row-major order (row 0 first).
    ///   Only the top 4 bits of each sample are used — callers should
    ///   already have quantized to 4-bit depth, or accept the precision
    ///   loss from truncation here.
    /// - Returns: 1024 bytes in Intuos4 USB wire order, or `nil` if
    ///   `grayscale.count != width * height`.
    public static func interleaveRows(_ grayscale: [UInt8]) -> [UInt8]? {
        guard grayscale.count == width * height else { return nil }

        var packed = [UInt8](repeating: 0, count: width * height / 2)
        var pos = 0
        for rowPair in stride(from: 0, to: height, by: 2) {
            for x in 0..<width {
                let low = grayscale[rowPair * width + x] >> 4
                let high = grayscale[(rowPair + 1) * width + x] & 0xF0
                packed[pos] = high | low
                pos += 1
            }
        }
        return packed
    }

    /// Renders a short text label to a 64×32 8-bit grayscale buffer
    /// (white text on black, matching the OLED's own look), suitable for
    /// passing to `interleaveRows`.
    ///
    /// This is phase 1 of the design plan — reusing existing per-key label
    /// text (`WacomKnownDevice.setAuxKeyLabels`'s existing input) rather
    /// than requiring a new image-import UI. Text is centered, single line,
    /// clipped rather than wrapped or scaled to fit — a key OLED is 64×32
    /// pixels, there is no room for real typography here.
    public static func renderTextLabel(_ text: String) -> [UInt8] {
        guard !text.isEmpty else {
            return [UInt8](repeating: 0, count: width * height)
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return [UInt8](repeating: 0, count: width * height)
        }

        // Black background — the OLED's own off-pixel color.
        context.setFillColor(gray: 0.0, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 1.0, alpha: 1.0),
        ]
        let attributedString = CFAttributedStringCreate(
            nil, text as CFString, attributes as CFDictionary)
        let line = CTLineCreateWithAttributedString(attributedString!)
        let lineBounds = CTLineGetBoundsWithOptions(line, [])

        // CGContext's origin is bottom-left; center the text both axes.
        let x = (CGFloat(width) - lineBounds.width) / 2 - lineBounds.origin.x
        let y = (CGFloat(height) - lineBounds.height) / 2 - lineBounds.origin.y
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)

        guard let data = context.data else {
            return [UInt8](repeating: 0, count: width * height)
        }
        return Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: width * height))
    }
}
