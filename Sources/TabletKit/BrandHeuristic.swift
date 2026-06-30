// SPDX-License-Identifier: MPL-2.0
//
// Cheap last-resort brand guess for HID devices that didn't match any
// registry entry by VID/PID. Scans the USB manufacturer/product strings for
// known tablet-brand keywords so an uncatalogued-but-plausible tablet can be
// surfaced to the user instead of silently doing nothing.
//
// Deliberately conservative: a false positive here (matching something that
// isn't actually a tablet) just adds noise to a banner the user can dismiss;
// it never changes routing or driver selection.

import Foundation

public enum BrandHeuristic {

    /// Keyword → display name, checked in order against the lowercased
    /// manufacturer + product strings. Brand names are checked before the
    /// generic category words so "Huion Pen Tablet" reports "Huion", not
    /// just "a drawing tablet".
    private static let keywords: [(needle: String, brand: String)] = [
        ("wacom", "Wacom"),
        ("huion", "Huion"),
        ("xp-pen", "XP-Pen"),
        ("xppen", "XP-Pen"),
        ("xencelabs", "Xencelabs"),
        ("ugee", "UGEE"),
        ("veikk", "VEIKK"),
        ("gaomon", "Gaomon"),
        ("pen display", "a pen display"),
        ("digitizer", "a digitizer"),
        ("tablet", "a drawing tablet"),
    ]

    /// Returns a brand/category guess if either string contains a known
    /// keyword, or nil when nothing matches. `manufacturer` and `product`
    /// are the raw `kIOHIDManufacturerKey` / `kIOHIDProductKey` values.
    public static func likelyBrand(manufacturer: String?, product: String?) -> String? {
        let haystack = [manufacturer, product]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        guard !haystack.isEmpty else { return nil }
        return keywords.first { haystack.contains($0.needle) }?.brand
    }
}
