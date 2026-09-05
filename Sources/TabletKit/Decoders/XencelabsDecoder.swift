// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Xencelabs Pen Tablet / Pen Display HID report format.
///
/// Used by the Xencelabs line (VID 0x28BD): Pen Tablet Medium (0x5201) and
/// Small (0x5204), Pen Display 24 (0x520D) and 16 (0x520B), and the Quick
/// Keys puck (0x5202) and its wireless dongle (0x5203), which carry aux
/// frames only. `VendorDeviceRegistry.drivableProfile` is the authoritative
/// list. Live pen data rides **Report ID 2** (vendor usage page 0xFF0A) —
/// confirmed from 10k+ frames captured off a real Pen Display 2026-07-02,
/// with both driver present and absent, both pens (slim 2-button and
/// 3-button), hover, pressure, taps, barrel buttons, eraser, and QuickKeys
/// puck use. The device also declares a standard bit-packed digitizer
/// collection on Report ID 7, but it never carries live data in any observed
/// state; an earlier revision of this decoder targeted it and was wrong.
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
/// Aux (bit-4) frames: byte 2 bits 0–7 are the 8 express keys, reported as
/// `AuxButtons.buttons[0...7]`.
///
/// Key numbering follows Xencelabs' own scheme, anchored on the dial: hold the
/// puck in landscape with the dial at the right, then keys 1–4 are the top row
/// left→right and keys 5–8 the bottom row left→right (matches the vendor
/// settings UI, and the `KeyIndex` values in its logs — KeyIndex 0 = key 1).
/// This decoder maps key N to bit N-1, i.e. top row = bits 0–3 and bottom row
/// = bits 4–7. **Hardware-confirmed 2026-07-18** with isolated single-key
/// presses: key 1 alone → byte 2 == `0x01`, key 8 alone → `0x80`. (Sweep
/// captures cannot establish this — `08 04 02 01 80 40 20 10` fits a sweep in
/// either direction, so only isolated named presses settle it.)
///
/// Byte 3 bit 0 is the bottom rectangular mode
/// button, reported as `buttons[8]` — bind it to the "Ring: Cycle" action to
/// advance the dial mode, same as a Wacom touch-ring mode key. Byte 3 bit 1
/// is the dial's own center click, reported via the shared
/// `touchRingButtonDown`/`touchRingButtonBinding` field instead of the
/// indexed array, mirroring how Wacom's ring center click is a dedicated
/// slot rather than a numbered express key. All-zero = release. Byte 7
/// carries dial rotation as per-click events: 1 = counter-clockwise, 2 =
/// clockwise (confirmed on hardware 2026-08-06 against the puck's own
/// bezel diagram, which labels physical rotation independent of any
/// scroll-direction convention).
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
    static let tagAux: UInt8 = 0xF0
    static let tagBattery: UInt8 = 0xF2
    static let eraserBit: UInt8 = 0x40

    /// Full-scale tilt in degrees. The wire unit is 1° per count: a
    /// stop-to-stop capture saturates at raw ±60 (see `tiltRawScale`) while
    /// the vendor tool reads ±60° at those same stops.
    public static let tiltMaxDegrees: Double? = 60.0

    /// Divisor for the signed raw tilt bytes, hardware-confirmed 2026-09-04.
    ///
    /// A stop-to-stop capture (0x520D, 27767 samples) holds both bytes at
    /// exactly ±60 with every integer in between present and nothing beyond,
    /// on both axes, reproduced independently in the hover (A0), contact (A1),
    /// and E0 buckets. Earlier sweeps peaked at 44 only because nobody tilted
    /// the pen to its mechanical stop.
    ///
    /// Read `signedMagnitudeMax` when checking this against a capture, not
    /// `min`/`max` — a signed byte reports 0 and 255 the moment it goes
    /// negative, and the truncated `values` list makes a signed span look like
    /// a plateau at the truncation boundary.
    ///
    /// OpenTabletDriver passes the raw sbyte straight through with no scaling,
    /// so it offers no independent check on the divisor.
    static let tiltRawScale = 60.0

    public init() {}

    public mutating func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        // Frame length varies across the family — there is no single padded
        // size (confirmed 2026-07-18 against live HID descriptors): the wired
        // Quick Keys declares 9 payload bytes on this tunnel (10 including the
        // report ID, i.e. no padding at all), while the wireless dongle and the
        // Pen Display both declare 31 (32 total). All pen fields through tilt Y
        // fit inside 10 bytes, so gate on that floor rather than a fixed size.
        guard length >= 10, report[0] == Self.penReportID else { return [] }

        let tag = report[1]

        // Vendor feature-report acknowledgements (config/init handshake echoes,
        // opcodes 0xB0/0xB4/0xB5/0xB8) are read back on this same Report ID 2
        // tunnel and were being misread as live pen/aux data — confirmed
        // 2026-07-05 on a Pen Display: its own "02 b4 ..."/"02 b5 ..." handshake
        // replies happened to have bit 4 (the aux-frame bit) set, so decodeAux()
        // ran on config bytes and latched a phantom express-key/mode-button
        // press — which stuck a mapped modifier permanently, with no puck even
        // connected. Every known real tag value has top nibble 0x2_, 0xA_, or
        // 0xC_; the whole opcode-echo family shares top nibble 0xB0, which
        // never occurs in real tag data, so gate on that instead.
        guard tag & 0xF0 != 0xB0 else { return [] }

        // ── QuickKeys puck (aux frames) ───────────────────────────────────────
        // Real aux data always arrives with tag == 0xF0 exactly (confirmed
        // from thousands of button/dial frames, both direct-USB and through
        // the wireless dongle). The wireless dongle also emits a couple of
        // one-off status/announcement frames around connect time — tags
        // 0xF8 and 0xF2, confirmed 2026-07-06 — that happen to share bit 4
        // (the aux-frame bit) with real data but aren't button presses; one
        // such 0xF8 frame decoded as a phantom express-key + mode-button
        // press with no matching release, sticking a mapped modifier down
        // exactly like the earlier 0xB4/0xB5 config-echo bug. Requiring an
        // exact match instead of just testing the aux bit excludes those.
        if tag == Self.tagAux {
            return Self.decodeAux(report)
        }
        // Battery GET reply (solicited — see WacomKnownDevice's periodic
        // poll): tag 0xF2, byte[2] == 0x01 as a constant marker, byte[3] =
        // raw 0–100 percentage. Confirmed 2026-07-14 from a live capture
        // (`02 f2 01 5a ...` == 90%) against a wireless puck. No charging
        // bit observed — this puck has no wired-charging state to report,
        // so charging is always false here. Single-sample confirmation;
        // revisit byte[2]'s role if a reply is ever seen with a different
        // value there.
        if tag == Self.tagBattery, length >= 4, report[2] == 0x01 {
            return [.battery(percent: Int(report[3]), charging: false)]
        }
        // Any other tag with the aux bit set isn't a pen frame either — it's
        // one of those dongle status frames — so don't let it fall through
        // to the pen-decode path below and synthesize a bogus toolEnter.
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

        let isEraser = tag & Self.eraserBit != 0

        var results: [DecodeResult] = []
        // toolEnter on rising edge or pen/eraser flip.  No serials or tool
        // IDs on this hardware (the 3 Button Pen and Thin Pen emit identical
        // reports), so both map to the shared synthetic Xencelabs codes in
        // WacomToolCatalog (0xE802 pen / 0xE80A eraser, following the Wacom
        // eraser-bit convention) for naming and per-tool settings.
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

        // Both axes pass through unmodified: measured against the native
        // Xencelabs driver on 2026-09-05 (tools/tilt_event_probe.swift, one
        // tablet connected), the raw wire signs already match it exactly —
        // leaning away gives +1.0 in both, leaning west +1.0 in both.
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
    private static func decodeAux(_ report: UnsafePointer<UInt8>) -> [DecodeResult] {
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
