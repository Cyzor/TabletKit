// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One pen sample: position, pressure, tilt, rotation, and button state,
/// decoded from a single report or frame.
///
/// Values stay in the device's own units; normalize at the point where you
/// map them to a screen or canvas. See <doc:DecodingPenReports>.
public struct TabletPoint: Sendable {
    /// Raw digitizer X coordinate (device units)
    public var x: Int
    /// Raw digitizer Y coordinate (device units)
    public var y: Int
    /// Maximum X value in device units (device-specific)
    public var maxX: Int
    /// Maximum Y value in device units (device-specific)
    public var maxY: Int
    /// Pressure value, 0..maxPressure
    public var pressure: Int
    /// Maximum pressure value for this device (1023 for PTH-851, 8191 for PTH-860)
    public var maxPressure: Int
    /// Normalized pressure, 0.0..1.0
    public var normalizedPressure: Double { Double(pressure) / Double(maxPressure) }
    /// Tilt X, -1.0..1.0. Positive when the top of the pen leans right (east),
    /// the HID Digitizer X Tilt convention (usage 0x3D).
    public var tiltX: Double
    /// Tilt Y, -1.0..1.0. Positive when the top of the pen leans toward the
    /// user (south), the HID Digitizer Y Tilt convention (usage 0x3E).
    ///
    /// Both axes follow the HID Usage Tables definition, which is also what
    /// the W3C Pointer Events `tiltX`/`tiltY` use: X positive to the right, Y
    /// positive toward the user. Decoders pass the wire sign through
    /// unmodified; every device measured so far already reports in this
    /// convention, so no decoder negates.
    ///
    /// macOS is the odd one out. `NSEvent.tilt.y` is positive when the pen
    /// leans *away* from the user — Apple never documents this, but Chromium's
    /// macOS event builder negates `tilt.y` to reach the Pointer Events sign
    /// and says why. Consumers that build `CGEvent`s therefore negate Y once
    /// at their own boundary, not here; MockTab does this in
    /// `resolveEffectivePose`. Confirmed at the application on 2026-09-05: a
    /// Rebelle flat brush shows bristles on the correct side, in every
    /// direction, for Xencelabs and Wacom pens, and matches the vendor drivers.
    ///
    /// Do not re-derive this from an event-stream probe alone. Reading
    /// `NSEvent.tilt` under two drivers with two tablets attached produced
    /// contradictory signs for days; judge polarity at a brush that renders
    /// its own preview, with one tablet connected.
    public var tiltY: Double
    /// Pen rotation (twist), 0.0..360.0 degrees (approximate)
    public var rotation: Double = 0.0
    /// The pen's first side button (the lower one on most Wacom pens).
    public var penButton1: Bool
    /// The pen's second side button (the upper one on most Wacom pens).
    public var penButton2: Bool
    /// True while the eraser end is in range, hovering or touching, so apps
    /// can switch tools before contact.
    public var eraser: Bool
    /// False on the single point a decoder emits when the pen leaves range;
    /// that point repeats the last position. True otherwise.
    public var inProximity: Bool
    /// Height above the surface in the device's own units: smallest in
    /// contact, larger as the pen lifts. The range differs by family (0–63
    /// on Intuos Pro gen 2, up to 255 on gen 3, where 255 means at or past
    /// the edge of sensing); 0 where the format doesn't report it.
    public var hoverDistance: Int
    /// For mouse tools only: middle-button state.
    public var mouseMiddleButton: Bool = false
    /// For mouse tools only: scroll-wheel step this report (+1 up / -1 down / 0 none).
    public var mouseWheelDelta: Int = 0
    /// Extra barrel / mouse buttons beyond the standard two side buttons.
    public var penButton3: Bool = false
    /// A fourth pen or mouse button, where the tool has one.
    public var penButton4: Bool = false
    /// A fifth pen or mouse button, where the tool has one.
    public var penButton5: Bool = false
    /// Absolute airbrush fingerwheel position, 0–1023; nil for tools without
    /// one. Separate from `mouseWheelDelta`, which is a relative ±1 step.
    public var airbrushWheel: Int? = nil

