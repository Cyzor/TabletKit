// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

// MARK: - TabletReportDecoder protocol

/// Link state reported by a wireless receiver.
public enum WirelessStatus: Sendable {
    /// A tablet is linked to the receiver.
    case active
    /// The link to the tablet has dropped.
    case lost
    /// The linked tablet reports a low battery.
    case lowBattery
    /// A status byte this decoder doesn't recognize, passed through.
    case unknown(UInt8)
}

/// What a decoder remembers between reports. Each decoder declares its own
/// `State` with just the fields it needs.
package protocol DecoderState: Sendable {
    init()
    /// Whether the last report had the pen in range.
    var prevInProximity: Bool { get }
    /// The device clock for each touch frame in the last report, in the
    /// order they were emitted. See ``TouchFrame/deviceTime``.
    var btTouchFrameStamps: [UInt16] { get }
}

extension DecoderState {
    package var prevInProximity: Bool { false }
    package var btTouchFrameStamps: [UInt16] { [] }
}

/// Consecutive weak frames after which a pen counts as having left. Bridges
/// brief dropouts at the edge of range, such as an Art Pen's rotation sensor
/// causes.
package let proximityExitFrames = 3

/// One slot of a wireless receiver's pairing table. `serial` is the remote's
/// own 24-bit identifier, the same one its event frames carry.
///
/// `connected` is stored pairing state, not a live radio heartbeat: it stays
/// set for a remote that is paired but asleep, so it answers "is this slot
/// claimed" rather than "is this remote awake".
public struct RemotePairingSlot: Sendable, Equatable {
    /// The slot's position in the receiver's table, from 0.
    public let index: Int
    /// The paired remote's 24-bit serial, or 0 for an empty slot.
    public let serial: UInt32
    /// Whether the slot holds a pairing.
    public let connected: Bool

    /// Creates a pairing-table entry.
    public init(index: Int, serial: UInt32, connected: Bool) {
        self.index = index
        self.serial = serial
        self.connected = connected
    }
}

/// One event decoded from a report. A single report can produce several,
/// such as a tool announcement and a pen sample, so always handle the whole
/// array a decoder returns.
package enum DecodeResult: Sendable {
    /// Nothing to report.
    case none
    /// A pen sample.
    case pen(TabletPoint)
    /// A tool came into range and identified itself.
    case toolEnter(ToolIdentity)
    /// ExpressKey, ring, or strip state.
    case aux(AuxButtons)
    /// A wireless receiver's link state changed.
    case wireless(WirelessStatus)
    /// Battery status from a BT device report.
    /// `percent` is 0–100 (direct, no lookup table). `charging` is true when the device is plugged in.
    case battery(percent: Int, charging: Bool)
    /// A wireless receiver's full pairing table, one entry per slot.
    /// Diagnostic only — nothing downstream acts on it; it lets a capture
    /// answer "is a remote actually paired here".
    case remotePairing([RemotePairingSlot])
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
    /// configure scroll vs. key-press behavior through the existing ring UI.
    case wheel(index: Int, delta: Int)
    /// Capacitive finger-touch contact frame.  One emission carries the full
    /// set of active contacts; an empty array signals "all fingers lifted".
    /// Coordinates are in the same device-units space as `TabletPoint`
    /// (decoder must scale to `spec.maxX`/`spec.maxY`).  See `TouchContact`.
    ///
    /// Emitted by `IntuosV2Decoder`'s BPT3-style per-family touch path and by
    /// `PrecisionTouchDecoder` for Cintiq Pro/DTH devices whose touch report
    /// `TabletInput` derives a decoder for at connect time. Devices with no recoverable touch coordinate maxima
    /// still emit nothing; see `WacomDeviceRegistry`'s `touchMaxX`/`touchMaxY`
    /// provenance comments for which devices those are.
    case touch([TouchContact])
}

/// A single capacitive contact point reported by a touch-capable Wacom display.
/// `id` is a per-contact tracking identifier reused across frames for the same
/// finger (typically 0–9 on 10-point devices). `contactArea` and
/// `contactMinor` are optional raw major/minor footprint axes. They are only
/// populated on devices that report those HID Digitizer usages.
///
/// Both producers agree on that quantity: `IntuosV2Decoder.decodeTouchReport`
/// takes report 0x21's per-slot Width/Height bytes, and
/// `PrecisionTouchDecoder` takes the HID Digitizer Width usage (0x0D/0x48).
/// Units still differ per device — these are raw sensor values, not normalized
/// ones, so any threshold tuned against them must be per-device.
public struct TouchContact: Equatable, Sendable {
    /// Tracking ID, stable for one finger across frames.
    public let id: Int
    /// X in the touch sensor's own units.
    public let x: Int
    /// Y in the touch sensor's own units.
    public let y: Int
    /// Contact width (major axis), raw; `nil` where not reported.
    public let contactArea: Int?
    /// Contact height (minor axis), raw; `nil` where not reported.
    public let contactMinor: Int?

    /// Creates a contact.
    public init(
        id: Int,
        x: Int,
        y: Int,
        contactArea: Int?,
        contactMinor: Int? = nil
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.contactArea = contactArea
        self.contactMinor = contactMinor
    }
}

/// One HID report family's decoder. Turns a raw input report into
/// `DecodeResult`s; anything it remembers between reports lives in the
/// decoder's own `State`, which its caller keeps. Apps use ``DeviceDecoder``,
/// which keeps both.
package protocol TabletReportDecoder: Sendable {
    associatedtype State: DecoderState

    /// Decode one raw HID report into zero or more results.
    mutating func decode(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult]

    /// How long without a report means the pen has left, or `nil` if the
    /// tablet says so itself.
    var silenceTimeout: TimeInterval? { get }

    /// What a silence of `silenceTimeout` means.
    mutating func decodeSilence(
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult]
}

extension TabletReportDecoder {
    package var silenceTimeout: TimeInterval? { nil }

    package mutating func decodeSilence(
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] { [] }
}

public struct BLEPenResult: Sendable {
    /// The pen sample.
    public let point: TabletPoint
    /// The pen's serial number.
    public let serial: UInt32
    /// The pen's tool code.
    public let toolCode: UInt16
    /// Whether the tool is a mouse.
    public let isMouse: Bool
}

// MARK: - Tool compatibility checking

/// Emit a toolCompatibility warning if the tool code is not fully supported on the device.
/// Updates `toolIsSupported` and appends `.toolCompatibility(msg)` to results if needed.
package func emitToolCompatibility(
    toolCode: UInt16,
    deviceFamily: DeviceFamily,
    toolIsSupported: inout Bool,
    results: inout [DecodeResult]
) {
    let caps = ToolCatalog.capabilities(forToolCode: toolCode, family: deviceFamily)
    toolIsSupported = caps.isSupported
    if !caps.isSupported {
        // These are the capabilities the tool lacks, not the ones it keeps.
        var missing: [String] = []
        if !caps.hasPressure { missing.append("pressure") }
        if !caps.hasTilt { missing.append("tilt") }
        if !caps.hasRotation { missing.append("rotation") }
        var msg = "Tool 0x\(String(format: "%04X", toolCode)) not fully supported on \(deviceFamily.rawValue)."
        if !missing.isEmpty {
            msg += " Missing: \(missing.joined(separator: ", "))"
        }
        results.append(.toolCompatibility(msg))
    }
}
