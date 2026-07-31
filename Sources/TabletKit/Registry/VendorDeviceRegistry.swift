// SPDX-License-Identifier: MPL-2.0
//
// Vendor-neutral recognition registry for non-Wacom tablets.
//
// Bulk-imported from OpenTabletDriver's per-vendor JSON configs via
// `tools/import_vendor_configs.py`.  The generated entries carry no decoder
// dispatch — they exist so the app can name a device it doesn't yet support
// and route the user to log-capture instead of an opaque "unknown device"
// error.  Devices MockTab can actually drive are marked separately by the
// hand-maintained `drivableProfile(forVendorID:productID:)` below (Xencelabs
// only, at present); the rest of this registry remains recognition-only.
//
// To refresh from a newer OTD snapshot:
//
//     python3 tools/import_vendor_configs.py \
//         /path/to/OpenTabletDriver/.../Configurations \
//         --vendors Huion Xencelabs XP-Pen \
//         > /tmp/entries.swift
//
// Then replace the body between the `// BEGIN GENERATED` / `// END GENERATED`
// markers with the script's stdout.
//
// Lookup semantics: `profiles(forVendorID:productID:)` returns an *array*
// because the Huion line in particular packs dozens of distinct products
// behind the same (VID, PID) and discriminates only by USB string descriptor
// #201 — callers that need to single out one product must inspect
// `productStringRegex` against the live descriptor themselves.

import Foundation

public enum VendorDeviceRegistry {

    // MARK: - Lookup

    /// All profiles matching the given USB Vendor/Product ID pair.  Returns
    /// an empty array when nothing matches.  Multiple results are normal for
    /// Huion (PID collisions across product families).
    public static func profiles(forVendorID vendorID: Int, productID: Int) -> [VendorDeviceProfile] {
        knownDevices.filter { $0.vendorID == vendorID && $0.productID == productID }
    }

    /// All profiles for a given vendor brand (case-sensitive — matches the
    /// strings emitted by the OTD importer: "Huion", "Xencelabs", "XP-Pen").
    public static func profiles(forVendor vendor: String) -> [VendorDeviceProfile] {
        knownDevices.filter { $0.vendor == vendor }
    }

    /// A profile matching a product ID alone, regardless of vendor ID.
    /// Useful when a caller has a canonical productID but can't reliably
    /// obtain the matching vendor ID (e.g. UI code reading a device context
    /// mid-connect). PID collisions *across* vendors aren't a concern in
    /// this registry today (Huion/XP-Pen/Xencelabs don't share PID space);
    /// this returns the first match if that ever changes.
    public static func profile(forProductID productID: Int) -> VendorDeviceProfile? {
        knownDevices.first { $0.productID == productID }
    }

    /// The profile for a non-Wacom device MockTab can actually *drive* (a
    /// decoder exists and the init handshake is known), or nil when the device
    /// is recognition-only.
    ///
    /// Deliberately a hand-maintained allowlist rather than a flag on the
    /// generated entries: the generated registry is bulk-imported and
    /// regenerated wholesale, and drivability is a property of our decoder
    /// coverage, not of the imported data.
    ///
    /// Current coverage: Xencelabs Pen Tablet Medium (0x5201) and Small
    /// (0x5204), Pen Display 24 (0x520D), Pen Display 16 (0x520B), Quick Keys
    /// (0x5202, aux-only), and the Quick Keys wireless USB Dongle (0x5203,
    /// aux-only), via `XencelabsDecoder` (report-2 layout confirmed on real
    /// Pen Display 24 and Quick Keys hardware 2026-07-02; the Pen Tablets and
    /// the Pen Display 16 are assumed to share it — same OEM firmware family
    /// — pending their own hardware pass; see the 0x520B entry below for the
    /// Pen Display 16's still-unconfirmed logical coordinate maxima).
    /// The dongle was confirmed 2026-07-06 to relay an already-paired puck's
    /// input reports completely transparently — identical report-2 0xF0 aux
    /// frames, byte-for-byte, as talking to the puck directly over USB — so
    /// it reuses `XencelabsDecoder` unchanged rather than needing its own
    /// decode path. MockTab only drives an already-paired dongle; pairing a
    /// dongle to a puck stays the native Xencelabs driver's job.
    /// Huion / XP-Pen PID collisions need string-descriptor
    /// discrimination before any of their entries can be promoted here.
    public static func drivableProfile(
        forVendorID vendorID: Int, productID: Int
    ) -> VendorDeviceProfile? {
        guard vendorID == 0x28BD,
            productID == 0x5201 || productID == 0x5202 || productID == 0x5204
                || productID == 0x520D || productID == 0x520B || productID == 0x5203
        else {
            return nil
        }
        return profiles(forVendorID: vendorID, productID: productID).first
    }

    /// If `productID` has a companion peripheral (per its profile's
    /// `companions` list) that's also present in `connectedProductIDs`,
    /// returns that companion's PID. Runtime-resolved rather than a static
    /// ownership record: a puck/dongle only gets folded into its tablet's
    /// settings UI while both are actually connected, so unplugging the
    /// tablet (or using the puck standalone with no paired tablet) leaves
    /// the puck free to show its own window again. Returns the first
    /// matching companion; this hardware family never has more than one.
    public static func connectedCompanion(
        forProductID productID: Int, connectedProductIDs: [Int]
    ) -> Int? {
        guard let companions = profile(forProductID: productID)?.companions,
            !companions.isEmpty
        else { return nil }
        return connectedProductIDs.first { companions.contains($0) }
    }

