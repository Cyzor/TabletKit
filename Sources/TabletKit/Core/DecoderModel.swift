// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

// MARK: - TabletReportDecoder protocol

public enum WirelessStatus {
    case active
    case lost
    case lowBattery
    case unknown(UInt8)
}

/// All mutable state shared between reports for a single decoder session.
/// Passed `inout` through every `decode` call so decoders can be pure structs.
public struct DecoderState {
    public var lastX: Int = 0
    public var lastY: Int = 0
    /// Serial number at the last tool-identity change.
    public var lastSerial: UInt32 = 0
    /// Tool code at the last tool-identity change (V2 change detection).
    public var lastToolCode: UInt16 = 0
    /// Currently active tool code.
    public var currentToolCode: UInt16 = 0
    /// Absolute scroll-position counter for mouse-tool reports (V2).
    public var lastScrollPos: UInt8 = 0
    public var prevInProximity: Bool = false
    public var isEraser: Bool = false
    public var toolIsMouse: Bool = false
    /// Active finger contacts for the BPT3 touch container (IntuosV1 path,
    /// CTH-690). Keyed by slot ID; containers carry only changed contacts,
    /// so the full active set lives here between reports.
    public var bpt3TouchSlots: [Int: TouchContact] = [:]
    /// BT 0x80 container pad state — emit aux only on change.
    public var lastBTPadKeys: UInt8 = 0
    public var lastBTPadRing: UInt8 = 0x7F
    public var lastBTPadBtn: UInt8 = 0
    /// Consecutive frames/reports with low-confidence or out-of-range signal.
    /// Exit proximity only after this reaches exitThreshold, bridging transient
    /// boundary oscillations (confirmed: Art Pen rotation sensor causes these).
    /// Reset to 0 on any valid in-proximity frame.
    public var exitFrameCount: Int = 0
    public static let exitThreshold = 3
    /// Whether the current tool is supported on this device family.
    /// Used to show UI warnings for incompatible tools and adjust feature decoding.
    public var toolIsSupported: Bool = true
    /// Last valid rotation reading (Art Pen). Used to hold state during boundary-noise
    /// frames where !highConfidence (USB) or !inRange (BT). Reset to 0.0 on proximity exit.
    public var lastRotation: Double = 0.0
    /// True once at least one valid rotation frame has been decoded since tool-enter.
    /// Prevents emitting stale 0.0 during boundary oscillations at re-entry.
    public var hasValidRotationFrame: Bool = false
    public var hasValidTiltFrame: Bool = false
    /// Last valid tilt readings. Used to hold state during boundary-noise frames
    /// where !highConfidence (USB) or !inRange (BT) so that apps receive a continuous
    /// azimuth angle rather than a zero-snapped value on every low-confidence frame.
    /// Reset to 0.0 on proximity exit alongside lastRotation.
    public var lastTiltX: Double = 0.0
    public var lastTiltY: Double = 0.0
    /// Last raw battery byte seen (INTUOSP2_BT 361-byte path). 0xFF = not yet received.
    /// Used to suppress redundant .battery emissions on every pen report.
    public var lastBatteryByte: UInt8 = 0xFF
    public init() {}
}

