// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

/// An 8-bit-per-channel color for device LEDs.
public struct LEDColor: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// The hardware a connected device lets the host set. Each slot is `nil`
/// when the device has no such hardware, so callers can ask instead of
/// sending writes that do nothing.
///
/// Every control method runs on the thread that delivers the device's
/// reports. A device's controls are fixed once it opens, except when a
/// wireless receiver learns which tablet is paired to it.
public struct TabletControls {
    public var ringLED: (any RingLEDControl)?
    public var labels: (any LabelControl)?
    public var displayPanel: (any DisplayPanelControl)?
    public var quickKeys: (any QuickKeysControl)?

    public init(
        ringLED: (any RingLEDControl)? = nil,
        labels: (any LabelControl)? = nil,
        displayPanel: (any DisplayPanelControl)? = nil,
        quickKeys: (any QuickKeysControl)? = nil
    ) {
        self.ringLED = ringLED
        self.labels = labels
        self.displayPanel = displayPanel
        self.quickKeys = quickKeys
    }
}

/// A touch ring's or dial's mode LEDs.
public protocol RingLEDControl: AnyObject {
    /// Light the LED for the active mode slot (0-based).
    func setRingLED(index: Int)
    /// Per-slot colors for an RGB LED; `nil` entries use the device's
    /// factory palette. Devices with single-color LEDs ignore this.
    func setRingLEDColors(_ colors: [LEDColor?])
    /// Light the second ring's LED, on tablets with two rings that light
    /// independently (Cintiq 24HD).
    func setRingLED2(index: Int)
}

extension RingLEDControl {
    public func setRingLED2(index: Int) {}
}

/// On-device text: the active ring or dial mode's name, and per-key labels.
public protocol LabelControl: AnyObject {
    func setRingModeLabel(_ label: String)
    /// `labels[0]` is key 1.
    func setAuxKeyLabels(_ labels: [String])
    /// Turn the key displays' images 180°, for a tablet used upside down
    /// (Intuos4).
    func setKeyOLEDsRotated180(_ rotated: Bool)
}

extension LabelControl {
    public func setKeyOLEDsRotated180(_ rotated: Bool) {}
}

/// A pen display's own panel settings, set over HID.
public protocol DisplayPanelControl: AnyObject {
    /// Backlight brightness, 0–100.
    func setDisplayBrightness(_ percent: Int)
    /// Contrast, 0–100.
    func setDisplayContrast(_ percent: Int)
    /// Gamma × 10 (22 = 2.2).
    func setDisplayGamma(_ gammaTimesTen: Int)
    /// A color-space preset, by the device's row index.
    func setColorMode(_ index: Int)
    /// The backlight behind the onboard bezel buttons. It has no brightness
    /// register, so premultiply brightness into the color.
    func setBezelLEDColor(_ color: LEDColor)
}

/// Settings specific to the Xencelabs Quick Keys remote.
public protocol QuickKeysControl: AnyObject {
    /// OLED text orientation in 90° steps (0 = upright).
    func setQuickKeysOrientation(steps: Int)
    /// Auto-sleep timer in minutes (0 = never).
    func setQuickKeysSleepMinutes(_ minutes: Int)
    /// OLED brightness, 0 (off) through 3.
    func setQuickKeysOledBrightness(_ level: Int)
}