    /// Creates a value with the given fields; optional ones default to absent.
    public init(
        x: Int,
        y: Int,
        maxX: Int,
        maxY: Int,
        pressure: Int,
        maxPressure: Int,
        tiltX: Double,
        tiltY: Double,
        rotation: Double = 0.0,
        penButton1: Bool,
        penButton2: Bool,
        eraser: Bool,
        inProximity: Bool,
        hoverDistance: Int,
        mouseMiddleButton: Bool = false,
        mouseWheelDelta: Int = 0,
        penButton3: Bool = false,
        penButton4: Bool = false,
        penButton5: Bool = false,
        airbrushWheel: Int? = nil
    ) {
        self.x = x
        self.y = y
        self.maxX = maxX
        self.maxY = maxY
        self.pressure = pressure
        self.maxPressure = maxPressure
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.rotation = rotation
        self.penButton1 = penButton1
        self.penButton2 = penButton2
        self.eraser = eraser
        self.inProximity = inProximity
        self.hoverDistance = hoverDistance
        self.mouseMiddleButton = mouseMiddleButton
        self.mouseWheelDelta = mouseWheelDelta
        self.penButton3 = penButton3
        self.penButton4 = penButton4
        self.penButton5 = penButton5
        self.airbrushWheel = airbrushWheel
    }
}

/// Identity of a physical pen as reported by the tablet firmware.
/// Fires once per `onToolEnter` callback whenever the active tool changes.
public struct ToolIdentity: Sendable {
    /// Unique 32-bit serial per physical pen body.  0 means not available (IntuosV1).
    public let serial: UInt32
    /// Wacom product code — e.g. 0x0802 Grip Pen, 0x0804 Art Pen, 0x0842 Pro Pen 2.
    public let toolCode: UInt16
    /// True for the eraser end: bit 3 of the tool code, except on Art Pen
    /// codes such as `0x1108` that set it on the tip.
    public let isEraser: Bool
    /// True for cordless mouse and cursor tools: tool codes whose low four
    /// bits are 6 (the KC-100 reports `0x0806`).
    public let isMouse: Bool

    /// Creates a value with the given fields; optional ones default to absent.
    public init(serial: UInt32, toolCode: UInt16, isEraser: Bool, isMouse: Bool) {
        self.serial = serial
        self.toolCode = toolCode
        self.isEraser = isEraser
        self.isMouse = isMouse
    }
}

/// ExpressKey, touch ring, dial, and touch strip state from one pad report.
///
/// Rings and strips report an absolute position while touched; dials and
/// wheels arrive separately as ``DecodeResult/wheel(index:delta:)``.
public struct AuxButtons: Sendable {
    /// Creates a pad state. Positions default to "no contact".
    public init(
        buttons: [Bool],
        mechanicalMask: UInt8 = 0,
        touchRingActive: Bool = false,
        touchRingButtonDown: Bool = false,
        touchRingPosition: UInt8 = 0x7F,
        touchRing2Active: Bool = false,
        touchRing2ButtonDown: Bool = false,
        touchRing2Position: UInt8 = 0x7F,
        touchStrip1Active: Bool = false,
        touchStrip1Position: UInt8 = 0xFF,
        touchStrip2Active: Bool = false,
        touchStrip2Position: UInt8 = 0xFF
    ) {
        self.buttons = buttons
        self.mechanicalMask = mechanicalMask
        self.touchRingActive = touchRingActive
        self.touchRingButtonDown = touchRingButtonDown
        self.touchRingPosition = touchRingPosition
        self.touchRing2Active = touchRing2Active
        self.touchRing2ButtonDown = touchRing2ButtonDown
        self.touchRing2Position = touchRing2Position
        self.touchStrip1Active = touchStrip1Active
        self.touchStrip1Position = touchStrip1Position
        self.touchStrip2Active = touchStrip2Active
        self.touchStrip2Position = touchStrip2Position
    }

    /// ExpressKeys in device order, `true` while held. Some devices report
    /// more than eight; index past the end reads as released.
    public var buttons: [Bool]
    /// Bitmask of buttons that had a new mechanical press pulse this frame.
    /// Bit N corresponds to buttons[N].  Set even when the synthesized button state
    /// is unchanged (e.g. rapid re-press before the previous release was detected).
    /// Used by injectAux to force an up→down cycle so rapid same-key presses are
    /// never swallowed by the injector's transition guard.
    public var mechanicalMask: UInt8 = 0
    /// True while a finger is resting on the touch ring (position is valid).
    public var touchRingActive: Bool = false
    /// True while the center click button of the touch ring is physically pressed.
    public var touchRingButtonDown: Bool = false
    /// Absolute touch ring position, 0–71 (5° resolution).  0x7F = idle/no contact.
    public var touchRingPosition: UInt8 = 0x7F
    /// Second touch ring (DTK-2400 right bezel).  Same encoding as touchRingPosition.
    public var touchRing2Active: Bool = false
    /// True while the second ring/dial's own center-cluster toggle button is
    /// physically pressed. PTK-670/870 (Intuos Pro gen 3 M/L): each of the
    /// two mechanical dials has its own toggle key (the center key of its
    /// express-key cluster) — this is not the same signal as
    /// `touchRing2Active` (finger presence on a capacitive ring), which this
    /// hardware has no equivalent of. See `IntuosV3Decoder.decodeAuxReport`.
    public var touchRing2ButtonDown: Bool = false
    /// Second ring position, same encoding as `touchRingPosition`.
    public var touchRing2Position: UInt8 = 0x7F
    /// True while a finger is on the left touch strip (Intuos3 WS).
    public var touchStrip1Active: Bool = false
    /// Left strip position: 0 is the bottom zone, higher is farther up;
    /// `0xFF` with no contact.
    public var touchStrip1Position: UInt8 = 0xFF
    /// True while a finger is on the right touch strip.
    public var touchStrip2Active: Bool = false
    /// Right strip position, same encoding as `touchStrip1Position`.
    public var touchStrip2Position: UInt8 = 0xFF
    /// Active ring mode, 0-based, on hardware whose own firmware switches
    /// modes (ExpressKey Remote). `nil` where the host owns the mode.
    public var touchRingHardwareMode: Int? = nil

