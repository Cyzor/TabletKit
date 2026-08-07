// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

public protocol TabletDevice: AnyObject {
    var spec: DigitizerSpec { get }
    func open()
    func close()
    /// Update the physical ring LED to reflect the active mode slot (0-based).
    /// No-op on devices that don't support LED control.
    func setRingLED(index: Int)
    /// Show the active ring/dial mode's name on the device's display
    /// (Xencelabs Quick Keys OLED mode line). No-op on devices without one.
    func setRingModeLabel(_ label: String)
    /// Show per-key labels on the device's display (Xencelabs Quick Keys
    /// OLED; labels[0] = key 1). No-op on devices without one.
    func setAuxKeyLabels(_ labels: [String])
    /// Per-mode-slot custom colors for devices whose ring/dial LED is RGB
    /// (Xencelabs Quick Keys). `nil` entries mean the device's factory
    /// per-mode palette. No-op on devices without an RGB LED.
    func setRingLEDColors(_ colors: [(r: UInt8, g: UInt8, b: UInt8)?])
    /// True when the device's built-in screen has host-controllable
    /// backlight brightness (Xencelabs pen displays).
    var hasDisplayBrightnessControl: Bool { get }
    /// Set the built-in screen's backlight brightness (0–100). No-op on
    /// devices without host-controllable brightness.
    func setDisplayBrightness(_ percent: Int)
    /// Set the built-in screen's contrast (0–100). No-op on devices without
    /// host-controllable panel contrast.
    func setDisplayContrast(_ percent: Int)
    /// Set the built-in screen's gamma, passed as gamma × 10 (e.g. 22 = 2.2).
    /// No-op on devices without host-controllable gamma.
    func setDisplayGamma(_ gammaTimesTen: Int)
    /// Select a built-in color-space preset (Adobe RGB, sRGB, REC 709,
    /// DCI-P3, REC 2020, Pantone, Custom) by row index. No-op on devices
    /// without host-controllable color-mode presets.
    func setColorMode(_ index: Int)
    /// Set the shared backlight LED behind the device's onboard bezel
    /// buttons (Xencelabs pen displays). Brightness is premultiplied into
    /// the RGB by the caller — the LED has no brightness register. No-op on
    /// devices without a controllable bezel LED.
    func setBezelLEDColor(r: UInt8, g: UInt8, b: UInt8)
    /// Set the Quick Keys OLED text orientation, in 90° steps (0 = upright,
    /// 1–3 = 90°/180°/270°). No-op on devices without one.
    func setQuickKeysOrientation(steps: Int)
    /// Set the Quick Keys' auto-sleep timer, in minutes (0 = never sleep).
    /// No-op on devices without one.
    func setQuickKeysSleepMinutes(_ minutes: Int)
    /// Set the Quick Keys OLED's brightness level, 0 (off) through 3
    /// (bright). No-op on devices without one.
    func setQuickKeysOledBrightness(_ level: Int)
    /// Re-run the device's feature/mode-switch init sequence on an already-open
    /// connection. No-op on devices with no such sequence (e.g. Xencelabs).
    ///
    /// Exists because a device can connect before its digitizer endpoint is
    /// ready to answer the mode-switch write, leaving it stuck reporting in
    /// whatever mode it powered on in (seen: a snapped-wrong screen mapping
    /// that only corrected after resending the same write the driver already
    /// sends once at `open()`). Safe to call on a device that's already
    /// correctly initialized — it's the same idempotent write.
    func reawaken()
}

public extension TabletDevice {
    func setRingLED(index: Int) {}
    func setRingModeLabel(_ label: String) {}
    func setAuxKeyLabels(_ labels: [String]) {}
    func setRingLEDColors(_ colors: [(r: UInt8, g: UInt8, b: UInt8)?]) {}
    var hasDisplayBrightnessControl: Bool { false }
    func setDisplayBrightness(_ percent: Int) {}
    func setDisplayContrast(_ percent: Int) {}
    func setColorMode(_ index: Int) {}
    func setDisplayGamma(_ gammaTimesTen: Int) {}
    func setBezelLEDColor(r: UInt8, g: UInt8, b: UInt8) {}
    func setQuickKeysOrientation(steps: Int) {}
    func setQuickKeysSleepMinutes(_ minutes: Int) {}
    func setQuickKeysOledBrightness(_ level: Int) {}
    func reawaken() {}
}
