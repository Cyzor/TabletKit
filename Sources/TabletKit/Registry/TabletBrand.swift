// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A maker of UC-Logic tablets, as people name it.
///
/// Brands pick hardware, and protocols pick decoding: Huion and Gaomon
/// tablets speak ``UCLogicProtocol/huionV2``, and XP-Pen, UGEE, and Parblo
/// tablets speak ``UCLogicProtocol/ugeeV2``. Xencelabs tablets speak UGEE v2
/// too, but have their own decoder and are never one of these brands.
public struct TabletBrand: Hashable, Sendable, CustomStringConvertible {
    /// The brand's name, as ``VendorDeviceProfile/vendor`` writes it.
    public let description: String

    private init(_ name: String) { description = name }

    public static let huion = TabletBrand("Huion")
    public static let gaomon = TabletBrand("Gaomon")
    public static let xpPen = TabletBrand("XP-Pen")
    public static let ugee = TabletBrand("UGEE")
    public static let parblo = TabletBrand("Parblo")

    /// Every brand TabletKit can switch on.
    public static let all: [TabletBrand] = [.huion, .gaomon, .xpPen, .ugee, .parblo]

    /// The brand with this name, ignoring case, spaces, and punctuation, so
    /// "xppen", "XP-Pen", and "XP Pen" are all ``xpPen``.
    public init?(name: String) {
        let key = Self.key(name)
        guard let brand = Self.all.first(where: { Self.key($0.description) == key }) else { return nil }
        self = brand
    }

    private static func key(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The brands a tablet may be, before it's switched on.
    ///
    /// Huion and Gaomon share a vendor ID and some product IDs, so for those
    /// pass `firmwareName`, the tablet's answer to string descriptor 201;
    /// reading it doesn't switch the tablet on. A product ID listed under
    /// more than one brand, with no firmware name to settle it, is all of
    /// them. An unlisted product ID is its vendor ID's main brand. Empty for
    /// Xencelabs and for anything else.
    public static func brands(vendorID: Int, productID: Int, firmwareName: String? = nil) -> Set<TabletBrand> {
        let profiles = VendorDeviceRegistry.profiles(forVendorID: vendorID, productID: productID)
        guard !profiles.contains(where: { $0.vendor == "Xencelabs" }) else { return [] }
        if let firmwareName {
            let named = Set(profiles.filter { $0.matches(firmwareName: firmwareName) }.compactMap { TabletBrand(name: $0.vendor) })
            if named.count == 1 { return named }
            if firmwareName.hasPrefix("HUION_") { return [.huion] }
            if firmwareName.hasPrefix("GM001_") || firmwareName.hasPrefix("OEM02_") { return [.gaomon] }
        }
        let listed = Set(profiles.compactMap { TabletBrand(name: $0.vendor) })
        if !listed.isEmpty { return listed }
        switch vendorID {
        case 0x256C: return [.huion]
        case 0x28BD: return [.xpPen]
        default: return []
        }
    }
}

extension VendorDeviceRegistry {
    /// The one profile that fits a tablet, or `nil` if none or several do.
    ///
    /// `firmwareName`, the answer to string descriptor 201, picks among
    /// products that share a product ID, by each one's
    /// ``VendorDeviceProfile/productStringRegex``.
    public static func profile(forVendorID vendorID: Int, productID: Int, firmwareName: String?) -> VendorDeviceProfile? {
        let candidates = profiles(forVendorID: vendorID, productID: productID)
        if let firmwareName {
            let matching = candidates.filter { $0.matches(firmwareName: firmwareName) }
            if matching.count == 1 { return matching[0] }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}

extension VendorDeviceProfile {
    func matches(firmwareName: String) -> Bool {
        productStringRegex.map { firmwareName.range(of: $0, options: .regularExpression) != nil } ?? false
    }
}

extension UCLogicTabletInfo {
    /// The text of a USB string descriptor, header included, or `nil` if it
    /// isn't one.
    public static func text(ofStringDescriptor bytes: [UInt8]) -> String? {
        guard bytes.count >= 2, bytes[1] == 0x03 else { return nil }
        let length = min(Int(bytes[0]), bytes.count)
        let units = stride(from: 2, to: length - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        return String(decoding: units, as: UTF16.self)
    }
}
