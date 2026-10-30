// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The Wacom registry as `registry.json` publishes it, for scripts, websites,
/// and drivers on other platforms. `swift run registry-export` writes the
/// file, and a test fails when the committed copy falls behind.
package struct RegistrySnapshot: Codable, Equatable, Sendable {
    package var schemaVersion = 2
    package var vendorID = "0x056A"
    package var note = "Generated from WacomDeviceRegistry.swift by `swift run registry-export`. "
        + "Don't edit by hand. Field meanings match the doc comments on TabletSpec in that file."
    package var deviceCount: Int
    package var devices: [Device]

    /// One registry row. Optional fields write `null`, so every key is
    /// always present.
    package struct Device: Codable, Equatable, Sendable {
        package var productID: String
        package var name: String
        package var parser: String
        package var confidence: String
        package var productStringMatch: String?
        package var maxX: Int
        package var maxY: Int
        package var maxPressure: Int
        package var buttonCount: Int
        package var maxTouchContacts: Int
        package var touchMaxX: Int
        package var touchMaxY: Int
        package var hasTouchRing: Bool
        package var hasEraser: Bool
        package var hasFingerTouch: Bool
        package var isPenDisplay: Bool
        package var seizeUSB: Bool
        package var activeWidthMM: Double?
        package var activeHeightMM: Double?
        /// A public-facing reason when the model is out of scope.
        package var outOfScope: String?

        package func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(productID, forKey: .productID)
            try c.encode(name, forKey: .name)
            try c.encode(parser, forKey: .parser)
            try c.encode(confidence, forKey: .confidence)
            try c.encode(productStringMatch, forKey: .productStringMatch)
            try c.encode(maxX, forKey: .maxX)
            try c.encode(maxY, forKey: .maxY)
            try c.encode(maxPressure, forKey: .maxPressure)
            try c.encode(buttonCount, forKey: .buttonCount)
            try c.encode(maxTouchContacts, forKey: .maxTouchContacts)
            try c.encode(touchMaxX, forKey: .touchMaxX)
            try c.encode(touchMaxY, forKey: .touchMaxY)
            try c.encode(hasTouchRing, forKey: .hasTouchRing)
            try c.encode(hasEraser, forKey: .hasEraser)
            try c.encode(hasFingerTouch, forKey: .hasFingerTouch)
            try c.encode(isPenDisplay, forKey: .isPenDisplay)
            try c.encode(seizeUSB, forKey: .seizeUSB)
            try c.encode(activeWidthMM, forKey: .activeWidthMM)
            try c.encode(activeHeightMM, forKey: .activeHeightMM)
            try c.encode(outOfScope, forKey: .outOfScope)
        }
    }

    /// The registry as it stands in this build.
    package static func current() -> RegistrySnapshot {
        let devices = WacomDeviceRegistry.knownDevices.map { spec in
            Device(
                productID: String(format: "0x%04X", spec.productID),
                name: spec.name,
                parser: spec.format.rawValue,
                confidence: String(describing: spec.confidence),
                productStringMatch: spec.productStringMatch,
                maxX: spec.maxX,
                maxY: spec.maxY,
                maxPressure: spec.maxPressure,
                buttonCount: spec.buttonCount,
                maxTouchContacts: spec.maxTouchContacts,
                touchMaxX: spec.touchMaxX,
                touchMaxY: spec.touchMaxY,
                hasTouchRing: spec.hasTouchRing,
                hasEraser: spec.hasEraser,
                hasFingerTouch: spec.hasFingerTouch,
                isPenDisplay: spec.isPenDisplay,
                seizeUSB: spec.seizeUSB,
                activeWidthMM: spec.activeWidthMM,
                activeHeightMM: spec.activeHeightMM,
                outOfScope: WacomEvidence.outOfScope[spec.productID])
        }
        return RegistrySnapshot(deviceCount: devices.count, devices: devices)
    }

    /// The file's contents, with sorted keys so every run writes the same bytes.
    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}