    /// True if `productID` is itself claimed as a companion by some other
    /// currently-connected device — i.e. it should be folded into that
    /// device's settings UI rather than getting a window of its own.
    public static func isConnectedCompanion(
        productID: Int, connectedProductIDs: [Int]
    ) -> Bool {
        connectedCompanionOwner(forProductID: productID, connectedProductIDs: connectedProductIDs) != nil
    }

    /// The PID of the currently-connected device that claims `productID` as
    /// a companion, or nil if `productID` isn't a claimed companion right
    /// now. Lets call sites (menu builders, window-open routing) redirect a
    /// companion PID to its owner instead of just suppressing it.
    public static func connectedCompanionOwner(
        forProductID productID: Int, connectedProductIDs: [Int]
    ) -> Int? {
        connectedProductIDs.first { ownerPID in
            guard ownerPID != productID else { return false }
            return profile(forProductID: ownerPID)?.companions.contains(productID) == true
        }
    }

    /// Canonical product ID for multi-transport accessories, mirroring
    /// `WacomDeviceRegistry.canonicalProductID(for:)`: the Xencelabs Quick
    /// Keys wireless dongle (0x5203) is the wired puck (0x5202) reached over
    /// a different transport, so both fold into one identity — one settings
    /// namespace, one window, one device row. Unmapped PIDs return
    /// unchanged. Only PIDs unique to a single vendor across the catalog may
    /// be mapped here, since callers don't always know the vendor. The
    /// driver layer must keep the raw PID: relay handling (relink handshake,
    /// address-suffixed writes) is transport-specific.
    public static func canonicalProductID(for productID: Int) -> Int {
        productID == 0x5203 ? 0x5202 : productID
    }

    /// Transport priority among simultaneously-connected raw PIDs that fold
    /// to the same `canonicalProductID` — currently just the Quick Keys
    /// puck's three faces. Higher wins. Policy (2026-07-31): USB wins, so a
    /// direct-wired puck always owns the live context over the wireless
    /// dongle. 0x520D is the Pen Display tunneling the dongle's own traffic
    /// (not a third physical path), so it ranks alongside the dongle rather
    /// than above or below it — the two are not expected to compete in
    /// practice, but a decidable order avoids surprises if they ever do.
    /// Unranked PIDs return 0, so a lone connection is always installed and
    /// promoted regardless of what this returns.
    public static func transportPriority(forRawProductID rawProductID: Int) -> Int {
        switch rawProductID {
        case 0x5202: return 2  // wired puck
        case 0x5203, 0x520D: return 1  // wireless dongle / display-relayed
        default: return 0
        }
    }

    // MARK: - Registry

