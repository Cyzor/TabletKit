// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Which UC-Logic protocol a tablet speaks.
///
/// A struct rather than an enum so that adding a protocol later doesn't
/// break code that switches over it.
public struct UCLogicProtocol: Hashable, Sendable, CustomStringConvertible {
    /// A short name for logs.
    public let description: String

    /// Huion and Gaomon tablets. They describe themselves in string
    /// descriptor 200, and reading it switches them on.
    public static let huionV2 = UCLogicProtocol(description: "Huion v2")
    /// XP-Pen, UGEE, and Parblo tablets. They switch on with output report
    /// `02 B0 04`, then describe themselves in string descriptor 100.
    public static let ugeeV2 = UCLogicProtocol(description: "UGEE v2")
}

/// What a UC-Logic tablet says about itself when switched on.
///
/// Huion and Gaomon tablets answer string descriptor 200, and XP-Pen and
/// UGEE tablets answer string descriptor 100. Either answer gives the
/// tablet's coordinate range, pressure levels, and resolution, so these
/// tablets need no registry entry to be sized. Layouts are from the Linux
/// kernel's `hid-uclogic` driver.
///
/// TabletKit doesn't read descriptors itself. The caller reads one and
/// passes the raw bytes here, including the two-byte USB descriptor header.
public struct UCLogicTabletInfo: Sendable, Equatable {
    /// The protocol the answer came from.
    public let tabletProtocol: UCLogicProtocol
    /// Largest pen X coordinate.
    public let maxX: Int
    /// Largest pen Y coordinate.
    public let maxY: Int
    /// Largest pressure value.
    public let maxPressure: Int
    /// Resolution in lines per inch, or 0 if the tablet didn't say.
    public let lpi: Int
    /// Buttons on the tablet itself.
    public let tabletButtonCount: Int

    /// Width of the active area in millimeters, or `nil` without a resolution.
    public var activeWidthMM: Double? { millimeters(maxX) }
    /// Height of the active area in millimeters, or `nil` without a resolution.
    public var activeHeightMM: Double? { millimeters(maxY) }

    private func millimeters(_ units: Int) -> Double? {
        lpi > 0 ? Double(units) / Double(lpi) * 25.4 : nil
    }

    /// The spec a decoder needs. Both protocols report tilt from −60° to 60°.
    public var digitizerSpec: DigitizerSpec {
        DigitizerSpec(
            maxX: maxX, maxY: maxY, maxPressure: maxPressure,
            buttonCount: tabletButtonCount, hasTilt: true, tiltMaxDegrees: 60)
    }

    /// Reads a Huion or Gaomon tablet's answer to string descriptor 200.
    ///
    /// Returns `nil` if the answer is too short, or is only text: some
    /// tablets answer every unknown string descriptor with their name.
    public init?(huionDescriptor200 bytes: [UInt8]) {
        // The kernel accepts 18 to 32 bytes.
        guard bytes.count >= 18, !Self.isOnlyText(bytes) else { return nil }
        tabletProtocol = .huionV2
        maxX = Self.le24(bytes, 2)
        maxY = Self.le24(bytes, 5)
        maxPressure = Self.le16(bytes, 8)
        lpi = Self.le16(bytes, 10)
        // Matches the key count on every Huion answer seen so far.
        tabletButtonCount = Int(bytes[13])
    }

    /// Reads an XP-Pen or UGEE tablet's answer to string descriptor 100.
    ///
    /// Returns `nil` if the answer is too short to hold the fields.
    public init?(ugeeDescriptor100 bytes: [UInt8]) {
        // 12 bytes is the minimum; 14-byte answers add a third byte of X.
        guard bytes.count >= 12 else { return nil }
        tabletProtocol = .ugeeV2
        maxX = Self.le16(bytes, 2) | (bytes.count > 12 ? Int(bytes[12]) << 16 : 0)
        maxY = Self.le16(bytes, 4)
        tabletButtonCount = Int(bytes[6])
        maxPressure = Self.le16(bytes, 8)
        lpi = Self.le16(bytes, 10)
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i + 1]) << 8
    }

    private static func le24(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16
    }

    /// True when every UTF-16 character after the header is printable ASCII.
    private static func isOnlyText(_ b: [UInt8]) -> Bool {
        stride(from: 2, to: b.count - 1, by: 2).allSatisfy { b[$0] >= 0x20 && b[$0] < 0x7F && b[$0 + 1] == 0 }
    }
}