public enum DecodeResult {
    case none
    case pen(TabletPoint)
    case toolEnter(ToolIdentity)
    case aux(AuxButtons)
    case wireless(WirelessStatus)
    /// Battery status from a BT device report.
    /// `percent` is 0–100 (direct, no lookup table). `charging` is true when the device is plugged in.
    case battery(percent: Int, charging: Bool)
    /// Tool compatibility warning: tool is present but not fully supported on this device.
    /// The associated string describes the limitation (e.g., "Rotation not supported").
    case toolCompatibility(String)
    /// Standard USB HID mouse report (Report ID 0x01, 4 bytes) from the mouse
    /// interface (usagePage=0x01) of an Intuos Pro tablet. Carries button state only;
    /// absolute position is delivered separately via the digitizer 0x10 stream.
    /// bit0 = left, bit1 = right, bit2 = middle.
    case mouseButton(UInt8)
    /// Relative-encoder wheel step from a device with physical scroll wheels
    /// (e.g. PTK-470/670/870 IntuosV3 side wheels).  `index` identifies the
    /// wheel (0 = left, 1 = right); `delta` is the signed per-frame step count
    /// (positive = clockwise / up, negative = counter-clockwise / down).
    /// Routed through `touchRingSlots[index]` in InputInjector so the user can
    /// configure scroll vs. key-press behaviour through the existing ring UI.
    case wheel(index: Int, delta: Int)
    /// Capacitive finger-touch contact frame.  One emission carries the full
    /// set of active contacts; an empty array signals "all fingers lifted".
    /// Coordinates are in the same device-units space as `TabletPoint`
    /// (decoder must scale to `spec.maxX`/`spec.maxY`).  See `TouchContact`.
    ///
    /// Currently emitted by no shipping decoder — Phase 1 plumbing for
    /// Cintiq Pro 27 (DTH-271), Movink 13 (DTH-135), Cintiq 16 (DTH-1320),
    /// Cintiq 24HD Touch (DTH-2400), Cintiq 22HD Touch (DTH-2200) once a
    /// real capture confirms the per-family byte layout.
    case touch([TouchContact])
}

/// A single capacitive contact point reported by a touch-capable Wacom display.
/// `id` is a per-contact tracking identifier reused across frames for the same
/// finger (typically 0–9 on 10-point devices).  `contactArea` is optional and
/// only populated on devices that report contact-major.
///
/// Both producers agree on that quantity: `IntuosV2Decoder.decodeTouchReport`
/// takes report 0x21's per-slot major byte, and `PrecisionTouchDecoder` takes
/// the HID Digitizer Width usage (0x0D/0x48), which is the major axis in that
/// usage set.  Units still differ per device — this is a raw sensor value, not
/// a normalized one, so any threshold tuned against it must be per-device.
public struct TouchContact: Equatable {
    public let id: Int
    public let x: Int
    public let y: Int
    public let contactArea: Int?

    public init(id: Int, x: Int, y: Int, contactArea: Int?) {
        self.id = id
        self.x = x
        self.y = y
        self.contactArea = contactArea
    }
}

/// Vendor-neutral decoder protocol.  One per HID report family.
///
/// G3 publish surface for the `TabletKit` Swift package.  Implementors translate
/// a raw HID input report into a sequence of high-level `DecodeResult` events.
/// Stateless across calls except for the `inout DecoderState` the host owns.
public protocol TabletReportDecoder {
    /// Decode one raw HID report into zero or more results.
    /// Mutating to allow decoder structs with their own cached state if needed.
    /// - Parameter deviceFamily: The device family string (e.g., "intuosProGen2", "cintiq")
    ///   used to check tool compatibility and adjust feature decoding.
    mutating func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult]
}

/// Decoded BLE HOGP pen report. See `decodeBLEPenReport` for the wire layout.
public struct BLEPenResult {
    public let point: TabletPoint
    public let serial: UInt32
    public let toolCode: UInt16
    public let isMouse: Bool
}

// MARK: - Tool compatibility checking

/// Emit a toolCompatibility warning if the tool code is not fully supported on the device.
/// Updates `state.toolIsSupported` and appends `.toolCompatibility(msg)` to results if needed.
public func emitToolCompatibility(
    toolCode: UInt16,
    deviceFamily: String,
    state: inout DecoderState,
    results: inout [DecodeResult]
) {
    let caps = WacomToolCatalog.capabilities(forToolCode: toolCode, family: deviceFamily)
    state.toolIsSupported = caps.isSupported
    if !caps.isSupported {
        var limitations: [String] = []
        if !caps.hasPressure { limitations.append("pressure") }
        if !caps.hasTilt { limitations.append("tilt") }
        if !caps.hasRotation { limitations.append("rotation") }
        let msg = "Tool 0x\(String(format: "%04X", toolCode)) not fully supported on \(deviceFamily). Limited to: \(limitations.joined(separator: ", "))"
        results.append(.toolCompatibility(msg))
    }
}
