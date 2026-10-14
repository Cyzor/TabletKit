// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import os

/// Finger ranges read from touch sensors' descriptors, by the product ID of
/// the tablet whose driver read them. For tablets the registry gives no
/// touch range: without one, every contact lands in one corner.
public enum DescribedTouchRanges {
    private static let ranges = OSAllocatedUnfairLock<[Int: (x: Int, y: Int, exact: Bool)]>(initialState: [:])

    /// The range for `productID`. `exact` marks one read from the report the
    /// decoder parses, which outranks one found elsewhere in the descriptor.
    public static func range(forProductID productID: Int) -> (x: Int, y: Int, exact: Bool)? {
        ranges.withLock { $0[productID] }
    }

    static func record(_ range: (x: Int, y: Int, exact: Bool), forProductID productID: Int) {
        ranges.withLock {
            if range.exact ? $0[productID]?.exact != true : $0[productID] == nil { $0[productID] = range }
        }
    }
}