    public static let knownDevices: [VendorDeviceProfile] = [
        // BEGIN GENERATED — do not hand-edit, regenerate via tools/import_vendor_configs.py
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0060,
            productName: "Huion Q630M",
            activeWidthMM: 266.7, activeHeightMM: 166.7,
            maxX: 53340, maxY: 33340,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_T216_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0061,
            productName: "Huion G930L",
            activeWidthMM: 345.44, activeHeightMM: 215.9,
            maxX: 69088, maxY: 43180,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_T209_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0064,
            productName: "Huion H1060P",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 12,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T(205|219)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0064,
            productName: "Huion H1161",
            activeWidthMM: 279.4, activeHeightMM: 174.625,
            maxX: 55880, maxY: 34925,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 10,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T191_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0064,
            productName: "Huion H420X",
            activeWidthMM: 106, activeHeightMM: 66,
            maxX: 21200, maxY: 13200,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_(T210|T223)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0064,
            productName: "Huion H430P",
            activeWidthMM: 121.92, activeHeightMM: 76.2,
            maxX: 24384, maxY: 15240,
            maxPressure: 4095,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T(176|18a|21c)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0064,
            productName: "Huion H580X",
            activeWidthMM: 203.2, activeHeightMM: 127,
            maxX: 40640, maxY: 25400,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T(211|224)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0064,
            productName: "Huion H610 Pro V2",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T184_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0064,
            productName: "Huion H610X",
            activeWidthMM: 254, activeHeightMM: 158.8,
            maxX: 50800, maxY: 31760,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T(212|229)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0064,
            productName: "Huion H640P",
            activeWidthMM: 160, activeHeightMM: 100,
            maxX: 32000, maxY: 20000,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T203_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0064,
            productName: "Huion H642",
            activeWidthMM: 160.02, activeHeightMM: 99.06,
            maxX: 32004, maxY: 19812,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T19g_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0064,
            productName: "Huion H950P",
            activeWidthMM: 221, activeHeightMM: 138,
            maxX: 44200, maxY: 27600,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T22d_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0064,
            productName: "Huion HC16",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 12,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T18C_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0064,
            productName: "Huion HS610",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 12,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T194_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0064,
            productName: "Huion RTE-100",
            activeWidthMM: 121.92, activeHeightMM: 76.19,
            maxX: 24384, maxY: 15238,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T217_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0064,
            productName: "Huion RTM-500",
            activeWidthMM: 220.995, activeHeightMM: 137.995,
            maxX: 44199, maxY: 27599,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T19h_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0064,
            productName: "Huion RTP-700",
            activeWidthMM: 279.4, activeHeightMM: 174.6,
            maxX: 55880, maxY: 34920,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T19k_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0066,
            productName: "Huion H641P",
            activeWidthMM: 160, activeHeightMM: 100,
            maxX: 32000, maxY: 20000,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T21j_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0067,
            productName: "Huion H951P",
            activeWidthMM: 221, activeHeightMM: 138,
            maxX: 44200, maxY: 27600,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 11,
            otdParser: "InspiroyReportParser",
            productStringRegex: "HUION_T21k_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x0068,
            productName: "Huion H1061P",
            activeWidthMM: 266.7, activeHeightMM: 166.7,
            maxX: 53340, maxY: 33340,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 11,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T21m_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006B,
            productName: "Huion Kamvas Pro 19 (4K)",
            activeWidthMM: 408.96, activeHeightMM: 230.03,
            maxX: 81792, maxY: 46006,
            maxPressure: 16383,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M220_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion GC610",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T166_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion H1060P",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 12,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T(167|205)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion H1161",
            activeWidthMM: 279.4, activeHeightMM: 174.625,
            maxX: 55880, maxY: 34925,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 10,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T191_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion H320M",
            activeWidthMM: 228.5, activeHeightMM: 142.9,
            maxX: 45700, maxY: 28580,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 11,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T198_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion H420X",
            activeWidthMM: 106, activeHeightMM: 66,
            maxX: 21200, maxY: 13200,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T210_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion H430P",
            activeWidthMM: 121.92, activeHeightMM: 76.2,
            maxX: 24384, maxY: 15240,
            maxPressure: 4095,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T(176|18a|21c)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion H610 Pro",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T175_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion H610 Pro V2",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T184_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion H610X",
            activeWidthMM: 254, activeHeightMM: 158.8,
            maxX: 50800, maxY: 31760,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T212_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion H640P",
            activeWidthMM: 160, activeHeightMM: 100,
            maxX: 32000, maxY: 20000,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T173_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion H642",
            activeWidthMM: 160.02, activeHeightMM: 99.06,
            maxX: 32004, maxY: 19812,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T19g_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion H950P",
            activeWidthMM: 221, activeHeightMM: 138,
            maxX: 44200, maxY: 27600,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T(172|204)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion HC16",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 12,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T18C_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion HS610",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 12,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T194_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion HS611",
            activeWidthMM: 258.4, activeHeightMM: 161.5,
            maxX: 51680, maxY: 32300,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 10,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T19c_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion HS64",
            activeWidthMM: 160, activeHeightMM: 102,
            maxX: 32000, maxY: 20400,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T(181|193)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion HS95",
            activeWidthMM: 203.19, activeHeightMM: 126.99,
            maxX: 40638, maxY: 25398,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T206_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Kamvas 12",
            activeWidthMM: 267.9, activeHeightMM: 168.2,
            maxX: 53580, maxY: 33640,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M19p_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Kamvas 13",
            activeWidthMM: 293.76, activeHeightMM: 165.24,
            maxX: 58752, maxY: 33048,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 10,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_(?:M20h|M19f|M215)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Kamvas 16",
            activeWidthMM: 344.2, activeHeightMM: 193.6,
            maxX: 68840, maxY: 38720,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 10,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M18e_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Kamvas 16 (2021)",
            activeWidthMM: 344.2, activeHeightMM: 193.6,
            maxX: 68840, maxY: 38720,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 10,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M19s_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Kamvas 22",
            activeWidthMM: 476.76, activeHeightMM: 268.225,
            maxX: 95352, maxY: 53645,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M19g_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Kamvas 22 Plus",
            activeWidthMM: 476.64, activeHeightMM: 268.11,
            maxX: 95328, maxY: 53622,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M19t_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Kamvas 24 Plus",
            activeWidthMM: 526.85, activeHeightMM: 296.35,
            maxX: 105370, maxY: 59270,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M205_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Kamvas Pro 12",
            activeWidthMM: 267.9, activeHeightMM: 168.2,
            maxX: 53580, maxY: 33640,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M(20j|171)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Kamvas Pro 13",
            activeWidthMM: 293.76, activeHeightMM: 165.24,
            maxX: 58752, maxY: 33048,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_M182_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Kamvas Pro 13 (2.5k)",
            activeWidthMM: 286.465, activeHeightMM: 179.04,
            maxX: 57293, maxY: 35808,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 7,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_M(210|213)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Kamvas Pro 16",
            activeWidthMM: 344.2, activeHeightMM: 193.6,
            maxX: 68840, maxY: 38720,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M183_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Kamvas Pro 16 (2.5k)",
            activeWidthMM: 349.63, activeHeightMM: 196.665,
            maxX: 69926, maxY: 39333,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M214_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Kamvas Pro 16 (4k)",
            activeWidthMM: 344.2, activeHeightMM: 193.6,
            maxX: 68840, maxY: 38720,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M202_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Kamvas Pro 16 Plus (4k)",
            activeWidthMM: 344.2, activeHeightMM: 193.6,
            maxX: 68840, maxY: 38720,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M20a_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Kamvas Pro 24 (4K)",
            activeWidthMM: 527.04, activeHeightMM: 296.46,
            maxX: 105370, maxY: 59270,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M207_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion New 1060 Plus",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 12,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T174_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Q11K",
            activeWidthMM: 279.4, activeHeightMM: 174.625,
            maxX: 55880, maxY: 34925,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T164_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion Q620M",
            activeWidthMM: 266.7, activeHeightMM: 165.1,
            maxX: 53340, maxY: 33020,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_T18d_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion RDS-160",
            activeWidthMM: 344.2, activeHeightMM: 193.6,
            maxX: 68840, maxY: 38720,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 10,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M211_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion RTM-500",
            activeWidthMM: 220.995, activeHeightMM: 137.995,
            maxX: 44199, maxY: 27599,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T19h_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006D,
            productName: "Huion RTP-700",
            activeWidthMM: 279.4, activeHeightMM: 174.6,
            maxX: 55880, maxY: 34920,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T19k_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion 1060 Plus",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 40000, maxY: 25000,
            maxPressure: 2047,
            penButtonCount: 2, auxButtonCount: 12,
            otdParser: "UCLogicReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion 420",
            activeWidthMM: 101.6, activeHeightMM: 57.01295,
            maxX: 8340, maxY: 4680,
            maxPressure: 2047,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "TabletReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion G10T",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T161_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion GC610",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T166_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion GT-156HD V2",
            activeWidthMM: 343.9, activeHeightMM: 193.55,
            maxX: 68780, maxY: 38710,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 14,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M174_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion GT-220 V2",
            activeWidthMM: 476.68, activeHeightMM: 268.145,
            maxX: 95336, maxY: 53629,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M165_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion GT-221",
            activeWidthMM: 476.73, activeHeightMM: 268.205,
            maxX: 95346, maxY: 53641,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 10,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M175_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion GT-221 Pro",
            activeWidthMM: 476.73, activeHeightMM: 268.205,
            maxX: 95346, maxY: 53641,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 10,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M167_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion H1060P",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 12,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T167_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion H420",
            activeWidthMM: 101.6, activeHeightMM: 57.01295,
            maxX: 8340, maxY: 4680,
            maxPressure: 2047,
            penButtonCount: 2, auxButtonCount: 3,
            otdParser: "UCLogicReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion H430P",
            activeWidthMM: 121.92, activeHeightMM: 76.2,
            maxX: 24384, maxY: 15240,
            maxPressure: 4095,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T(176|18a|21c)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion H610 Pro",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T175_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion H610 Pro V2",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T184_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion H610 Pro V3",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 2048, maxY: 2048,
            maxPressure: 2047,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "TabletReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion H640P",
            activeWidthMM: 160, activeHeightMM: 100,
            maxX: 32000, maxY: 20000,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T173_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion H690",
            activeWidthMM: 228.6, activeHeightMM: 142.875,
            maxX: 36000, maxY: 22500,
            maxPressure: 2047,
            penButtonCount: 2, auxButtonCount: 3,
            otdParser: "UCLogicReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion H950P",
            activeWidthMM: 221, activeHeightMM: 138,
            maxX: 44200, maxY: 27600,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T(172|204)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion HS64",
            activeWidthMM: 160, activeHeightMM: 102,
            maxX: 32000, maxY: 20400,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T181_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion Kamvas 20",
            activeWidthMM: 434.75, activeHeightMM: 238.75,
            maxX: 86950, maxY: 47750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_(M192|M189)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion Kamvas Pro 12",
            activeWidthMM: 267.9, activeHeightMM: 168.2,
            maxX: 53580, maxY: 33640,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M171_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion Kamvas Pro 13",
            activeWidthMM: 293.76, activeHeightMM: 165.24,
            maxX: 58752, maxY: 33048,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_M182_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion Kamvas Pro 20",
            activeWidthMM: 435.375, activeHeightMM: 238.75,
            maxX: 87075, maxY: 47750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 16,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M193_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion Kamvas Pro 22 (2019)",
            activeWidthMM: 476.75, activeHeightMM: 268.22,
            maxX: 95350, maxY: 53644,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 20,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M194_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion Kamvas Pro 24",
            activeWidthMM: 526.895, activeHeightMM: 296.18,
            maxX: 105379, maxY: 59236,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 20,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_M184_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion New 1060 Plus",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 12,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T174_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion New 1060 Plus (2048)",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 40000, maxY: 25000,
            maxPressure: 2047,
            penButtonCount: 2, auxButtonCount: 12,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T151_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion Q11K",
            activeWidthMM: 279.4, activeHeightMM: 174.625,
            maxX: 55880, maxY: 34925,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T164_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion Q11K V2",
            activeWidthMM: 279.4, activeHeightMM: 174.625,
            maxX: 55880, maxY: 34925,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T185_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion WH1409",
            activeWidthMM: 350, activeHeightMM: 218,
            maxX: 70000, maxY: 43600,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 12,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_T153_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion WH1409 V2",
            activeWidthMM: 350, activeHeightMM: 218,
            maxX: 70000, maxY: 43600,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 12,
            otdParser: "GianoReportParser",
            productStringRegex: "HUION_T188_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006E,
            productName: "Huion WH1409 V2 (Variant 2)",
            activeWidthMM: 350.52, activeHeightMM: 219.0623,
            maxX: 55200, maxY: 34498,
            maxPressure: 2047,
            penButtonCount: 2, auxButtonCount: 12,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T153_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006F,
            productName: "Huion H320M",
            activeWidthMM: 228.5, activeHeightMM: 142.9,
            maxX: 45700, maxY: 28580,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 11,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T198_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006F,
            productName: "Huion H430P",
            activeWidthMM: 121.92, activeHeightMM: 76.2,
            maxX: 24384, maxY: 15240,
            maxPressure: 4095,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T(176|18a|21c)_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006F,
            productName: "Huion H950P",
            activeWidthMM: 221, activeHeightMM: 138,
            maxX: 44200, maxY: 27600,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T204_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006F,
            productName: "Huion HS611",
            activeWidthMM: 258.4, activeHeightMM: 161.5,
            maxX: 51680, maxY: 32300,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 10,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_T19c_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x006F,
            productName: "Huion HS64",
            activeWidthMM: 160, activeHeightMM: 102,
            maxX: 32000, maxY: 20400,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "UCLogicReportParser",
            productStringRegex: "HUION_T225_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "Huion",
            vendorID: 0x256C, productID: 0x2008,
            productName: "Huion Kamvas 13 (Gen 3)",
            activeWidthMM: 293.8, activeHeightMM: 165.2,
            maxX: 58760, maxY: 33040,
            maxPressure: 16383,
            penButtonCount: 3, auxButtonCount: 7,
            otdParser: "UCLogicTiltReportParser",
            productStringRegex: "HUION_M22c_\\d{6}$"),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x000B,
            productName: "XP-Pen Artist 13.3",
            activeWidthMM: 293.76, activeHeightMM: 165.24,
            maxX: 29376, maxY: 16524,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x000C,
            productName: "XP-Pen Artist 15.6",
            activeWidthMM: 344.19, activeHeightMM: 194.61,
            maxX: 34419, maxY: 19461,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0042,
            productName: "XP-Pen Deco 01",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 25400, maxY: 15875,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x5543, productID: 0x0047,
            productName: "XP-Pen Artist 22HD",
            activeWidthMM: 476.64, activeHeightMM: 268.11,
            maxX: 38161, maxY: 21458,
            maxPressure: 2047,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x5543, productID: 0x004A,
            productName: "XP-Pen Artist 10S",
            activeWidthMM: 216.96, activeHeightMM: 135.6,
            maxX: 21696, maxY: 13560,
            maxPressure: 2047,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "UCLogicV1ReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x5543, productID: 0x004D,
            productName: "XP-Pen Artist 16",
            activeWidthMM: 344.16, activeHeightMM: 193.59,
            maxX: 34416, maxY: 19359,
            maxPressure: 2047,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenOffsetAuxReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0061,
            productName: "XP-Pen Star G540 Pro",
            activeWidthMM: 136.8, activeHeightMM: 73.025,
            maxX: 54720, maxY: 29210,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0062,
            productName: "XP-Pen Star 06C",
            activeWidthMM: 254, activeHeightMM: 152.4,
            maxX: 50800, maxY: 30480,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0071,
            productName: "XP-Pen Star 05 V3",
            activeWidthMM: 203.2, activeHeightMM: 127,
            maxX: 40640, maxY: 25400,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0075,
            productName: "XP-Pen Star G430",
            activeWidthMM: 101.6, activeHeightMM: 76.2,
            maxX: 45720, maxY: 29210,
            maxPressure: 2047,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0075,
            productName: "XP-Pen Star G430S",
            activeWidthMM: 101.6, activeHeightMM: 76.2,
            maxX: 20320, maxY: 15240,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0075,
            productName: "XP-Pen Star G540",
            activeWidthMM: 228.6, activeHeightMM: 146.05,
            maxX: 45720, maxY: 29210,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0077,
            productName: "XP-Pen Star 03 Pro",
            activeWidthMM: 254, activeHeightMM: 152.4,
            maxX: 50800, maxY: 30480,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0078,
            productName: "XP-Pen Star 06",
            activeWidthMM: 254, activeHeightMM: 152.4,
            maxX: 50800, maxY: 30480,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0094,
            productName: "XP-Pen Star G640",
            activeWidthMM: 160, activeHeightMM: 100,
            maxX: 32000, maxY: 20000,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0096,
            productName: "XP-Pen Deco 03",
            activeWidthMM: 254, activeHeightMM: 142.875,
            maxX: 50800, maxY: 28575,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0803,
            productName: "XP-Pen Deco 02",
            activeWidthMM: 254, activeHeightMM: 142.875,
            maxX: 22352, maxY: 13970,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x080A,
            productName: "XP-Pen Artist 12",
            activeWidthMM: 256.32, activeHeightMM: 144.18,
            maxX: 25632, maxY: 14418,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0902,
            productName: "XP-Pen Deco 01 V2",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 25400, maxY: 15875,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0904,
            productName: "XP-Pen Deco Pro Medium",
            activeWidthMM: 278.99, activeHeightMM: 156.995,
            maxX: 55798, maxY: 31399,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0905,
            productName: "XP-Pen Deco 01 V2",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 25400, maxY: 15875,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0905,
            productName: "XP-Pen Deco 01 V2 (Variant 2)",
            activeWidthMM: 254, activeHeightMM: 158.75,
            maxX: 50800, maxY: 31750,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0906,
            productName: "XP-Pen Star G640S",
            activeWidthMM: 165, activeHeightMM: 103,
            maxX: 32999, maxY: 20599,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0907,
            productName: "XP-Pen Star 03",
            activeWidthMM: 254, activeHeightMM: 152.4,
            maxX: 50800, maxY: 30480,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0909,
            productName: "XP-Pen Deco Pro Small",
            activeWidthMM: 230.12, activeHeightMM: 129.54,
            maxX: 46024, maxY: 25908,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x090D,
            productName: "XP-Pen Artist 15.6 Pro",
            activeWidthMM: 344.16, activeHeightMM: 193.59,
            maxX: 34416, maxY: 19359,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0913,
            productName: "XP-Pen Star G430S",
            activeWidthMM: 101.6, activeHeightMM: 76.2,
            maxX: 20320, maxY: 15240,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0913,
            productName: "XP-Pen Star G430S V2",
            activeWidthMM: 101.6, activeHeightMM: 76.2,
            maxX: 10160, maxY: 7620,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0914,
            productName: "XP-Pen Star G640",
            activeWidthMM: 160, activeHeightMM: 100,
            maxX: 32000, maxY: 20000,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0914,
            productName: "XP-Pen Star G640 (Variant 2)",
            activeWidthMM: 160, activeHeightMM: 100,
            maxX: 15999, maxY: 9999,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0917,
            productName: "XP-Pen Star G960S",
            activeWidthMM: 228.8, activeHeightMM: 152.6,
            maxX: 22860, maxY: 15240,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0918,
            productName: "XP-Pen Star G960S Plus",
            activeWidthMM: 228.6, activeHeightMM: 152.4,
            maxX: 22860, maxY: 15240,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x091A,
            productName: "XP-Pen Artist 15.6",
            activeWidthMM: 344.19, activeHeightMM: 194.61,
            maxX: 34419, maxY: 19461,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x091F,
            productName: "XP-Pen Artist 12 Pro",
            activeWidthMM: 256.34, activeHeightMM: 144.15,
            maxX: 25634, maxY: 14415,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0920,
            productName: "XP-Pen Star G960",
            activeWidthMM: 223.52, activeHeightMM: 139.7,
            maxX: 22352, maxY: 13970,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 4,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0928,
            productName: "XP-Pen Deco mini7",
            activeWidthMM: 177.8, activeHeightMM: 111.095,
            maxX: 35560, maxY: 22219,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0929,
            productName: "XP-Pen Deco mini4",
            activeWidthMM: 101.6, activeHeightMM: 76.2,
            maxX: 20320, maxY: 15240,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x092B,
            productName: "XP-Pen Artist 13.3 Pro",
            activeWidthMM: 293.62, activeHeightMM: 165.1,
            maxX: 29362, maxY: 16510,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x092C,
            productName: "XP-Pen Innovator 16",
            activeWidthMM: 343.915, activeHeightMM: 193.545,
            maxX: 68783, maxY: 38709,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x092D,
            productName: "XP-Pen Artist 24 Pro",
            activeWidthMM: 526.85, activeHeightMM: 296.35,
            maxX: 105370, maxY: 59270,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 20,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x092E,
            productName: "XP-Pen Artist Pro 16TP",
            activeWidthMM: 345.615, activeHeightMM: 194.385,
            maxX: 69123, maxY: 38877,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x092F,
            productName: "XP-Pen Artist 22 (2nd Gen)",
            activeWidthMM: 476.64, activeHeightMM: 267.78,
            maxX: 47664, maxY: 26778,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0930,
            productName: "XP-Pen CT430",
            activeWidthMM: 121.92, activeHeightMM: 76.2,
            maxX: 24384, maxY: 15240,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0931,
            productName: "XP-Pen CT640",
            activeWidthMM: 160, activeHeightMM: 101.6,
            maxX: 32000, maxY: 20320,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0932,
            productName: "XP-Pen CT1060",
            activeWidthMM: 254.505, activeHeightMM: 159.305,
            maxX: 50901, maxY: 31861,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0933,
            productName: "XP-Pen Deco Pro SW",
            activeWidthMM: 230.12, activeHeightMM: 129.54,
            maxX: 46024, maxY: 25908,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0935,
            productName: "XP-Pen Deco L",
            activeWidthMM: 254, activeHeightMM: 152.4,
            maxX: 50800, maxY: 30480,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenOffsetPressureReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0936,
            productName: "XP-Pen Deco M",
            activeWidthMM: 203.2, activeHeightMM: 127,
            maxX: 40640, maxY: 25400,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenOffsetPressureReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0943,
            productName: "XP-Pen Deco Pro LW Gen2",
            activeWidthMM: 278.99, activeHeightMM: 173.99,
            maxX: 55798, maxY: 34798,
            maxPressure: 16383,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenGen2ReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x0944,
            productName: "XP-Pen Deco Pro XLW Gen2",
            activeWidthMM: 381, activeHeightMM: 229.005,
            maxX: 76200, maxY: 45801,
            maxPressure: 16383,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenGen2ReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x094A,
            productName: "XP-Pen Artist 12 (2nd Gen)",
            activeWidthMM: 263.19, activeHeightMM: 148.08,
            maxX: 52638, maxY: 29616,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenOffsetPressureReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x094B,
            productName: "XP-Pen Artist 16 Pro",
            activeWidthMM: 341.07, activeHeightMM: 191.795,
            maxX: 68214, maxY: 38359,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 8,
            otdParser: "XP_PenReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x094C,
            productName: "XP-Pen Artist 16 (2nd Gen)",
            activeWidthMM: 340.99, activeHeightMM: 191.81,
            maxX: 68198, maxY: 38362,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 10,
            otdParser: "XP_PenOffsetPressureReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x094D,
            productName: "XP-Pen Artist 10 (2nd Gen)",
            activeWidthMM: 224.51, activeHeightMM: 126.695,
            maxX: 44902, maxY: 25339,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 6,
            otdParser: "XP_PenOffsetPressureReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x094E,
            productName: "XP-Pen Artist 13 (2nd Gen)",
            activeWidthMM: 293.76, activeHeightMM: 165.24,
            maxX: 58760, maxY: 33040,
            maxPressure: 8191,
            penButtonCount: 2, auxButtonCount: 9,
            otdParser: "XP_PenOffsetPressureReportParser",
            productStringRegex: nil),
        VendorDeviceProfile(
            vendor: "XP-Pen",
            vendorID: 0x28BD, productID: 0x095B,
            productName: "XP-Pen Artist Pro 16 (Gen2)",
            activeWidthMM: 344.68, activeHeightMM: 215.42,
            maxX: 68920, maxY: 43078,
            maxPressure: 16383,
            penButtonCount: 2, auxButtonCount: nil,
            otdParser: "XP_PenGen2ReportParser",
            productStringRegex: nil),
        // auxButtonCount is nil (not 3, an earlier OTD-import artifact from
        // before the Quick Keys puck was modeled as its own companion
        // device): the tablet itself has no onboard express keys or ring —
        // those belong to the puck/dongle companion, see `companions` below.
        VendorDeviceProfile(
            vendor: "Xencelabs",
            vendorID: 0x28BD, productID: 0x5201,
            productName: "XenceLabs Pen Tablet Medium",
            activeWidthMM: 261.62, activeHeightMM: 148,
            maxX: 52324, maxY: 29600,
            maxPressure: 8191,
            penButtonCount: 3, auxButtonCount: nil,
            otdParser: "XenceLabsReportParser",
            productStringRegex: nil,
            companions: [0x5202, 0x5203]),
        VendorDeviceProfile(
            vendor: "Xencelabs",
            vendorID: 0x28BD, productID: 0x5204,
            productName: "XenceLabs Pen Tablet Small",
            activeWidthMM: 178, activeHeightMM: 101,
            maxX: 35600, maxY: 20200,
            maxPressure: 8191,
            penButtonCount: 3, auxButtonCount: nil,
            otdParser: "XenceLabsReportParser",
            productStringRegex: nil,
            companions: [0x5202, 0x5203]),
        // END GENERATED

        // Hand-added, not from the OTD import. maxX/maxY confirmed 2026-07-03
        // from real physical corner sweeps captured directly off the raw HID
        // stream (tools/hid_input_capture.c): both axes clamp at round
        // firmware ceilings of exactly 105000 × 59000, isotropic ~200
        // units/mm, consistent with the published 5080 lpi over the
        // 527.04 × 296.46 mm active area (527.04 × 200 = 105408). X exceeds
        // 16 bits, so it's carried as 24-bit LE in the report — see
        // XencelabsDecoder. Four earlier values were wrong, in order:
        // 65535×65535 and 22352×13970 (report-7 digitizer descriptor —
        // generic/unreliable, never carries live data), 65535×59050 (an edge
        // glide that measured the low 16-bit word's wrap, mistaken for a
        // sensor overscan ceiling), and 39150×59050 (corner sweeps decoded
        // with only 16 bits of X — 105000 mod 65536 ≈ 39464 — which made the
        // sensor look anisotropic; it isn't). maxPressure per spec (8192
        // levels); observed ceiling ~6.4k under hard hand pressure.
        // penButtonCount covers the 3-button pen. auxButtonCount is nil —
        // the QuickKeys puck's 8 express keys + bottom mode button (9) are
        // the puck/dongle companion's own capability, not the display's (see
        // `companions` below); this entry previously carried 9 here too, from
        // before the puck was split into its own device. The display also
        // has 3 onboard capacitive touch buttons of its own (bezelButtonCount)
        // — confirmed 2026-07-14 via live capture: they ride the exact same
        // aux frame format as the puck's express keys (report 2, tag 0xF0,
        // bits 0-2 one-hot on a clean tap), remapped to the bezel-button
        // slots in WacomKnownDevice since this device has no puck of its own
        // to disambiguate them from.
        // Covers the Pen Display 24 and, most likely, the Pen Display 24+ (2025):
        // the two are understood to be the same panel and digitizer, with the
        // plus adding color-calibration software rather than hardware, and a
        // curated catalog lists both under one model number (LPH2412U-A). Nothing
        // here needs to change if that holds — the plus would enumerate as this
        // PID and inherit everything. Deliberately left generic in name for that
        // reason. If a 24+ ever turns up reporting a PID of its own, that is the
        // signal to revisit; the color software is host-side and out of scope
        // either way.
        VendorDeviceProfile(
            vendor: "Xencelabs",
            vendorID: 0x28BD, productID: 0x520D,
            productName: "Xencelabs Pen Display",
            // Confirmed 2026-07-02 from Xencelabs' own published spec: active
            // drawing area 527.04 x 296.46 mm, 16:9. Doesn't feed the
            // coordinate mapping (maxX/maxY do, see above) — cosmetic only.
            activeWidthMM: 527.04, activeHeightMM: 296.46,
            maxX: 105000, maxY: 59000,
            maxPressure: 8191,
            penButtonCount: 3, auxButtonCount: nil, bezelButtonCount: 3,
            otdParser: "XenceLabsReportParser",
            productStringRegex: nil,
            isPenDisplay: true,
            companions: [0x5202, 0x5203]),

        // Hand-added 2026-07-17, sourced from the pinned libwacom snapshot
        // (`upstream/libwacom/data/xencelabs-pen-display-16.tablet`, model
        // LPH1612U-A) — PID and physical dimensions are libwacom-confirmed;
        // no MockTab hardware capture yet, unlike the 24 above. maxX/maxY
        // are NOT from a capture: they're extrapolated from the 24's
        // confirmed density (105000/527.04mm ≈ 199.32 units/mm, isotropic)
        // applied to this model's 344x194mm active area. Treat as a strong
        // estimate, not fact, until a real Pen Display 16 capture confirms
        // or corrects them — same OEM firmware family as the 24 makes the
        // report-2 protocol itself the safer assumption than the coordinate
        // maxima. bezelButtonCount/companions mirrored from the 24 pending
        // its own confirmation (same onboard capacitive-button hardware is
        // plausible, not verified).
        VendorDeviceProfile(
            vendor: "Xencelabs",
            vendorID: 0x28BD, productID: 0x520B,
            productName: "Xencelabs Pen Display 16",
            activeWidthMM: 344, activeHeightMM: 194,
            maxX: 68577, maxY: 38669,
            maxPressure: 8191,
            penButtonCount: 3, auxButtonCount: nil, bezelButtonCount: 3,
            otdParser: "XenceLabsReportParser",
            productStringRegex: nil,
            isPenDisplay: true,
            companions: [0x5202, 0x5203]),

        // Hand-added 2026-07-29. These two pen tablets — the products Xencelabs
        // is best known for, usually bundled with the Quick Keys puck — had no
        // entry at all, so they were being ignored outright.
        //
        // Source is OpenTabletDriver's own configurations (XenceLabs/Pen Tablet
        // Medium.json, Pen Tablet Small.json), the same origin as `otdParser`
        // elsewhere in this file. NOT from a capture, and no MockTab hardware has
        // seen either one — treat as recognition plus a strong estimate, on the
        // same footing as the Pen Display 16 above.
        //
        // Three independent things make the estimate strong rather than a guess:
        //
        // 1. Both land on exactly 200 units/mm on both axes (52324/261.62 and
        //    29600/148; 35600/178 and 20200/101), matching the density the Pen
        //    Display 24's real corner sweeps established for this family.
        // 2. OTD assigns them `XenceLabsReportParser` — the same parser as the
        //    displays, so `XencelabsDecoder` should serve them unchanged.
        // 3. OTD's output-init string decodes to 0x02 0xB0 0x04, byte for byte
        //    the family tablet-mode init documented on the puck below.
        //
        // The three onboard buttons OTD reports are modeled as bezel buttons, not
        // aux buttons, following the Pen Display 24's precedent: on that device
        // the onboard capacitive buttons ride the identical report-2 0xF0 aux
        // frame as the puck's express keys, so they occupy the bezel slots to
        // stay distinguishable from a companion puck's keys. Unverified here.
        VendorDeviceProfile(
            vendor: "Xencelabs",
            vendorID: 0x28BD, productID: 0x5201,
            productName: "Xencelabs Pen Tablet Medium",
            activeWidthMM: 261.62, activeHeightMM: 148,
            maxX: 52324, maxY: 29600,
            maxPressure: 8191,
            penButtonCount: 3, auxButtonCount: nil, bezelButtonCount: 3,
            otdParser: "XenceLabsReportParser",
            productStringRegex: nil,
            companions: [0x5202, 0x5203]),

        VendorDeviceProfile(
            vendor: "Xencelabs",
            vendorID: 0x28BD, productID: 0x5204,
            productName: "Xencelabs Pen Tablet Small",
            activeWidthMM: 178, activeHeightMM: 101,
            maxX: 35600, maxY: 20200,
            maxPressure: 8191,
            penButtonCount: 3, auxButtonCount: nil, bezelButtonCount: 3,
            otdParser: "XenceLabsReportParser",
            productStringRegex: nil,
            companions: [0x5202, 0x5203]),

        // Hand-added, confirmed 2026-07-02 over direct USB on real hardware.
        // Aux-only device (8 express keys, bottom mode button, clickable dial):
        // no pen digitizer, so no coordinate maxima or pressure. Mute until it
        // receives the family's standard tablet-mode init (`[0x02, 0xB0, 0x04]`
        // zero-padded to MaxOutputReportSize, 64 on its main interface), then
        // streams the same report-2 0xF0 aux frames as the Pen Display, as
        // 10-byte reports. XencelabsDecoder handles them unchanged.
        VendorDeviceProfile(
            vendor: "Xencelabs",
            vendorID: 0x28BD, productID: 0x5202,
            productName: "Xencelabs Quick Keys",
            penButtonCount: nil, auxButtonCount: 9,
            otdParser: nil,
            productStringRegex: nil),

        // Confirmed 2026-07-04 via native Xencelabs driver's own diagnostic
        // panel (PID_5203, "Xencelabs Dongle"), and confirmed 2026-07-06 via
        // a raw HID input-report capture (tools/hid_input_capture.c) taken
        // while an already-paired puck operated through it: the dongle
        // relays the puck's report-2 aux frames byte-for-byte identically to
        // a direct-USB connection, so it's aux-only (like the puck itself)
        // and reuses XencelabsDecoder unchanged — no new decode path needed.
        VendorDeviceProfile(
            vendor: "Xencelabs",
            vendorID: 0x28BD, productID: 0x5203,
            productName: "Xencelabs Dongle",
            penButtonCount: nil, auxButtonCount: 9,
            otdParser: nil,
            productStringRegex: nil),
    ]
}
