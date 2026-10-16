// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

/// Holds the pen position still through moves of a few tablet counts, so
/// sensor noise doesn't flicker the cursor while the pen rests.
///
/// Each axis keeps its output until the raw value moves more than `width`
/// counts away, then follows it at that distance. The pen never trails by
/// more than `width`, and reaching a tablet edge snaps the output to it.
/// Reversing direction costs twice `width` of pen travel before the output
/// moves again.
public struct PositionDeadBand: Sendable {
    /// Counts each axis may move without moving the output. 0 passes every
    /// report through.
    public var width: Int
    private var held: (x: Int, y: Int)?

    public init(width: Int = 0) {
        self.width = width
    }

    /// The position to report for a raw position on a tablet `maxX` by
    /// `maxY` counts.
    public mutating func apply(x: Int, y: Int, maxX: Int, maxY: Int) -> (x: Int, y: Int) {
        guard width > 0, let last = held else {
            held = (x, y)
            return (x, y)
        }
        let out = (
            x: Self.follow(x, from: last.x, width: width, max: maxX),
            y: Self.follow(y, from: last.y, width: width, max: maxY))
        held = out
        return out
    }

    /// Forgets the held position, so the next report passes through as is.
    /// Call when the pen leaves proximity.
    public mutating func reset() {
        held = nil
    }

    private static func follow(_ raw: Int, from last: Int, width: Int, max: Int) -> Int {
        if raw <= 0 { return 0 }
        if raw >= max { return max }
        let delta = raw - last
        if delta > width { return raw - width }
        if delta < -width { return raw + width }
        return last
    }
}
