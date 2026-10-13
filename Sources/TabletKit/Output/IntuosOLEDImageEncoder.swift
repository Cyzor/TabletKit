// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import CoreGraphics
import CoreText

/// Encodes images for the Intuos4's per-key OLEDs over USB: 64×32 pixels,
/// 4-bit grayscale, 1024 bytes per key. Bluetooth uses a different, 1-bit
/// format that this doesn't produce.
///
/// Not hardware-verified. The layout follows the kernel's sysfs ABI doc; the
/// column order and the left-handed rotation follow the public Intuos4 OLED
/// tools.
public enum IntuosOLEDImageEncoder: Sendable {

    /// OLED width in pixels.
    public static let width = 64
    /// OLED height in pixels.
    public static let height = 32

    /// Packs a 64×32 8-bit grayscale image into the USB wire format.
    ///
    /// Each byte holds two vertically adjacent pixels of one column: the low
    /// nibble from the upper row, the high nibble from the one below. Columns
    /// go right to left. With `rotated180`, for a tablet turned around for
    /// left-handed use, rows go bottom up and columns left to right.
    ///
    /// - Parameters:
    ///   - grayscale: `width * height` samples, row-major, top row first.
    ///     Only the top 4 bits of each are used.
    ///   - rotated180: Whether to turn the image for upside-down use.
    /// - Returns: 1024 bytes, or `nil` if `grayscale` is the wrong size.
    public static func interleaveRows(_ grayscale: [UInt8], rotated180: Bool) -> [UInt8]? {
        guard grayscale.count == width * height else { return nil }

        var packed = [UInt8](repeating: 0, count: width * height / 2)
        var pos = 0
        for pair in 0..<(height / 2) {
            let (lowRow, highRow) = rotated180
                ? (height - 1 - 2 * pair, height - 2 - 2 * pair)
                : (2 * pair, 2 * pair + 1)
            for i in 0..<width {
                let x = rotated180 ? i : width - 1 - i
                let low = grayscale[lowRow * width + x] >> 4
                let high = grayscale[highRow * width + x] & 0xF0
                packed[pos] = high | low
                pos += 1
            }
        }
        return packed
    }

    /// ``interleaveRows(_:rotated180:)`` for the right-handed layout.
    public static func interleaveRows(_ grayscale: [UInt8]) -> [UInt8]? {
        interleaveRows(grayscale, rotated180: false)
    }

    /// Renders a short label as white-on-black 64×32 grayscale for
    /// `interleaveRows`: one centered line, clipped rather than wrapped.
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
