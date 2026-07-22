// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

// MARK: - Tool Type

/// Categories of tools Wacom devices can report.
public enum WacomToolType: String, Codable, CaseIterable {
    case stylus = "Stylus"
    case eraser = "Eraser"
    case mouse = "Mouse"
    case touch = "Touch"
    case airbrush = "Airbrush"
    case artPen = "Art Pen"
    case inkingPen = "Inking Pen"
}

// MARK: - Tool Specification

/// Complete specification for a Wacom tool type.
/// Derived from OpenTabletDriver conventions and Linux input-wacom driver.
public struct WacomToolSpec: Codable, Identifiable, Equatable {
    /// The 16-bit Wacom tool code (e.g., 0x0802 for Grip Pen).
    public let toolCode: UInt16

    /// Human-readable name (e.g., "Grip Pen", "Pro Pen 2").
    public let name: String

    /// Category of tool.
    public let toolType: WacomToolType

    /// Number of side buttons on the pen body.
    public let buttonCount: Int

    /// Maximum pressure levels (nil = device-dependent).
    public let maxPressure: Int?

    /// True if this tool reports tilt data.
    public let hasTilt: Bool

    /// True if this tool supports rotation (twist) data.
    public let hasRotation: Bool

    /// True if this tool has a scroll wheel (mice only).
    public let hasWheel: Bool

    /// True if this tool has an eraser counterpart.
    public let hasEraserVariant: Bool

    /// Tool code for the eraser variant (if different from toolCode).
    public let eraserToolCode: UInt16?

    /// Device families this tool is commonly shipped with.
    /// Empty means universal.
    public let supportedFamilies: [String]

    public init(
        toolCode: UInt16,
        name: String,
        toolType: WacomToolType,
        buttonCount: Int,
        maxPressure: Int?,
        hasTilt: Bool,
        hasRotation: Bool,
        hasWheel: Bool,
        hasEraserVariant: Bool,
        eraserToolCode: UInt16?,
        supportedFamilies: [String]
    ) {
        self.toolCode = toolCode
        self.name = name
        self.toolType = toolType
        self.buttonCount = buttonCount
        self.maxPressure = maxPressure
        self.hasTilt = hasTilt
        self.hasRotation = hasRotation
        self.hasWheel = hasWheel
        self.hasEraserVariant = hasEraserVariant
        self.eraserToolCode = eraserToolCode
        self.supportedFamilies = supportedFamilies
    }

    /// Unique identifier (hex string matching toolCode).
    public var id: String { String(format: "0x%04X", toolCode) }

    /// Returns the tool code with eraser bit set (bit 3 of low byte).
    public var eraserCode: UInt16 { toolCode | 0x0008 }

    /// Returns true if this is an eraser tool.
    public var isEraser: Bool { toolType == .eraser }

    /// Returns true if this is a mouse/cursor tool.
    public var isMouse: Bool { toolType == .mouse }

    /// Returns the base tool code without eraser bit.
    public var baseCode: UInt16 { toolCode & ~UInt16(0x0008) }

    /// Returns true if this tool is compatible with the given device family.
    /// Empty supportedFamilies means universal compatibility.
    public func isSupported(onFamily family: String) -> Bool {
        if supportedFamilies.isEmpty { return true }
        return supportedFamilies.contains(family)
    }

    /// Returns the tool's capabilities adjusted for the given device family.
    /// If the tool is unsupported, returns a fallback with limited features.
    public func capabilities(forFamily family: String) -> ToolCapabilities {
        let supported = isSupported(onFamily: family)
        return ToolCapabilities(
            isSupported: supported,
            hasPressure: supported && (maxPressure ?? 0) > 0,
            hasTilt: supported && hasTilt,
            hasRotation: supported && hasRotation,
            hasWheel: supported && hasWheel,
            // If unsupported, fall back to basic position + buttons only
            maxPressure: supported ? (maxPressure ?? 2047) : 0
        )
    }
}

/// Capabilities of a tool on a specific device family.
/// Returned by WacomToolSpec.capabilities(forFamily:) to indicate which
/// features are available when a tool is used with an incompatible tablet.
public struct ToolCapabilities {
    /// True if this tool is officially supported on this device family.
    public let isSupported: Bool
    /// True if pressure data is available.
    public let hasPressure: Bool
    /// True if tilt data is available.
    public let hasTilt: Bool
    /// True if rotation data is available (Art Pen).
    public let hasRotation: Bool
    /// True if the scroll wheel is available.
    public let hasWheel: Bool
    /// Maximum pressure value (0 if pressure unsupported).
    public let maxPressure: Int
}

// MARK: - ToolIdentity Extension

public extension ToolIdentity {
    /// Creates a ToolIdentity from a WacomToolSpec.
    public init(spec: WacomToolSpec, serial: UInt32) {
        self.serial = serial
        self.toolCode = spec.toolCode
        self.isEraser = spec.isEraser
        self.isMouse = spec.isMouse
    }

    /// Returns the corresponding WacomToolSpec if available.
    public var toolSpec: WacomToolSpec? {
        return WacomToolCatalog.spec(forToolCodeRaw: toolCode)
    }

    /// Returns the human-readable name for this tool.
    public var displayName: String {
        return WacomToolCatalog.name(forToolCode: toolCode)
    }
}
