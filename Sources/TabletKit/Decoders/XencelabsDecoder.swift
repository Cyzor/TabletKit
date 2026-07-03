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
///   [2–3]  X, u16 LE — raw; real visible-area range confirmed ~0–39150 from
///          two independent physical corner sweeps, NOT the wire field's
///          16-bit capacity and NOT the report-7 descriptor's logical max
///          (both wrong — see VendorDeviceRegistry's Pen Display entry for
///          the full story). The sensor's physical detection area does
///          extend past the visible glass edge though — confirmed live, it
///          keeps emitting valid in-range reports out to where the wire
///          field itself wraps at 65536 — hence the edge-wrap latch below.
///   [4–5]  Y, u16 LE — same; confirmed ~0–59050. The two axes have
///          different units-per-mm on this sensor (Y's raw range is larger
///          despite being the shorter physical dimension), which is fine —
///          screen mapping normalizes each axis independently against its
///          own max
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
/// The two pens are not distinguishable in the report (bytes 10+ carry the
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
            state.xEdgeLatch = nil
            state.yEdgeLatch = nil
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
                        toolCode: isEraser ? 0x080A : 0x0802,
                        isEraser: isEraser,
                        isMouse: false)))
        }

        var x = Int(report[2]) | Int(report[3]) << 8
        var y = Int(report[4]) | Int(report[5]) << 8
        let pressure = Int(report[6]) | Int(report[7]) << 8
        // Both axes are raw 16-bit wire fields that genuinely overflow past
        // the sensor's active area: confirmed live via a slow drag off the
        // right edge, where X climbed steadily (~70–90/sample) to 65469,
        // then the very next sample read 13 — a clean mod-65536 wrap
        // (65469 + ~80 = 65549; 65549 - 65536 = 13). Left uncorrected, this
        // snaps the cursor to the opposite edge ("Pac-Man" wraparound) right
        // when the pen pushes past the true drawable boundary. A same-sample
        // jump of more than half the axis's range, while still continuously
        // in proximity, can only be this wraparound (no human motion covers
        // that distance between two ~100Hz+ reports).
        //
        // A single-shot clamp on just the wrap sample isn't enough: confirmed
        // live that holding the pen off-edge afterward keeps the wrapped
        // value free-running upward (still climbing ~50/sample, apparently
        // extrapolated rather than saturated) for hundreds of samples, until
        // it organically crosses back over the halfway threshold and would
        // otherwise be accepted again as if it were a real position — while
        // the pen is still physically off the drawable surface. So once a
        // wrap fires, latch to the edge and hold it there regardless of
        // further raw drift, releasing only on proximity loss/re-entry
        // (state.xEdgeLatch/yEdgeLatch, cleared in the out-of-range branch
        // above and on fresh proximity entry below).
        if wasInProximity {
            if let latched = state.xEdgeLatch {
                x = latched
            } else if prevX - x > spec.maxX / 2 {
                x = spec.maxX
                state.xEdgeLatch = spec.maxX
            } else if x - prevX > spec.maxX / 2 {
                x = 0
                state.xEdgeLatch = 0
            }
            if let latched = state.yEdgeLatch {
                y = latched
            } else if prevY - y > spec.maxY / 2 {
                y = spec.maxY
                state.yEdgeLatch = spec.maxY
            } else if y - prevY > spec.maxY / 2 {
                y = 0
                state.yEdgeLatch = 0
            }
        } else {
            state.xEdgeLatch = nil
            state.yEdgeLatch = nil
        }
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
