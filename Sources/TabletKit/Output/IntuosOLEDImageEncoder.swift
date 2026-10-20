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

    /// The largest size tried; a short label renders at it on one line.
    private static let maxFontSize: CGFloat = 18
    /// Below this the render stops shrinking and clips.
    private static let minFontSize: CGFloat = 6
    /// Blank rows between wrapped lines. Antialiasing fills one, so a single
    /// row runs the lines together.
    private static let lineGap: CGFloat = 2
    /// Dark rows and columns kept clear at each edge.
    private static let margin: CGFloat = 1

    /// Renders a label as white-on-black 64×32 grayscale for
    /// `interleaveRows`, centered and sized to fit. A label wraps onto two
    /// lines when that reads larger than one line; "Toggle Display" is about
    /// 130 px wide at 18 pt.
    public static func renderTextLabel(_ text: String) -> [UInt8] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [UInt8](repeating: 0, count: width * height)
        }

        // A tie stays on one line. A word is cut in half only when it can't
        // fit on one line at any size.
        let single = fittedSize(for: [trimmed])
        let split = splitAtSeparator(trimmed) ?? (single == nil ? splitInHalf(trimmed) : nil)
        let both = split.flatMap { fittedSize(for: $0) }
        let lines: [String], size: CGFloat
        if let single, single >= (both ?? 0) {
            (lines, size) = ([trimmed], single)
        } else if let split, let both {
            (lines, size) = (split, both)
        } else {
            (lines, size) = ([trimmed], single ?? minFontSize)
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

        draw(lines, at: size, in: context)

        guard let data = context.data else {
            return [UInt8](repeating: 0, count: width * height)
        }
        let bitmap = Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: width * height))
        return centeredByInk(bitmap)
    }

    private static func makeLine(_ text: String, size: CGFloat) -> CTLine? {
        guard !text.isEmpty else { return nil }
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 1.0, alpha: 1.0),
        ]
        guard let attributed = CFAttributedStringCreate(
            nil, text as CFString, attributes as CFDictionary)
        else { return nil }
        return CTLineCreateWithAttributedString(attributed)
    }

    /// One line's bounds at `size`, with the baseline at 0.
    private static func bounds(of text: String, size: CGFloat) -> CGRect {
        guard let line = makeLine(text, size: size) else { return .zero }
        return CTLineGetBoundsWithOptions(line, [])
    }

    /// Ascent plus descent. The 1.2 em line box would cost a couple of font
    /// sizes on a 32 px display.
    private static func lineHeight(at size: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return CTFontGetAscent(font) + CTFontGetDescent(font)
    }

    /// The largest size at which `lines` fit inside the margins, or nil.
    private static func fittedSize(for lines: [String]) -> CGFloat? {
        guard !lines.isEmpty else { return nil }
        let availWidth = CGFloat(width) - margin * 2
        let availHeight = CGFloat(height) - margin * 2
        for size in stride(from: maxFontSize, through: minFontSize, by: -1) {
            let widest = lines.map { bounds(of: $0, size: size).width }.max() ?? 0
            let blockHeight = lineHeight(at: size) * CGFloat(lines.count)
                + lineGap * CGFloat(lines.count - 1)
            if widest <= availWidth, blockHeight <= availHeight {
                return size
            }
        }
        return nil
    }

    /// Two lines split at the separator (space, `+`, `/`, …) that best evens
    /// their widths, or nil when the label has none.
    private static func splitAtSeparator(_ text: String) -> [String]? {
        let separators: Set<Character> = [" ", "+", "/", "|", "&", "-", "_", "·"]
        let chars = Array(text)
        var best: (lines: [String], width: CGFloat)?
        for i in 1..<chars.count where separators.contains(chars[i - 1]) {
            let first = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
            let second = String(chars[i...]).trimmingCharacters(in: .whitespaces)
            guard !first.isEmpty, !second.isEmpty else { continue }
            let width = max(bounds(of: first, size: maxFontSize).width,
                            bounds(of: second, size: maxFontSize).width)
            if width < best?.width ?? .greatestFiniteMagnitude {
                best = ([first, second], width)
            }
        }
        return best?.lines
    }

    private static func splitInHalf(_ text: String) -> [String]? {
        let chars = Array(text)
        guard chars.count > 1 else { return nil }
        let mid = chars.count / 2
        return [String(chars[0..<mid]), String(chars[mid...])]
    }

    /// Draws `lines` top down, each centered on its own. `centeredByInk`
    /// settles the final placement.
    private static func draw(_ lines: [String], at size: CGFloat, in context: CGContext) {
        let lineHeight = lineHeight(at: size)
        // CGContext's origin is bottom left.
        var baseline = CGFloat(height) - margin - lineHeight
        for text in lines {
            guard let line = makeLine(text, size: size) else { continue }
            let box = CTLineGetBoundsWithOptions(line, [])
            context.textPosition = CGPoint(
                x: (CGFloat(width) - box.width) / 2 - box.origin.x,
                y: baseline - box.origin.y)
            CTLineDraw(line, context)
            baseline -= lineHeight + lineGap
        }
    }

    /// Moves the lit pixels so their bounding box is centered. Line metrics
    /// include leading and descent the glyphs may not use, which pushed
    /// two-line labels against an edge.
    private static func centeredByInk(_ buffer: [UInt8]) -> [UInt8] {
        var x0 = width, x1 = -1, y0 = height, y1 = -1
        for row in 0..<height {
            for x in 0..<width where buffer[row * width + x] > 0 {
                x0 = min(x0, x); x1 = max(x1, x)
                y0 = min(y0, row); y1 = max(y1, row)
            }
        }
        guard x1 >= x0, y1 >= y0 else { return buffer }

        let dx = (width - (x1 - x0 + 1)) / 2 - x0
        let dy = (height - (y1 - y0 + 1)) / 2 - y0
        guard dx != 0 || dy != 0 else { return buffer }

        var shifted = [UInt8](repeating: 0, count: width * height)
        for row in y0...y1 {
            let targetRow = row + dy
            guard targetRow >= 0, targetRow < height else { continue }
            for x in x0...x1 {
                let targetX = x + dx
                guard targetX >= 0, targetX < width else { continue }
                shifted[targetRow * width + targetX] = buffer[row * width + x]
            }
        }
        return shifted
    }
}
