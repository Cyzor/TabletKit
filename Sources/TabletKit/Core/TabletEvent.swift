// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One thing a tablet did. A report can produce several, so handle every
/// event ``DeviceDecoder/events(_:)`` returns, in order.
///
/// The input cases are fixed. Everything else arrives as ``device(_:)``,
/// which grows without breaking a `switch`.
public enum TabletEvent: Sendable {
    case pen(TabletPoint)
    case tool(ToolEvent)
    case pad(PadState)
    /// A dial or wheel turned `delta` detents; positive is clockwise.
    case dial(index: Int, delta: Int)
    case touch(TouchFrame)
    case device(DeviceEvent)
}

/// A tool coming into range or leaving it.
public struct ToolEvent: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case enter, leave }
    public var identity: ToolIdentity
    public var phase: Phase

    public init(identity: ToolIdentity, phase: Phase) {
        self.identity = identity
        self.phase = phase
    }
}

/// The tablet's own controls, as of this report.
public struct PadState: Sendable, Equatable {
    /// Buttons in device order, `true` while held.
    public var buttons: [Bool]
    /// Buttons with a new physical press this report, even if they still
    /// read as held, so a quick re-press isn't lost.
    public var pressedThisReport: IndexSet
    public var rings: [RingState]
    public var strips: [StripState]
    /// The active mode on hardware whose own firmware switches modes
    /// (ExpressKey Remote); `nil` where the host owns the mode.
    public var hardwareMode: Int?

    public init(
        buttons: [Bool], pressedThisReport: IndexSet = [], rings: [RingState] = [],
        strips: [StripState] = [], hardwareMode: Int? = nil
    ) {
        self.buttons = buttons
        self.pressedThisReport = pressedThisReport
        self.rings = rings
        self.strips = strips
        self.hardwareMode = hardwareMode
    }
}

public struct RingState: Sendable, Equatable {
    /// Finger position in the ring's raw steps, or `nil` with no finger.
    public var position: Int?
    /// The ring's center button.
    public var buttonDown: Bool

    public init(position: Int?, buttonDown: Bool) {
        self.position = position
        self.buttonDown = buttonDown
    }
}

public struct StripState: Sendable, Equatable {
    /// Finger position in the strip's raw steps, or `nil` with no finger.
    public var position: Int?

    public init(position: Int?) { self.position = position }
}

/// Finger contacts at one moment.
public struct TouchFrame: Sendable, Equatable {
    /// Every contact on the surface; empty when all fingers lifted.
    public var contacts: [TouchContact]
    /// The tablet's own clock for this frame, in 0.1 ms counts, where it
    /// sends one (Bluetooth batches). Wraps every 6.55 s, so compare only
    /// frames from the same report.
    public var deviceTime: UInt16?

    public init(contacts: [TouchContact], deviceTime: UInt16? = nil) {
        self.contacts = contacts
        self.deviceTime = deviceTime
    }

    /// Milliseconds per count of ``deviceTime``.
    public static let deviceTimeMsPerCount = 0.1
    /// Counts between consecutive frames in one Bluetooth report (10 ms),
    /// measured on a PTH-660.
    public static let deviceTimeCountsPerBluetoothFrame = 100
}

/// Anything a tablet reports besides input. New kinds are additions, so
/// check ``kind`` and read the matching accessor.
public struct DeviceEvent: Sendable {
    public struct Kind: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let battery = Kind(rawValue: "battery")
        public static let wireless = Kind(rawValue: "wireless")
        public static let remotePairing = Kind(rawValue: "remotePairing")
        public static let toolSupport = Kind(rawValue: "toolSupport")
        public static let mouseButtons = Kind(rawValue: "mouseButtons")
    }

    public struct Battery: Sendable, Equatable {
        public var percent: Int
        public var charging: Bool
    }

    public let kind: Kind
    public private(set) var battery: Battery?
    public private(set) var wireless: WirelessStatus?
    public private(set) var remotePairing: [RemotePairingSlot]?
    /// Why the tool in range isn't fully supported on this tablet.
    public private(set) var unsupportedToolNote: String?
    /// The Intuos mouse's extra buttons, one bit each.
    public private(set) var mouseButtons: UInt8?

    init(kind: Kind) { self.kind = kind }

    public static func battery(percent: Int, charging: Bool) -> DeviceEvent {
        var e = DeviceEvent(kind: .battery)
        e.battery = Battery(percent: percent, charging: charging)
        return e
    }
    public static func wireless(_ status: WirelessStatus) -> DeviceEvent {
        var e = DeviceEvent(kind: .wireless)
        e.wireless = status
        return e
    }
    public static func remotePairing(_ slots: [RemotePairingSlot]) -> DeviceEvent {
        var e = DeviceEvent(kind: .remotePairing)
        e.remotePairing = slots
        return e
    }
    public static func toolSupport(note: String) -> DeviceEvent {
        var e = DeviceEvent(kind: .toolSupport)
        e.unsupportedToolNote = note
        return e
    }
    public static func mouseButtons(_ bits: UInt8) -> DeviceEvent {
        var e = DeviceEvent(kind: .mouseButtons)
        e.mouseButtons = bits
        return e
    }
}

// MARK: - From DecodeResult

/// How many rings and strips a tablet's pad has.
struct PadShape: Sendable {
    var rings: Int
    var strips: Int

    init(rings: Int, strips: Int) {
        self.rings = rings
        self.strips = strips
    }

    init(spec: TabletSpec) {
        rings = spec.hasDualRings ? 2 : (spec.hasTouchRing || spec.hasMechanicalDial ? 1 : 0)
        strips = spec.hasTouchStrips ? 2 : 0
    }
}

extension PadState {
    /// The pad in `aux`, listing the rings and strips it uses.
    public init(_ aux: AuxButtons) {
        self.init(aux, shape: PadShape(rings: 0, strips: 0))
    }

    /// The pad in `aux`, with at least the rings and strips `shape` names,
    /// and more if the report uses them.
    init(_ aux: AuxButtons, shape: PadShape) {
        let ring1 = RingState(
            position: aux.touchRingActive && aux.touchRingPosition != 0x7F ? Int(aux.touchRingPosition) : nil,
            buttonDown: aux.touchRingButtonDown)
        let ring2 = RingState(
            position: aux.touchRing2Active && aux.touchRing2Position != 0x7F ? Int(aux.touchRing2Position) : nil,
            buttonDown: aux.touchRing2ButtonDown)
        let strip1 = StripState(
            position: aux.touchStrip1Active && aux.touchStrip1Position != 0xFF ? Int(aux.touchStrip1Position) : nil)
        let strip2 = StripState(
            position: aux.touchStrip2Active && aux.touchStrip2Position != 0xFF ? Int(aux.touchStrip2Position) : nil)

        let idleRing = RingState(position: nil, buttonDown: false)
        let ringCount = max(shape.rings, ring2 != idleRing ? 2 : ring1 != idleRing ? 1 : 0)
        let stripCount = max(shape.strips, strip2.position != nil ? 2 : strip1.position != nil ? 1 : 0)

        self.init(
            buttons: aux.buttons,
            pressedThisReport: IndexSet((0..<8).filter { aux.mechanicalMask & (1 << $0) != 0 }),
            rings: Array([ring1, ring2].prefix(min(ringCount, 2))),
            strips: Array([strip1, strip2].prefix(min(stripCount, 2))),
            hardwareMode: aux.touchRingHardwareMode)
    }
}
