// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Digitizer usage *numbers*, and whether a `(page, usage)` pair carries
/// meaning this package can decode.
///
/// Kept separate from the page-scoped constants in `GenericDigitizerFrame` and
/// the extended `(page << 16) | usage` constants in `PrecisionTouchLayout`,
/// because the question here is deliberately page-agnostic.
///
/// The reason: **Wacom puts standard digitizer usage numbers on its own vendor
/// pages.** A Cintiq Pro's pen report declares Tip Switch as `0xFF0D`/`0x42`,
/// pressure as `0xFF0D`/`0x30`, tilt as `0xFF0D`/`0x3D`—`0x3E` — the standard
/// numbers, on a vendor page. Judging such a field by its page alone calls the
/// most completely self-describing descriptors we have "opaque", which is
/// exactly backwards and sends anyone reading a capture off to do correlation
/// analysis against a descriptor that already spells out every field.
///
/// The inverse trap is just as real, which is why this cannot simply trust
/// vendor pages: classic Wacom blob reports also sit on `0xFF0D`/`0xFF00`, with
/// a uniform filler usage (`0x00` or `0x01`) on every byte. Those genuinely
/// carry nothing. Only the usage *number* separates the two cases.
public enum DigitizerUsage: Sendable {

    // MARK: - Standard Digitizer page (0x0D) usage numbers
    //
    // Wacom reuses these verbatim on its vendor pages, which is what makes a
    // page-agnostic set the right shape for this problem.

    public static let tipPressure: UInt32 = 0x30
    public static let inRange: UInt32 = 0x32
    public static let dataValid: UInt32 = 0x36
    public static let invert: UInt32 = 0x3C
    public static let tiltX: UInt32 = 0x3D
    public static let tiltY: UInt32 = 0x3E
    public static let twist: UInt32 = 0x41
    public static let tipSwitch: UInt32 = 0x42
    public static let barrelSwitch: UInt32 = 0x44
    public static let eraserSwitch: UInt32 = 0x45
    public static let confidence: UInt32 = 0x47
    public static let width: UInt32 = 0x48
    public static let height: UInt32 = 0x49
    public static let contactID: UInt32 = 0x51
    public static let deviceMode: UInt32 = 0x52
    public static let deviceIndex: UInt32 = 0x53
    public static let contactCount: UInt32 = 0x54
    public static let contactCountMaximum: UInt32 = 0x55
    public static let scanTime: UInt32 = 0x56
    public static let secondaryBarrel: UInt32 = 0x5A
    public static let transducerSerial: UInt32 = 0x5B

    /// Carries the tool/transducer type on every Wacom descriptor examined
    /// here, alongside `transducerSerial`.
    ///
    /// Named for what it is observed to hold rather than for the HID usage
    /// tables, which assign `0x5C` on the Digitizer page to something else
    /// entirely. This is a Wacom convention on a Wacom page, not a claim about
    /// the standard.
    public static let transducerToolType: UInt32 = 0x5C

    // MARK: - Wacom vendor position usages
    //
    // The one place Wacom departs from standard numbering. Position on a
    // vendor page is `0x0130`/`0x0131` rather than Generic Desktop X/Y, and
    // both the pen reports and the vendor-page touch reports use them.

    public static let vendorX: UInt32 = 0x0130
    public static let vendorY: UInt32 = 0x0131
    /// Hover height above the surface. Distinct from tip pressure, and present
    /// on pen reports that also declare pressure.
    public static let vendorHoverDistance: UInt32 = 0x0132

    /// Usage numbers that carry digitizer meaning wherever they appear,
    /// including on a vendor page.
    public static let decodableOnVendorPage: Set<UInt32> = [
        tipPressure, inRange, dataValid, invert, tiltX, tiltY, twist,
        tipSwitch, barrelSwitch, eraserSwitch, confidence, width, height,
        contactID, deviceMode, deviceIndex, contactCount, contactCountMaximum,
        scanTime, secondaryBarrel, transducerSerial, transducerToolType,
        vendorX, vendorY, vendorHoverDistance,
    ]

    /// HID usage pages whose usages this package understands wholesale.
    /// Generic Desktop, Button, Consumer, Digitizer.
    public static let standardPages: Set<UInt32> = [0x01, 0x09, 0x0C, 0x0D]

    /// Whether a field's `(page, usage)` pair carries decodable meaning.
    ///
    /// Three cases, in order:
    /// - Usage `0x00` is filler on any page, including the correct Digitizer
    ///   page — an Intuos5 touch descriptor declares every field that way.
    /// - On a standard page, any named usage counts.
    /// - On a vendor page (`>= 0xFF00`), only a usage number from
    ///   `decodableOnVendorPage` counts, which admits Wacom's structured
    ///   reports while still rejecting its blob reports.
    ///
    /// A non-standard, non-vendor page is treated as unreadable rather than
    /// guessed at.
    public static func isDecodable(usagePage: UInt32, usage: UInt32) -> Bool {
        guard usage != 0x00 else { return false }
        if standardPages.contains(usagePage) { return true }
        guard usagePage >= 0xFF00 else { return false }
        return decodableOnVendorPage.contains(usage)
    }
}
