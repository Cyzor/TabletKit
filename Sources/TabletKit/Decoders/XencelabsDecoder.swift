// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Xencelabs Pen Tablet / Pen Display HID report format.
///
/// Used by the Xencelabs line (VID 0x28BD): Pen Tablet Medium (0x5201) and
/// Small (0x5204), Pen Display 24 (0x520D) and 16 (0x520B), and the Quick
/// Keys puck (0x5202) and its dongle (0x5203), which send aux frames only.
/// `VendorDeviceRegistry.drivableProfile` is the authoritative list.
///
/// Pen data arrives on report ID 2 (vendor page 0xFF0A), in the UGEE/XP-Pen
/// layout; the hardware is a UGEE OEM. The standard digitizer collection on
/// report ID 7 never carries data.
///   [1]    tag bitfield (see below)
///   [2–3]  X low u16 LE; [10] is X's high byte. The Pen Display's X runs
///          0–105000, past 16 bits.
///   [4–5]  Y low u16 LE; [11] is Y's high byte (0 in practice)
///   [6–7]  pressure, u16 LE (8192 levels)
///   [8]    tilt X, signed byte
///   [9]    tilt Y, signed byte
///
/// Tag byte: 0xC0 = pen out of range. Otherwise a bitfield:
///   bit 0 = tip switch (pressure is nonzero iff set)
///   bit 1 = barrel button 1 (lowest button, 3 Button Pen only)
///   bit 2 = barrel button 2 (Thin Pen's first button)
///   bit 3 = barrel button 3 (Thin Pen's second button)
///   bit 4 = aux frame: Quick Keys buttons/dial, not pen data
///   bit 6 = eraser end in range
///   bit 7 = which pen: set for the 3 Button Pen, clear for the Thin Pen
/// The out-of-range tag 0xC0 has bit 7 set either way, so it doesn't say
/// which pen left.
///
/// Aux (bit-4) frames:
/// - Byte 2: the 8 keys, as `AuxButtons.buttons[0...7]`. Key N is bit N-1,
///   in Xencelabs' numbering: puck in landscape, dial at the right, keys
///   1–4 along the top row and 5–8 along the bottom, left to right.
///   Confirmed on hardware with single-key presses.
/// - Byte 3 bit 0: the mode button, as `buttons[8]`.
/// - Byte 3 bit 1: the dial's center click, as `touchRingButtonDown`, like a
///   Wacom ring's center button. All zero is a release.
/// - Byte 7: dial clicks, 1 = counterclockwise, 2 = clockwise, matching the
///   puck's own diagram.
///
/// Needs output report `[0x02, 0xB0, 0x04]` first, zero-padded to the
/// maximum output size; without it the device stays in mouse mode.
package struct XencelabsDecoder: TabletReportDecoder {

    /// Vendor-tunnel report carrying all live pen and puck data.
    static let penReportID: UInt8 = 0x02

    /// Tag byte constants.
    static let tagOutOfRange: UInt8 = 0xC0
    static let tipBit: UInt8 = 0x01
    static let barrelLowBit: UInt8 = 0x02   // 3-button pen's extra lower button
    static let barrel1Bit: UInt8 = 0x04
    static let barrel2Bit: UInt8 = 0x08
    static let auxBit: UInt8 = 0x10
    static let tagAux: UInt8 = 0xF0
    static let tagBattery: UInt8 = 0xF2
    static let eraserBit: UInt8 = 0x40
    static let threeButtonPenBit: UInt8 = 0x80

    /// Tool codes. See ``ToolIdentity/toolCode``.
    static let threeButtonPenCode: UInt16 = 0xE802
    static let threeButtonEraserCode: UInt16 = 0xE80A
    static let thinPenCode: UInt16 = 0xE812
    static let thinEraserCode: UInt16 = 0xE81A

    /// Full-scale tilt in degrees; see ``ReportFormat/tiltMaxDegrees``.
    public static let tiltMaxDegrees: Double? = ReportFormat.xencelabs.tiltMaxDegrees

    /// Divisor for the signed raw tilt bytes: a stop-to-stop capture reaches
    /// exactly ±60 on both axes. Check captures with `signedMagnitudeMax`,
    /// not `min`/`max`, which read a negative byte as up to 255.
    static let tiltRawScale = 60.0

    /// Creates a decoder. ``DeviceDecoder`` keeps one per device, with its state.
    public init() {}

    /// Decodes one report. See ``TabletReportDecoder/decode(report:spec:state:deviceFamily:)``.
    public mutating func decode(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        // Frame length varies: 10 bytes on the wired Quick Keys, 32 on the
        // dongle and Pen Display. Every pen field fits in the first 10.
        guard report.count >= 10, report[0] == Self.penReportID else { return [] }

        let tag = report[1]

        // Command echoes (0xB0–0xBF) arrive on this report too, some with the
        // aux bit set; read as keys, they stuck modifiers down. No real tag
        // has a 0xB_ top nibble.
        guard tag & 0xF0 != 0xB0 else { return [] }

        // ── QuickKeys puck (aux frames) ───────────────────────────────────────
        // Real aux data is exactly 0xF0. The dongle's connect-time status
        // frames (0xF8, 0xF2) share the aux bit and would read as presses.
        if tag == Self.tagAux {
            return Self.decodeAux(report)
        }
        // Reply to a battery poll: tag 0xF2, byte 2 == 0x01 as a marker,
        // byte 3 the percentage (`02 f2 01 5a` is 90%). No charging bit has
        // been seen, and only one sample confirms byte 2.
        if tag == Self.tagBattery, report.count >= 4, report[2] == 0x01 {
            return [.battery(percent: Int(report[3]), charging: false)]
        }
        // Other aux-bit tags are dongle status, not pen frames.
        guard tag & Self.auxBit == 0 else { return [] }

        // ── Out of range ──────────────────────────────────────────────────────
        if tag == Self.tagOutOfRange {
            guard state.prevInProximity else { return [] }
            state.prevInProximity = false
            let exitEraser = state.isEraser
            state.isEraser = false
            return [
                .pen(
                    TabletPoint(
                        x: state.lastX, y: state.lastY,
                        maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: false, penButton2: false,
                        eraser: exitEraser, inProximity: false, hoverDistance: 0))
            ]
        }

        // The coordinates' high bytes sit at [10] and [11].
        guard report.count >= 12 else { return [] }

        let isEraser = tag & Self.eraserBit != 0
        let toolCode: UInt16 =
            tag & Self.threeButtonPenBit != 0
            ? (isEraser ? Self.threeButtonEraserCode : Self.threeButtonPenCode)
            : (isEraser ? Self.thinEraserCode : Self.thinPenCode)

        var results: [DecodeResult] = []
        // Announce the tool on entering range, and whenever the pen or its
        // end changes. The pens carry no serial, so these codes are
        // TabletKit's own, listed in ToolCatalog.
        if !state.prevInProximity || toolCode != state.currentToolCode {
            state.prevInProximity = true
            state.isEraser = isEraser
            state.currentToolCode = toolCode
            results.append(
                .toolEnter(
                    ToolIdentity(
                        serial: 0,
                        toolCode: toolCode,
                        isEraser: isEraser,
                        isMouse: false)))
        }

        // Clamped in case some firmware overshoots its active area.
        let x = min(report.le16(at: 2) | Int(report[10]) << 16, spec.maxX)
        let y = min(report.le16(at: 4) | Int(report[11]) << 16, spec.maxY)
        let pressure = report.le16(at: 6)
        state.lastX = x
        state.lastY = y

        // Both axes pass through unmodified: the wire already uses the HID
        // tilt convention (+X right, +Y toward the user) that TabletPoint
        // defines. Verified at the application, not the event stream — see
        // TabletPoint.tiltY.
        let tiltX = Double(Int8(bitPattern: report[8])) / Self.tiltRawScale
        let tiltY = Double(Int8(bitPattern: report[9])) / Self.tiltRawScale

        results.append(
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: min(pressure, spec.maxPressure),
                    maxPressure: spec.maxPressure,
                    tiltX: max(-1.0, min(1.0, tiltX)),
                    tiltY: max(-1.0, min(1.0, tiltY)),
                    rotation: 0.0,
                    penButton1: tag & Self.barrel1Bit != 0,
                    penButton2: tag & Self.barrel2Bit != 0,
                    eraser: isEraser,
                    inProximity: true,
                    hoverDistance: 0,
                    penButton3: tag & Self.barrelLowBit != 0)))
        return results
    }

    /// QuickKeys puck frame: 8 express-key bits + mode button at bytes 2–3,
    /// dial center click reported separately via `touchRingButtonDown`
    /// (reused from the touch-ring model — see the type's header comment),
    /// dial rotation event at byte 7 (1 / 2 = the two directions).
    private static func decodeAux(_ report: HIDReport) -> [DecodeResult] {
        var results: [DecodeResult] = []

        var buttons = [Bool](repeating: false, count: 9)
        for i in 0..<8 { buttons[i] = report[2] & (1 << UInt8(i)) != 0 }
        buttons[8] = report[3] & 0x01 != 0
        let dialCenterDown = report[3] & 0x02 != 0
        results.append(.aux(AuxButtons(buttons: buttons, touchRingButtonDown: dialCenterDown)))

        // Dial clicks arrive as discrete events, not a counter. Positive delta
        // means physically clockwise, matching the normalized convention used
        // by the Wacom ring paths (see InputInjector.ringDeltaIsInverted) —
        // scroll-direction is applied later, uniformly, from the system
        // natural-scrolling setting, not baked in here.
        switch report[7] {
        case 1: results.append(.wheel(index: 0, delta: -1))
        case 2: results.append(.wheel(index: 0, delta: 1))
        default: break
        }
        return results
    }
}

extension ReportFormat {
    /// Full-scale tilt in degrees where the format itself fixes it, else `nil`.
    ///
    /// Xencelabs: the wire unit is 1° per count. A stop-to-stop capture
    /// saturates at raw ±60 while the vendor tool reads ±60° at those stops.
    public var tiltMaxDegrees: Double? {
        self == .xencelabs ? 60.0 : nil
    }
}

extension XencelabsDecoder {
    /// What this decoder remembers between reports.
    package struct State: DecoderState {
        /// Last X, held for frames that carry no position.
        package var lastX: Int = 0
        /// Last Y, held for frames that carry no position.
        package var lastY: Int = 0
        /// The tool in range.
        package var currentToolCode: UInt16 = 0
        /// Whether the last report had the pen in range.
        package var prevInProximity: Bool = false
        /// Whether the eraser end is in range, held through weak frames.
        package var isEraser: Bool = false

        package init() {}
    }
}
