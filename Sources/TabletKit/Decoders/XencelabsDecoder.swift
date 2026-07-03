// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Xencelabs Pen Tablet / Pen Display HID report format.
///
/// Used by: Pen Tablet Medium (VID 0x28BD, PID 0x5201), Pen Tablet Small
/// (PID 0x5204), and Pen Display (PID 0x520D). Live pen data rides
/// **Report ID 2** (32 bytes, vendor usage page 0xFF0A) — confirmed from
/// 10k+ frames captured off a real Pen Display 2026-07-02, with both driver
/// present and absent, both pens (slim 2-button and 3-button), hover,
/// pressure, taps, barrel buttons, eraser, and QuickKeys puck use. The
/// device also declares a standard bit-packed digitizer collection on
/// Report ID 7, but it never carries live data in any observed state; an
/// earlier revision of this decoder targeted it and was wrong.
///
/// The layout matches the Ugee/XP-Pen OTD parser family (Xencelabs hardware
/// is Hanvon Ugee OEM and shares Ugee's actual VID). Byte offsets after the
/// report ID byte:
///   [1]    tag bitfield (see below)
///   [2–3]  X low u16 LE; byte [10] is X's high byte (24-bit LE total).
///          The Pen Display's X range is 0–105000 (~200 units/mm, matching
///          the spec'd 5080 lpi), which doesn't fit in 16 bits — byte 10
///          flips 0→1 exactly where the low word wraps, confirmed from live
///          mid-screen sweeps. An earlier revision read only the low word,
///          which made X wrap mod 65536 mid-screen ("Pac-Man" cursor) and
///          made corner sweeps report a bogus ~39150 max.
///   [4–5]  Y low u16 LE; byte [11] is Y's high byte (always 0 in practice —
///          Y's range is 0–59000, within 16 bits — read for symmetry)
///   [6–7]  pressure, u16 LE (spec'd 8192 levels; observed max ~6.4k)
///   [8]    tilt X, signed byte
///   [9]    tilt Y, signed byte
///
/// Tag byte: 0xC0 = pen out of range. Otherwise a bitfield:
///   bit 0 = tip switch (pressure is nonzero iff set)
///   bit 1 = barrel button 1 (lowest button, 3-button pen only)
///   bit 2 = barrel button 2 (slim pen's first button)
///   bit 3 = barrel button 3 (slim pen's second button)
///   bit 4 = aux frame: QuickKeys puck buttons/dial, not pen data
///   bit 6 = eraser end in range
///   bit 7 = device has been driver-initialized (0xA0 vs 0x20 hover);
///           orthogonal to everything else, ignored here
/// The two pens are not distinguishable in the report (bytes 12+ carry the
/// same constant on both), so tool identity only tracks pen vs eraser.
///
/// Aux (bit-4) frames: 10 one-hot button bits — byte 2 bits 0–7 are the 8
/// express keys (left column top→bottom = bits 3→0, right column top→bottom
/// = bits 7→4), byte 3 bit 0 = bottom rectangular mode button, bit 1 = dial
/// center click (both confirmed on hardware); all-zero = release. Byte 7
/// carries dial
/// rotation as per-click events: 1 = one direction, 2 = the other
/// (physical CW/CCW mapping unconfirmed — flip `dialDelta` if inverted).
///
/// Requires a tablet-mode init first: output report `[0x02, 0xB0, 0x04]`
/// (`InitStep.outputReport`), zero-padded to MaxOutputReportSize; without
/// it the device stays in mouse-emulation mode.
public struct XencelabsDecoder: TabletReportDecoder {

    /// Vendor-tunnel report carrying all live pen and puck data.
    static let penReportID: UInt8 = 0x02

    /// Tag byte constants.
    static let tagOutOfRange: UInt8 = 0xC0
    static let tipBit: UInt8 = 0x01
    static let barrelLowBit: UInt8 = 0x02   // 3-button pen's extra lower button
    static let barrel1Bit: UInt8 = 0x04
    static let barrel2Bit: UInt8 = 0x08
    static let auxBit: UInt8 = 0x10
    static let eraserBit: UInt8 = 0x40

    /// Tilt bytes are assumed to be degrees (±60°, the spec'd max for this pen
    /// family) rather than the ±127 sin-proportional encoding Wacom BLE uses.
    /// Unverified on hardware; if live tilt saturates early or never reaches
    /// full deflection, revisit this constant first.
    static let tiltScaleDegrees = 60.0

    public init() {}

    public mutating func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        // All fields through tilt Y fit in 10 bytes; the device pads to 32.
        guard length >= 10, report[0] == Self.penReportID else { return [] }

        let tag = report[1]

        // ── QuickKeys puck (aux frames) ───────────────────────────────────────
        if tag != Self.tagOutOfRange && tag & Self.auxBit != 0 {
            return Self.decodeAux(report)
        }

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

        let isEraser = tag & Self.eraserBit != 0
        let wasInProximity = state.prevInProximity
        let prevX = state.lastX
        let prevY = state.lastY

        var results: [DecodeResult] = []
        // toolEnter on rising edge or pen/eraser flip.  No serials on this
        // hardware; synthetic tool codes follow the GraphireDecoder convention
        // (0x080A eraser / 0x0802 pen) so per-tool settings keep working.
        if !state.prevInProximity || isEraser != state.isEraser {
            state.prevInProximity = true
            state.isEraser = isEraser
            results.append(
                .toolEnter(
                    ToolIdentity(
                        serial: 0,
                        toolCode: isEraser ? 0xE80A : 0xE802,
                        isEraser: isEraser,
                        isMouse: false)))
        }

        // Coordinates are 24-bit LE: low word at [2–3]/[4–5], high byte at
        // [10]/[11]. X genuinely needs the third byte (range 0–105000);
        // firmware clamps both axes at their active-area maxima, so no
        // wraparound handling is needed. Clamp to spec anyway in case a
        // different firmware overshoots slightly.
        let x = min(Int(report[2]) | Int(report[3]) << 8 | Int(report[10]) << 16, spec.maxX)
        let y = min(Int(report[4]) | Int(report[5]) << 8 | Int(report[11]) << 16, spec.maxY)
        let pressure = Int(report[6]) | Int(report[7]) << 8
        state.lastX = x
        state.lastY = y

        let tiltX = Double(Int8(bitPattern: report[8])) / Self.tiltScaleDegrees
        let tiltY = Double(Int8(bitPattern: report[9])) / Self.tiltScaleDegrees

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

    /// QuickKeys puck frame: 10 one-hot button bits at bytes 2–3, dial
    /// rotation event at byte 7 (1 / 2 = the two directions).
    private static func decodeAux(_ report: UnsafePointer<UInt8>) -> [DecodeResult] {
        var results: [DecodeResult] = []

        var buttons = [Bool](repeating: false, count: 10)
        for i in 0..<8 { buttons[i] = report[2] & (1 << UInt8(i)) != 0 }
        buttons[8] = report[3] & 0x01 != 0
        buttons[9] = report[3] & 0x02 != 0
        results.append(.aux(AuxButtons(buttons: buttons)))

        // Dial clicks arrive as discrete events, not a counter. Direction
        // assignment (1 = clockwise) is a guess pending physical confirmation.
        switch report[7] {
        case 1: results.append(.wheel(index: 0, delta: 1))
        case 2: results.append(.wheel(index: 0, delta: -1))
        default: break
        }
        return results
    }
}
