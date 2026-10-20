// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Intuos4 feature report 0x20 (LED slot and luminance, ExpressKey OLED
/// brightness) and the idle cycle that drives it.
///
/// Read from Wacom's macOS driver 6.3.41-2, and named after it:
/// `CPTKTabletControls::SendDisplayProperties` for the bytes,
/// `CPTKUSBGraphicsTablet::GetDisplayBrightness` and `SleepTimerCallBack` for
/// the idle cycle, and `CKestrelGraphicsTablet::HasOLEDS` for which models
/// take part. Bytes and timing are confirmed on a PTK-640; the other models
/// follow the driver.
public enum Intuos4DisplayProperties: Sendable {

    /// The driver's `SleepState`. Its states 0 and 1 both mean awake.
    public enum SleepState: Sendable, CaseIterable {
        case awake, lightSleep, deepSleep
    }

    /// The driver's `LightSleepTimerInterval` and `DeepSleepTimerInterval`,
    /// in seconds, over USB. It shortens them to 60 s / 90 s only for the
    /// PTK-540WL running on its battery, which this report path doesn't reach.
    public static let lightSleepTimerInterval: TimeInterval = 300
    public static let deepSleepTimerInterval: TimeInterval = 300

    /// The driver's `HasOLEDS`, for the wired Intuos4 models: every one but
    /// the PTK-440 (0x00B8), which has no ExpressKey displays. Only these
    /// models run the idle cycle.
    public static func hasOLEDs(productID: Int) -> Bool {
        (0x00B9...0x00BC).contains(productID)
    }

    /// The state `SleepTimerCallBack` moves to once `state`'s interval runs
    /// out; nil from deep sleep, where the driver stops its timer until input
    /// arrives.
    public static func nextSleepState(after state: SleepState) -> SleepState? {
        switch state {
        case .awake: return .lightSleep
        case .lightSleep: return .deepSleep
        case .deepSleep: return nil
        }
    }

    /// When `state` ends, counted from the last input; nil in deep sleep.
    public static func deadline(leaving state: SleepState, lastInput: TimeInterval) -> TimeInterval? {
        switch state {
        case .awake: return lastInput + lightSleepTimerInterval
        case .lightSleep: return lastInput + lightSleepTimerInterval + deepSleepTimerInterval
        case .deepSleep: return nil
        }
    }

    /// The driver's `GetDisplayBrightness`: the index into its brightness
    /// tables. The user's level (default 6) awake, 3 in light sleep, 0 in
    /// deep sleep.
    public static func displayBrightness(for state: SleepState) -> Int {
        switch state {
        case .awake: return 6
        case .lightSleep: return 3
        case .deepSleep: return 0
        }
    }

    /// The driver's `SendDisplayProperties`: the 9-byte report 0x20 for ring
    /// slot `slot`, `[0x20, 0x04 | slot, LED normal, LED high, OLED, 0, 0, 0, 0]`.
    /// The firmware switches the ring from the normal to the high level by
    /// itself: seen with the pen tip down; the Intuos4 mouse is untested.
    ///
    /// Models in `hasOLEDs` get the driver's bytes for `sleepState`; the OLED
    /// byte is a 0–15 level in the low nibble plus 0x10 to enable the
    /// displays. Anything else gets the kernel's `wacom_led_control`
    /// defaults (10, 20, 10) whatever the state. Bytes 5–8 stay zero, as
    /// neither the vendor driver nor the kernel writes them.
    public static func displayProperties(slot: Int, sleepState: SleepState, productID: Int) -> [UInt8] {
        var levels: (UInt8, UInt8, UInt8) = (10, 20, 10)
        if hasOLEDs(productID: productID) {
            let index = displayBrightness(for: sleepState)
            // The PTK-540WL (0x00BC/0x00BD) swaps in its own OLED table.
            let oled = productID == 0x00BC ? ptkWLOLEDBrightness : oledBrightness
            levels = (ledNormalBrightness[index], ledHighBrightness[index],
                      index == 0 ? 0 : oled[index] | 0x10)
        }
        return [0x20, 0x04 | UInt8(slot & 0x03), levels.0, levels.1, levels.2, 0, 0, 0, 0]
    }

    // The driver's tables (`kLEDNormalBrightness` and so on), indexed by
    // display brightness 0–9.
    static let ledNormalBrightness: [UInt8] = [10, 10, 10, 10, 10, 10, 10, 32, 32, 32]
    static let ledHighBrightness: [UInt8] = [10, 40, 40, 40, 40, 40, 40, 127, 127, 127]
    static let oledBrightness: [UInt8] = [0, 5, 5, 5, 10, 10, 10, 15, 15, 15]
    static let ptkWLOLEDBrightness: [UInt8] = [0, 7, 7, 7, 12, 12, 12, 15, 15, 15]
}