    public subscript(index: Int) -> Bool {
        guard index < buttons.count else { return false }
        return buttons[index]
    }
}

/// Snapshot of which hardware buttons are currently held down.
/// Published by TabletManager so the Buttons pane can light up rows
/// in real time, like a keyboard viewer for the tablet.
public struct LiveButtonState: Equatable, Sendable {
    /// Pen tip pressed (non-eraser end).
    public var tipDown: Bool = false
    /// Eraser tip pressed.
    public var eraserDown: Bool = false
    /// Side button 1 held.
    public var button1Down: Bool = false
    /// Side button 2 held.
    public var button2Down: Bool = false
    /// Extra button 3 held (mice and multi-button pens).
    public var button3Down: Bool = false
    /// Extra button 4 held.
    public var button4Down: Bool = false
    /// Extra button 5 held.
    public var button5Down: Bool = false
    /// Express-key live state. Sized to 16 (the storage cap shared with
    /// `TabletSettings.expressKeyBindings`); per-device, only the first
    /// `spec.buttonCount` entries are physically meaningful.
    public var expressKeys: [Bool] = Array(repeating: false, count: 16)
    /// Live state of a device's own onboard bezel buttons (e.g. the Cintiq
    /// DTK-2400's capacitive OSD buttons), kept separate from `expressKeys`
    /// since some devices already use all 16 of those slots.
    public var bezelButtons: [Bool] = Array(repeating: false, count: 3)
    /// True while a finger is actively touching the touch ring.
    public var touchRingActive: Bool = false
    /// True while the touch ring center button is physically pressed.
    public var touchRingButtonDown: Bool = false
    /// Second touch ring (DTK-2400 right bezel).
    public var touchRing2Active: Bool = false
    /// True while the second dial's own toggle key is physically pressed
    /// (PTK-670/870's right cluster center ExpressKey). Unused elsewhere.
    public var touchRing2ButtonDown: Bool = false
    /// True while a finger is on the left touch strip (Intuos3 WS).
    public var touchStrip1Active: Bool = false
    /// True while a finger is on the right touch strip.
    public var touchStrip2Active: Bool = false

    /// Creates a value with the given fields; optional ones default to absent.
    public init(
        tipDown: Bool = false,
        eraserDown: Bool = false,
        button1Down: Bool = false,
        button2Down: Bool = false,
        button3Down: Bool = false,
        button4Down: Bool = false,
        button5Down: Bool = false,
        expressKeys: [Bool] = Array(repeating: false, count: 16),
        bezelButtons: [Bool] = Array(repeating: false, count: 3),
        touchRingActive: Bool = false,
        touchRingButtonDown: Bool = false,
        touchRing2Active: Bool = false,
        touchRing2ButtonDown: Bool = false,
        touchStrip1Active: Bool = false,
        touchStrip2Active: Bool = false
    ) {
        self.tipDown = tipDown
        self.eraserDown = eraserDown
        self.button1Down = button1Down
        self.button2Down = button2Down
        self.button3Down = button3Down
        self.button4Down = button4Down
        self.button5Down = button5Down
        self.expressKeys = expressKeys
        self.bezelButtons = bezelButtons
        self.touchRingActive = touchRingActive
        self.touchRingButtonDown = touchRingButtonDown
        self.touchRing2Active = touchRing2Active
        self.touchRing2ButtonDown = touchRing2ButtonDown
        self.touchStrip1Active = touchStrip1Active
        self.touchStrip2Active = touchStrip2Active
    }
}
