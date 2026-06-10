// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Xencelabs Pen Tablet HID report format.
///
/// Used by: Pen Tablet Medium (VID 0x28BD, PID 0x5201) and Pen Tablet Small
/// (PID 0x5204).  Experimental — ported from OpenTabletDriver's
/// `XenceLabsReportParser` / `XenceLabsTabletReport` / `XP_PenAuxReport`
/// (pinned 2026-05-15 snapshot) and the desk spike in
/// Notes/Scratch/Xencelabs-G1D-Feasibility-2026-05-28.md.  Not yet validated
/// on hardware.
///
/// Requires a tablet-mode init first: output report `[0x02, 0xB0, 0x04]`
/// (`InitStep.outputReport`); without it the device stays in mouse-emulation
/// mode and these reports never arrive.
///
/// Report dispatch (on byte 1, after the report ID at byte 0):
///   (b1 & 0xF0) == 0xF0  → aux report (express keys + relative wheels)
///   b1 bit 5 set          → pen report
///   otherwise             → out-of-range / status frame (proximity exit)
///
/// Pen report (10 bytes):
///   [1] bit 5 = in range; bit 6 = eraser; bits 1–3 = barrel buttons 1–3
///   [2–3] X LE16   [4–5] Y LE16   [6–7] pressure LE16 (0–8191)
///   [8] tilt X (signed int8)   [9] tilt Y (signed int8)
///
/// Aux report:
///   [2–4] 20-button bitmask (we surface the first 16 — the binding storage cap)
///   [7] relative wheel pulses: bit0 = wheel 0 CW, bit1 = wheel 0 CCW,
///       bit4 = wheel 1 CW, bit5 = wheel 1 CCW
public struct XencelabsDecoder: TabletReportDecoder {

    public init() {}

    /// Tilt bytes are assumed to be degrees (±60°, the spec'd max for this pen
    /// family) rather than the ±127 sin-proportional encoding Wacom BLE uses.
    /// Unverified on hardware; if live tilt saturates early or never reaches
    /// full deflection, revisit this constant first.
    static let tiltScaleDegrees = 60.0

    public mutating func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        let status = report[1]

        // ── Aux: express keys + wheels ────────────────────────────────────────
        if (status & 0xF0) == 0xF0 {
            guard length >= 8 else { return [] }
            var buttons = [Bool](repeating: false, count: 16)
            for i in 0..<8 {
                buttons[i] = (report[2] >> i) & 1 != 0
                buttons[8 + i] = (report[3] >> i) & 1 != 0
            }
            var results: [DecodeResult] = [.aux(AuxButtons(buttons: buttons))]
            let wheels = report[7]
            let delta0 = (wheels & 0x01) != 0 ? 1 : ((wheels & 0x02) != 0 ? -1 : 0)
            let delta1 = (wheels & 0x10) != 0 ? 1 : ((wheels & 0x20) != 0 ? -1 : 0)
            if delta0 != 0 { results.append(.wheel(index: 0, delta: delta0)) }
            if delta1 != 0 { results.append(.wheel(index: 1, delta: delta1)) }
            return results
        }

        // ── Out of range ──────────────────────────────────────────────────────
        let inProximity = (status & 0x20) != 0
        if !inProximity {
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

        // ── Pen in range ──────────────────────────────────────────────────────
        guard length >= 10 else { return [] }
        let isEraser = (status & 0x40) != 0

        var results: [DecodeResult] = []
        // toolEnter on rising edge or tip/eraser flip.  No serials on this
        // hardware; synthetic tool codes follow the GraphireDecoder convention
        // (0x080A eraser / 0x0802 pen) so per-tool settings keep working.
        if !state.prevInProximity || isEraser != state.isEraser {
            state.prevInProximity = true
            state.isEraser = isEraser
            results.append(
                .toolEnter(
                    ToolIdentity(
                        serial: 0,
                        toolCode: isEraser ? 0x080A : 0x0802,
                        isEraser: isEraser,
                        isMouse: false)))
        }

        let x = Int(UInt16(report[2]) | UInt16(report[3]) << 8)
        let y = Int(UInt16(report[4]) | UInt16(report[5]) << 8)
        let pressure = Int(UInt16(report[6]) | UInt16(report[7]) << 8)
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
                    penButton1: (status & 0x02) != 0,
                    penButton2: (status & 0x04) != 0,
                    eraser: isEraser,
                    inProximity: true,
                    hoverDistance: 0,
                    penButton3: (status & 0x08) != 0)))
        return results
    }
}
