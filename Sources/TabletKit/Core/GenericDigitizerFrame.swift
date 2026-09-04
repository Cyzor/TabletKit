// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

/// Accumulates standard HID digitizer element values into a `TabletPoint`.
///
/// Pure and vendor-neutral — no IOKit. The app's `GenericHIDDigitizer` reads
/// element values via IOKit value callbacks and forwards each `(usagePage,
/// usage, value)` tuple to `update(usagePage:usage:value:)`; `point()` then
/// produces the current frame. Keeping this logic here (rather than inside the
/// IOKit callback) makes the proximity rules, click-pressure synthesis, and
/// usage mapping unit-testable without hardware.
///
/// Usages follow the HID Usage Tables: Generic Desktop X/Y on page `0x01`,
/// everything else on the Digitizer page `0x0D`.
public struct GenericDigitizerFrame: Sendable {

    // Standard usages we read. Public so the app's element-presence scan and the
    // tests reference the same constants rather than scattered magic numbers.
    public enum Usage {
        public static let genericDesktopPage: UInt32 = 0x01
        public static let digitizerPage: UInt32 = 0x0D

        public static let x: UInt32 = 0x30  // Generic Desktop
        public static let y: UInt32 = 0x31  // Generic Desktop

        public static let tipPressure: UInt32 = 0x30  // Digitizer
        public static let inRange: UInt32 = 0x32
        public static let invert: UInt32 = 0x3C
        public static let tiltX: UInt32 = 0x3D
        public static let tiltY: UInt32 = 0x3E
        public static let tipSwitch: UInt32 = 0x42
        public static let barrelSwitch: UInt32 = 0x44
        public static let eraserSwitch: UInt32 = 0x45
        public static let secondaryBarrel: UInt32 = 0x5A
    }

    public let maxX: Int
    public let maxY: Int
    public let maxPressure: Int

    /// Whether the device exposes In Range and Tip Pressure usages. Decided once
    /// from the descriptor (the app scans elements; tests pass them in). These
    /// drive proximity semantics and click-pressure synthesis.
    public let hasInRange: Bool
    public let hasPressure: Bool

    private var x = 0
    private var y = 0
    private var pressure = 0
    private var tip = false
    private var inRange = false
    private var barrel1 = false
    private var barrel2 = false
    private var eraser = false
    private var tiltX = 0
    private var tiltY = 0

    public init(maxX: Int, maxY: Int, maxPressure: Int, hasInRange: Bool, hasPressure: Bool) {
        self.maxX = maxX
        self.maxY = maxY
        self.maxPressure = maxPressure
        self.hasInRange = hasInRange
        self.hasPressure = hasPressure
    }

    /// Apply one element value. Returns `true` if the usage was recognized (so
    /// the caller knows whether emitting a fresh point is worthwhile).
    @discardableResult
    public mutating func update(usagePage: UInt32, usage: UInt32, value: Int) -> Bool {
        switch (usagePage, usage) {
        case (Usage.genericDesktopPage, Usage.x): x = value
        case (Usage.genericDesktopPage, Usage.y): y = value
        case (Usage.digitizerPage, Usage.tipPressure): pressure = value
        case (Usage.digitizerPage, Usage.tipSwitch): tip = value != 0
        case (Usage.digitizerPage, Usage.inRange): inRange = value != 0
        case (Usage.digitizerPage, Usage.barrelSwitch): barrel1 = value != 0
        case (Usage.digitizerPage, Usage.secondaryBarrel): barrel2 = value != 0
        case (Usage.digitizerPage, Usage.eraserSwitch), (Usage.digitizerPage, Usage.invert):
            eraser = value != 0
        case (Usage.digitizerPage, Usage.tiltX): tiltX = value
        case (Usage.digitizerPage, Usage.tiltY): tiltY = value
        default: return false
        }
        return true
    }

    /// The current accumulated point.
    ///
    /// Proximity: trust In Range when the device reports it; otherwise reports
    /// only arrive while the pen is active, so treat the frame as in-proximity.
    ///
    /// Click is derived downstream from pressure. A tip-only pen with no pressure
    /// axis gets synthesized full-scale pressure on contact so taps register;
    /// pressure-reporting pens pass their real value through.
    public func point() -> TabletPoint {
        let proximity = hasInRange ? inRange : true
        let effPressure = hasPressure ? pressure : (tip ? maxPressure : 0)
        return TabletPoint(
            x: x, y: y, maxX: maxX, maxY: maxY,
            pressure: effPressure, maxPressure: maxPressure,
            tiltX: Double(tiltX), tiltY: Double(tiltY), rotation: 0.0,
            penButton1: barrel1, penButton2: barrel2,
            eraser: eraser, inProximity: proximity, hoverDistance: 0)
    }
}
