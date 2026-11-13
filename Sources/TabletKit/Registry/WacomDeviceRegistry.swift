// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

// MARK: - Registry

/// Every Wacom device TabletKit recognizes, keyed by USB product ID.
///
/// Look a device up with `spec(for:)`, then call its
/// ``TabletSpec/makeDecoder()``.
public enum WacomDeviceRegistry: Sendable {

    /// Every USB vendor ID whose PIDs this registry is keyed on.
    ///
    /// Wacom ships under two VIDs: 0x056A for the main line, and 0x0531
    /// (Wacom Technology Corp.) for the consumer Wacom One CTC line. Test
    /// membership here rather than comparing against 0x056A; a second
    /// literal once left the 0x0531 rows without their `initSteps`.
    public static let vendorIDs: Set<Int> = [0x056A, 0x0531]

    // MARK: - Transport-variant unification

    /// Maps Bluetooth Classic and wireless dongle PIDs to the canonical (USB) PID for their model family.
    ///
    /// Wacom assigns distinct product IDs per transport (USB, Bluetooth, wireless dongle).
    /// This map normalizes them so that all three transports of the same physical tablet
    /// share one `DeviceContext` and one settings namespace.
    ///
    /// The USB PID is canonical because it's the reference for HID feature reports and
    /// is always enumerable first. Example: PTH-660 family maps to 0x0357 (USB).
    public static let canonicalPIDMap: [Int: Int] = [
        // Intuos Pro S (PTH-460 family) — PIDs per kernel BT_DEVICE_WACOM(0x393)
        // and libwacom DeviceMatch (usb 0392 / bt 0393; usb 03dc / bt 03dd).
        0x0393: 0x0392,  // BT Classic
        0x03DD: 0x03DC,  // BT Classic (hardware-revision variant)
        0x03F6: 0x03F5,  // Intuos Pro S gen 3 Bluetooth (libwacom DeviceMatch)
        0x03F8: 0x03F7,  // Intuos Pro M gen 3 Bluetooth (libwacom DeviceMatch)
        0x03FA: 0x03F9,  // Intuos Pro L gen 3 Bluetooth (libwacom DeviceMatch)
        0x0401: 0x03F9,  // Intuos Pro L gen 3 USB hardware-revision variant (libwacom DeviceMatch)
        0x042D: 0x03F5,  // Intuos Pro S gen 3 USB revision (vendor model properties)
        0x042E: 0x03F7,  // Intuos Pro M gen 3 USB revision (vendor model properties)
        0x042F: 0x03F9,  // Intuos Pro L gen 3 USB revision (vendor model properties)

        // Intuos Pro M (PTH-660 family)
        0x0360: 0x0357,  // BT Classic

        // Intuos Pro L (PTH-860 family)
        0x0361: 0x0358,  // BT Classic

        // No 0x0359/0x035A: libwacom assigns them to the DTU-1141B and
        // DTH-1152. PTH-660/860 wireless is Bluetooth Classic, not a dongle.

        // Intuos4 WL (PTK-540WL): kernel BT_DEVICE_WACOM(0xBD) is the
        // Bluetooth PID of the USB 0x00BC entry. Decode over BT untested.
        0x00BD: 0x00BC,

        // Intuos BT S/M (CTL-4100WL/6100WL), two hardware generations, each
        // pairing its own USB and Bluetooth PIDs (libwacom DeviceMatch):
        // 0x0376/0x0377 and 0x03C5/0x03C6 (S), 0x0378/0x0379 and
        // 0x03C7/0x03C8 (M). Pairing across generations gave one tablet a
        // second identity, window, and settings over Bluetooth.
        //
        // All four of 0x377/0x379/0x3C6/0x3C8 are kernel type `INTUOSHT3_BT`
        // and send report `0x81`, decoded by `decodeIntuosHT3BTFrames`.
        0x0377: 0x0376,
        0x0379: 0x0378,
        0x03C6: 0x03C5,
        0x03C8: 0x03C7,
    ]

    // MARK: Lookups

    /// PID-keyed index over `knownDevices`, in declaration order within each
    /// PID, so the first match wins.
    private static let specsByPID: [Int: [TabletSpec]] =
        Dictionary(grouping: knownDevices, by: \.productID)

    /// PIDs some other row claims as its touch sensor (`touchCompanionPID`).
    /// Lets the routing layer recognize a sensor interface before the tablet
    /// that claims it has enumerated — arrival order between the two is not
    /// guaranteed.
    public static let touchCompanionPIDs: Set<Int> =
        Set(knownDevices.compactMap(\.touchCompanionPID))

    /// Returns the spec for `productID`, or nil if unrecognised.
    public static func spec(for productID: Int) -> TabletSpec? {
        specsByPID[productID]?.first
    }

    /// Returns the best-matching spec for `productID`, optionally using the
    /// device's `kIOHIDProductKey` string to disambiguate when more than one
    /// entry shares the PID.
    ///
    /// Selection order among entries with matching `productID`:
    ///   1. An entry whose `productStringMatch` is a case-insensitive
    ///      substring of `productString` (when `productString != nil`).
    ///   2. An entry with `productStringMatch == nil` (the catch-all).
    ///   3. The first entry, as a last resort.
    ///
    /// Wacom has no PID collisions, so this matches `spec(for:)` for every
    /// current device.
    public static func spec(forProductID productID: Int, productString: String?) -> TabletSpec? {
        let matches = specsByPID[productID] ?? []
        guard !matches.isEmpty else { return nil }
        if let needle = productString?.lowercased() {
            if let hit = matches.first(where: {
                guard let m = $0.productStringMatch?.lowercased(), !m.isEmpty else { return false }
                return needle.contains(m)
            }) {
                return hit
            }
        }
        return matches.first(where: { $0.productStringMatch == nil }) ?? matches.first
    }

    /// Human-readable display name for any Wacom product.
    /// Returns "Wacom 0xXXXX" for PIDs not yet in the table.
    public static func deviceName(forProductID productID: Int) -> String {
        spec(for: productID)?.name
            ?? "Wacom 0x\(String(productID, radix: 16, uppercase: true))"
    }

    /// True when a real decoder exists for this device. Every parser family
    /// has one, so this is true for every registry row.
    public static func hasLiveDecoder(for productID: Int) -> Bool {
        spec(for: productID) != nil
    }

    /// Returns the canonical (USB) product ID for any transport variant of a tablet.
    ///
    /// If `productID` is a Bluetooth or wireless dongle variant, returns the equivalent USB PID.
    /// If `productID` is already canonical (USB) or unmapped, returns it unchanged.
    ///
    /// Used at device connection to unify multi-transport tablets: USB PTH-660 (0x0357) and
    /// BT PTH-660 (0x0360) both normalize to 0x0357, so they share the same `DeviceContext`
    /// and settings namespace.
    public static func canonicalProductID(for productID: Int) -> Int {
        canonicalPIDMap[productID] ?? productID
    }
}
