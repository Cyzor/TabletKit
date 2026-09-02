// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Identity of one physical device instance.
///
/// A host has two identity axes that are easy to conflate:
/// - **Model** — the canonical USB product ID. Correct for decoder, spec, and
///   capability lookups (how Wacom's tables and libwacom key everything).
/// - **Instance** — the physical unit. Nicknames, settings namespaces,
///   per-device state, battery, and windows belong to an instance, and keying
///   them by PID alone silently collapses two identical devices into one.
///
/// This type carries both. The instance token comes from the USB serial when
/// the device reports one, else the IOKit `locationID` (stable per port), else
/// empty — which degrades to PID-only behaviour.
public struct DeviceInstanceKey: Hashable, Codable, Sendable {
    /// Canonical model PID (transport variants already folded by the host's
    /// `canonicalProductID` mapping).
    public let productID: Int
    /// Instance token: USB serial, `loc-XXXXXXXX` from `locationID`, or `""`
    /// when the device exposes neither.
    public let instance: String

    public init(productID: Int, instance: String) {
        self.productID = productID
        self.instance = instance
    }

    /// Builds the key from what IOKit exposes at connect time.
    public init(productID: Int, usbSerial: String?, locationID: Int) {
        let token: String
        if let serial = usbSerial, !serial.isEmpty, !Self.isPlaceholderSerial(serial) {
            token = serial
        } else if locationID != 0 {
            token = String(format: "loc-%08X", locationID)
        } else {
            token = ""
        }
        self.init(productID: productID, instance: token)
    }

    /// The Xencelabs Quick Keys wireless dongle relay reports the puck's
    /// serial as the literal string `"000000000000"` rather than omitting it
    /// (the real serial isn't recoverable over that transport). Treated as a
    /// real token, it folds a wirelessly-connected puck into its own instance
    /// row and settings namespace instead of the wired one's.
    public static func isPlaceholderSerial(_ serial: String) -> Bool {
        !serial.contains(where: { !"0:- ".contains($0) })
    }

    /// Stable string form for persistence, window restore, and logs:
    /// `"0x{PID}"` when the instance token is empty, else
    /// `"0x{PID}#{instance}"`.
    public var stringValue: String {
        let pidHex = "0x" + String(productID, radix: 16, uppercase: true)
        return instance.isEmpty ? pidHex : "\(pidHex)#\(instance)"
    }

    /// Parses ``stringValue`` back; `nil` if the PID portion isn't valid hex.
    public init?(stringValue: String) {
        let parts = stringValue.split(separator: "#", maxSplits: 1)
        guard let first = parts.first, first.hasPrefix("0x"),
            let pid = Int(first.dropFirst(2), radix: 16)
        else { return nil }
        self.init(productID: pid, instance: parts.count > 1 ? String(parts[1]) : "")
    }
}
