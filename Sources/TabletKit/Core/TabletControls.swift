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
    public var wirelessKit: (any WirelessKitControl)?

    public init(
        ringLED: (any RingLEDControl)? = nil,
        labels: (any LabelControl)? = nil,
        displayPanel: (any DisplayPanelControl)? = nil,
        quickKeys: (any QuickKeysControl)? = nil,
        wirelessKit: (any WirelessKitControl)? = nil
    ) {
        self.ringLED = ringLED
        self.labels = labels
        self.displayPanel = displayPanel
        self.quickKeys = quickKeys
        self.wirelessKit = wirelessKit
    }
}

extension TabletControls {
    /// Which slots a device fills, known without the device.
    public struct Kinds: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let ringLED = Kinds(rawValue: 1 << 0)
        public static let labels = Kinds(rawValue: 1 << 1)
        public static let displayPanel = Kinds(rawValue: 1 << 2)
        public static let quickKeys = Kinds(rawValue: 1 << 3)
        /// Offered by a model that runs on the Wacom wireless kit, and live
        /// only while it does.
        public static let wirelessKit = Kinds(rawValue: 1 << 4)
    }
}

extension TabletSpec {
    /// The controls a tablet of this model offers once connected, from the
    /// spec alone, so a host can show them, grayed out, while it's unplugged.
    /// The wireless kit's fill only while the tablet runs on its receiver.
    public var offeredControls: TabletControls.Kinds {
        var kinds: TabletControls.Kinds = []
        // The 21UX2's strips show their modes on LEDs like a ring's.
        if Self.ringLEDFormats.contains(format) && (hasTouchRing || hasMechanicalDial || hasTouchStrips) {
            kinds.insert(.ringLED)
        }
        if format == .xencelabs || hasKeyOLEDs { kinds.insert(.labels) }
        if format == .xencelabs && isPenDisplay { kinds.insert(.displayPanel) }
        if format == .xencelabs { kinds.insert(.quickKeys) }
        if Self.wirelessKitProductIDs.contains(productID) { kinds.insert(.wirelessKit) }
        return kinds
    }

    /// Intuos5 and Intuos Pro gen 1, which run on the ACK-40401 wireless kit,
    /// and the kit's receiver itself.
    static let wirelessKitProductIDs: Set<Int> = [
        0x0026, 0x0027, 0x0028, 0x0029, 0x002A, 0x0314, 0x0315, 0x0317, 0x0084,
    ]

    /// The formats whose ring or dial LEDs TabletKit can set.
    static let ringLEDFormats: Set<ReportFormat> = [.intuosV1, .intuosV2, .cintiqV1, .xencelabs]
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
    /// The key displays' brightness, 0–15; 0 turns them off (Intuos4).
    func setKeyDisplayBrightness(_ level: Int)
}

extension LabelControl {
    public func setKeyOLEDsRotated180(_ rotated: Bool) {}
    public func setKeyDisplayBrightness(_ level: Int) {}
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

/// Settings the Wacom wireless kit's receiver holds for its tablet.
public protocol WirelessKitControl: AnyObject {
    /// Turns the tablet off after `minutes` without use, in the receiver's
    /// 5-minute steps; 0 leaves the tablet's own timer.
    func setSleepMinutes(_ minutes: Int)
}
