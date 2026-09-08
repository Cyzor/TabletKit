// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for Wacom's "PL" report family — the PL-400 through PL-800 LCD
/// pen displays (roughly 1998–2005), the direct ancestors of the Cintiq
/// line. PL-550 and PL-800 are literally the Cintiq 15X and 18SX under
/// their internal model numbers.
///
/// Ported from the Linux kernel's `wacom_pl_irq()` (`wacom_wac.c`) — two
/// independent third-party research passes were each re-verified against
/// that source directly before writing this decoder, following the same
/// discipline that caught real errors elsewhere this session. See
/// `Notes/Scratch/wacom-pl-series-design-2026-09-08.md` for the full
/// design rationale and confidence-tier reasoning.
///
/// Report ID 2 (`WACOM_REPORT_PENABLED`), 8 bytes:
///   [0]   report ID: 0x02
///   [1]   bit 6 = in-proximity/data-ready; bits 1..0 = X bits 15..14
///   [2]   X bits 13..7
///   [3]   X bits 6..0
///   [4]   bit 6 = pressure extra bit (>255-level models only)
///         bit 5 = eraser / button-2, session-classified — see below
///         bit 4 = side button 1 (stylus button 1)
///         bit 3 = tip switch
///         bit 2 = pressure extra bit (always used)
///         bits 1..0 = Y bits 15..14
///   [5]   Y bits 13..7
///   [6]   Y bits 6..0
///   [7]   signed pressure core
///
/// No Bluetooth/mode-switch handshake exists for this family — confirmed
/// against the kernel's BT query path (no `PL` case) and its
/// `mode_report` gate (unset for every `PL`-typed feature-table entry).
/// USB-only; the `[0x02, 0x02]` feature-report init is used the same way
/// every other Intuos/Cintiq-era device uses it, and is hardware-confirmed
/// specifically for PL-800 (a real macOS diagnostic capture backs it; see
/// the design doc). Provisional for the other seven PIDs sharing this
/// decoder until each is confirmed individually.
///
/// **Eraser / button-2 classification — the one place both source research
/// passes needed correcting against the kernel.** Byte 4 bit 5 does not
/// mean the same thing on every report: the kernel decides eraser-vs-pen
/// exactly once, at the moment proximity is entered, then holds that
/// classification for the rest of the session (reset on proximity loss).
/// Bit 5 activity *after* entry, if the tool was classified as pen, is
/// reported as a second stylus button instead. The kernel additionally
/// self-corrects: if classified eraser at entry but bit 5 later clears
/// mid-session, the tool is forced back to pen — a behavior neither
/// research source mentioned, found only by reading `wacom_pl_irq()`
/// directly. Implemented here with the same `state.isEraser`/
/// `state.prevInProximity` fields `Intuos3Decoder`/`GraphireDecoder`
/// already use for their own tool-enter/proximity-session patterns — no
/// new `DecoderState` field needed.
public struct WacomPLDecoder: TabletReportDecoder {

    public init() {}

    public func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard length >= 8, report[0] == 0x02 else { return [] }

        let status1 = report[1]
        let status4 = report[4]
        let inProximity = (status1 & 0x40) != 0
        let eraserBit = (status4 & 0x20) != 0

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

        var results: [DecodeResult] = []
        if !state.prevInProximity {
            // Classify once, at entry. This is the only moment eraserBit
            // means "this tool is the eraser" rather than "button 2 was
            // pressed" — see the type doc comment.
            state.prevInProximity = true
            state.isEraser = eraserBit
            results.append(
                .toolEnter(
                    ToolIdentity(
                        serial: 0,
                        toolCode: eraserBit ? 0x080A : 0x0802,
                        isEraser: eraserBit,
                        isMouse: false)))
        } else if state.isEraser && !eraserBit {
            // Kernel self-correction: an eraser classification made at entry
            // is revoked if the eraser bit later clears mid-session.
            state.isEraser = false
        }

        let x = Int(report[3]) | (Int(report[2]) << 7) | (Int(status1 & 0x03) << 14)
        let y = Int(report[6]) | (Int(report[5]) << 7) | (Int(status4 & 0x03) << 14)

        // The kernel does this arithmetic on `int` throughout (`data[7]`
        // promotes from `unsigned char` before the shift, per C integer
        // promotion), with exactly one explicit narrowing cast to
        // `signed char` around the OR'd expression below — not an implicit
        // truncation from a narrow variable type. Widen to Int first, do
        // the shift/OR at full width, truncate+sign-extend at that one
        // point via Int8, then widen back — a literal UInt8 shift here
        // would wrap at 8 bits under different rules than C's
        // promote-then-explicitly-truncate order and risks the wrong bit
        // pattern for pressure values ≥ 128.
        let pressureCore = (Int(report[7]) << 1) | Int((status4 >> 2) & 1)
        var pressure = Int(Int8(truncatingIfNeeded: pressureCore))
        if spec.maxPressure > 255 {
            pressure = (pressure << 1) | Int((status4 >> 6) & 1)
        }
        pressure += (spec.maxPressure + 1) / 2

        state.lastX = x
        state.lastY = y

        // Once classified pen, bit 5 activity is a second stylus button,
        // not eraser — never surfaced as eraser again this session.
        let button2 = !state.isEraser && eraserBit

        results.append(
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: (status4 & 0x10) != 0,
                    penButton2: button2,
                    eraser: state.isEraser, inProximity: true, hoverDistance: 0)))
        return results
    }
}
