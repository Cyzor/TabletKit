// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 TabletKit contributors
// SPDX-License-Identifier: MPL-2.0

/// The margins a pen display's digitizer reports beyond its screen, in
/// device units.
package struct PenEdgeInsets: Sendable, Equatable {
    package var left, top, right, bottom: Int

    /// From the pen descriptor's feature 0x0C (usages 0x0D30 to 0x0D33),
    /// only where its minimum and maximum agree, so the device can't report
    /// another value.
    package init?(productID: Int) {
        switch productID {
        // Cintiq Pro 16 (2017) and MobileStudio Pro 13: 400 a side, which
        // the descriptor gives as 2 mm.
        case 0x0350, 0x034D: self.init(left: 400, top: 400, right: 400, bottom: 400)
        default: return nil
        }
    }

    package init(left: Int, top: Int, right: Int, bottom: Int) {
        (self.left, self.top, self.right, self.bottom) = (left, top, right, bottom)
    }

    /// Moves the origin to the screen's corner and shrinks the range to
    /// match. A point in a margin lands on the nearest edge.
    package func trim(_ point: TabletPoint) -> TabletPoint {
        var p = point
        p.maxX = max(point.maxX - left - right, 1)
        p.maxY = max(point.maxY - top - bottom, 1)
        p.x = min(max(point.x - left, 0), p.maxX)
        p.y = min(max(point.y - top, 0), p.maxY)
        return p
    }
}
