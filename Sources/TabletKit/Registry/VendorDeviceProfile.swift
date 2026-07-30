// SPDX-License-Identifier: MPL-2.0
//
// Vendor-neutral device recognition record.
//
// `WacomDeviceSpec` carries everything needed to actually decode Wacom HID
// reports.  This type is intentionally weaker: just enough metadata to *name*
// a device that the app doesn't yet have a decoder for, so the unknown-device
// UX can say "Huion H1060P — protocol unsupported, please submit a capture
// log" instead of "Unrecognized device, VID 0x256C, PID 0x006D."
//
// Data is bulk-imported from OpenTabletDriver's per-vendor JSON configs (see
// `tools/import_vendor_configs.py`).  The imported entries carry no decoder
// dispatch: they exist to *name* a device, nothing more.  A small hand-kept
// allowlist on top of them marks the few models MockTab can actually drive —
// see `VendorDeviceRegistry.drivableProfile(forVendorID:productID:)`, which
// today covers only the Xencelabs line.  Everything else stays
// recognition-only until a decoder and a known init handshake exist for it.
//
// Same-PID-many-products is the norm for Huion (PIDs 0x006D / 0x006E each
// cover dozens of products, discriminated only by USB string descriptor #201
// matching a per-product regex).  Lookups therefore return `[Profile]`, not
// `Profile?` — callers showing the result to a human should surface every
// candidate.

import Foundation

public struct VendorDeviceProfile: Equatable {
    /// Vendor brand string as it appears in OTD ("Huion", "Xencelabs", "XP-Pen").
    public let vendor: String
    /// USB Vendor ID.
    public let vendorID: Int
    /// USB Product ID.  May be shared across many products from the same vendor.
    public let productID: Int
    /// Marketing name as published by OTD (e.g. "H1060P", "Pen Tablet Medium").
    public let productName: String
    /// Active-area width in millimetres, when published.
    public let activeWidthMM: Double?
    /// Active-area height in millimetres, when published.
    public let activeHeightMM: Double?
    /// Logical X coordinate maximum (device units), when published.
    public let maxX: Int?
    /// Logical Y coordinate maximum (device units), when published.
    public let maxY: Int?
    /// Pen pressure bit-depth ceiling, when published.
    public let maxPressure: Int?
    /// Number of pen barrel buttons, when published.
    public let penButtonCount: Int?
    /// Number of frame / express buttons, when published.
    public let auxButtonCount: Int?
    /// Number of onboard bezel buttons built into the device itself (e.g. the
    /// Xencelabs Pen Display's 3 capacitive touch buttons), distinct from
    /// `auxButtonCount`'s companion-peripheral express keys. Nil/0 if none.
    public let bezelButtonCount: Int?
    /// OTD's report-parser class name (e.g. "UCLogicTiltReportParser").
    /// Records OTD's parser hint verbatim — useful when picking a decoder
    /// family later without re-deriving from raw bytes.
    public let otdParser: String?
    /// Regex matched against USB string descriptor #201 (or similar) to
    /// disambiguate same-PID products.  Stored as a string — interpreting it
    /// is the caller's job, since the matching strategy is vendor-specific.
    public let productStringRegex: String?
    /// True for display-integrated tablets (pen displays).  Drives
    /// screen-mapping behavior the same way `WacomDeviceSpec.isPenDisplay`
    /// does; defaults false since most imported rows are opaque tablets.
    public let isPenDisplay: Bool
    /// Product IDs of standalone aux-only peripherals (e.g. an EKR-style
    /// remote/puck) that pair with this device and should be folded into
    /// its settings UI instead of getting a window of their own, when both
    /// are connected at once. Resolved against *currently connected*
    /// devices at runtime (see `VendorDeviceRegistry.connectedCompanion`) —
    /// this list is just a static hint, not a live pairing record, mirroring
    /// libwacom's `libwacom_get_paired_device()` match-string approach.
    /// Empty for devices with no companion (including the companion
    /// peripherals themselves, to avoid claiming each other).
    public let companions: [Int]

    public init(
        vendor: String, vendorID: Int, productID: Int, productName: String,
        activeWidthMM: Double? = nil, activeHeightMM: Double? = nil,
        maxX: Int? = nil, maxY: Int? = nil, maxPressure: Int? = nil,
        penButtonCount: Int? = nil, auxButtonCount: Int? = nil,
        bezelButtonCount: Int? = nil,
        otdParser: String? = nil, productStringRegex: String? = nil,
        isPenDisplay: Bool = false, companions: [Int] = []
    ) {
        self.vendor = vendor
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.activeWidthMM = activeWidthMM
        self.activeHeightMM = activeHeightMM
        self.maxX = maxX
        self.maxY = maxY
        self.maxPressure = maxPressure
        self.penButtonCount = penButtonCount
        self.auxButtonCount = auxButtonCount
        self.bezelButtonCount = bezelButtonCount
        self.otdParser = otdParser
        self.productStringRegex = productStringRegex
        self.isPenDisplay = isPenDisplay
        self.companions = companions
    }

    /// Lines per inch derived from `maxX`/`activeWidthMM`.  Returns nil unless
    /// both physical and logical dimensions are populated on both axes.
    /// Matches the shape of `WacomDeviceSpec.lpi` for cross-vendor consistency.
    /// The physical fields carry the same contract documented on
    /// `WacomDeviceSpec.activeWidthMM` — physical extent of the logical range,
    /// not advertised drawing area — which is what makes this division valid.
    public var lpi: (x: Double, y: Double)? {
        guard let w = activeWidthMM, w > 0,
              let h = activeHeightMM, h > 0,
              let mx = maxX, let my = maxY else { return nil }
        return (Double(mx) / w * 25.4, Double(my) / h * 25.4)
    }
}
