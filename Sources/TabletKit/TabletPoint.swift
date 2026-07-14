// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

public struct TabletPoint {
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
    /// Tilt X, -1.0..1.0
    public var tiltX: Double
    /// Tilt Y, -1.0..1.0
    public var tiltY: Double
    /// Pen rotation (twist), 0.0..360.0 degrees (approximate)
    public var rotation: Double = 0.0
    public var penButton1: Bool
    public var penButton2: Bool
    public var eraser: Bool
    public var inProximity: Bool
    public var hoverDistance: Int
    /// For mouse tools only: middle-button state.
    public var mouseMiddleButton: Bool = false
    /// For mouse tools only: scroll-wheel step this report (+1 up / -1 down / 0 none).
    public var mouseWheelDelta: Int = 0
    /// Extra barrel / mouse buttons beyond the standard two side buttons.
    public var penButton3: Bool = false
    public var penButton4: Bool = false
    public var penButton5: Bool = false

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
        penButton5: Bool = false
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
    }
}

/// Identity of a physical pen as reported by the tablet firmware.
/// Fires once per `onToolEnter` callback whenever the active tool changes.
public struct ToolIdentity {
    /// Unique 32-bit serial per physical pen body.  0 means not available (IntuosV1).
    public let serial: UInt32
    /// Wacom product code — e.g. 0x0802 Grip Pen, 0x0832 Pro Pen 2, 0x0842 Pro Pen 3.
    public let toolCode: UInt16
    /// True for the eraser end.  Derived from toolCode: bit 3 of the low byte is set.
    public let isEraser: Bool
    /// True for cordless mouse / cursor accessories (Intuos Mouse).
    /// On IntuosV2 devices: detected by the absence of the pen bit (0x0800) in toolCode.
    public let isMouse: Bool

    public init(serial: UInt32, toolCode: UInt16, isEraser: Bool, isMouse: Bool) {
        self.serial = serial
        self.toolCode = toolCode
        self.isEraser = isEraser
        self.isMouse = isMouse
    }
}

public struct AuxButtons {
    public init(
        buttons: [Bool],
        mechanicalMask: UInt8 = 0,
        touchRingActive: Bool = false,
        touchRingButtonDown: Bool = false,
        touchRingPosition: UInt8 = 0x7F,
        touchRing2Active: Bool = false,
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
        self.touchRing2Position = touchRing2Position
        self.touchStrip1Active = touchStrip1Active
        self.touchStrip1Position = touchStrip1Position
        self.touchStrip2Active = touchStrip2Active
        self.touchStrip2Position = touchStrip2Position
    }

    public var buttons: [Bool]  // up to 8 express key buttons
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
    public var touchRing2Position: UInt8 = 0x7F
    /// Intuos3 WS left touch strip.  0xFF = no contact; 0 = bottom zone, higher = up.
    public var touchStrip1Active: Bool = false
    public var touchStrip1Position: UInt8 = 0xFF
    /// Intuos3 WS right touch strip.  Same encoding as strip 1.
    public var touchStrip2Active: Bool = false
    public var touchStrip2Position: UInt8 = 0xFF

    public subscript(index: Int) -> Bool {
        guard index < buttons.count else { return false }
        return buttons[index]
    }
}

/// Snapshot of which hardware buttons are currently held down.
/// Published by TabletManager so the Buttons pane can light up rows
/// in real time, like a keyboard viewer for the tablet.
public struct LiveButtonState: Equatable {
    /// Pen tip pressed (non-eraser end).
    public var tipDown: Bool = false
    /// Eraser tip pressed.
    public var eraserDown: Bool = false
    /// Side button 1 held.
    public var button1Down: Bool = false
    /// Side button 2 held.
    public var button2Down: Bool = false
    /// Extra buttons 3–5 (mice or future multi-button pens).
    public var button3Down: Bool = false
    public var button4Down: Bool = false
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
    /// Intuos3 WS touch strip states (0xFF = no contact, otherwise 0–12 zone).
    public var touchStrip1Active: Bool = false
    public var touchStrip2Active: Bool = false

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
        self.touchStrip1Active = touchStrip1Active
        self.touchStrip2Active = touchStrip2Active
    }
}
