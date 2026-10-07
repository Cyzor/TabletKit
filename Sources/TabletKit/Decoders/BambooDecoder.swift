// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom Bamboo consumer HID report format.
///
/// Used by: CTT-460, CTH-460/461/470/480/490, CTH-661/670, CTL-460/470/660,
/// and related consumer Bamboo / Wacom One series.
///
/// Two wire formats, distinguished by report ID:
///
/// **Report ID 0x02, 9 bytes (BAMBOO_PT / USB)** — the format the kernel's
/// `wacom_bpt_pen()` decodes for the 2009–2011 Bamboo generation (CTL-460/660,
/// CTH-460/461/470, CTL-470...). Only emitted after the tablet is switched out
/// of mouse emulation with feature report `[0x02, 0x02]` (see
/// `WacomDeviceSpec.initSteps`); in mouse mode these tablets send 4-byte
/// relative boot-mouse packets on report ID 0x01 instead. Confirmed against a
/// user capture of a CTL-460 (PID 0x00D4) on 2026-07-21.
///
/// The same 0x02 pen format, at 10 bytes rather than 9, also covers the
/// INTUOSHT generation (CTH-480/680, CTL-480/680 — the 2013 "Intuos Pen &
/// Touch" / "One by Wacom" models). Those were previously assigned `.intuosV1`,
/// which reads coordinates big-endian and produced ~130,600 for every position
/// regardless of tablet size; reassigned 2026-07-29 after little-endian decode
/// hit each model's registered maxX exactly. Their INTUOSHT2 successors
/// (CTH-490/690, CTL-490/690) genuinely are `.intuosV1` and stay there — see
/// `BPT3ContainerDecoder` for the generation table.
///
/// **Report ID 0x02, 64 bytes** — BPT3 touch/pad container, shared with the
/// INTUOSHT2 generation. Routed to `BPT3ContainerDecoder`. Dispatched on length
/// before the pen path, since both share report ID 0x02.
///
/// **Report ID 0x10, 10 bytes** — legacy synthesized layout, same report ID as
/// IntuosV2 but an entirely different, shorter layout with no tool-serial
/// negotiation. Retained for compatibility; not yet observed on hardware.
///
/// **CTT-460 (0x00D0) is touch-only** — it has no pen interface.  Reports will
/// never fire (maxPressure = 0, buttonCount = 0 → decoder silently returns []).
///
/// **Report ID 0x02, 20 bytes (BAMBOO_PT touch, USB)** — a separate USB
/// interface on the older CTH-460/461 chassis (kernel `wacom_bpt_touch()`).
/// Two fixed slots, big-endian, 11-bit coordinates in a 480×320 wire space
/// (same low-res space as CTT-460 — see that registry row's note), plus the
/// 4 express keys, which ride this report's byte 1 rather than a separate pad
/// byte. Confirmed against the kernel's static feature table (`BAMBOO_PT`,
/// `touch_max = 2`) for 0x00D1/0x00D6/0x00D7/0x00DA on 2026-08-26; no direct
/// hardware capture of this report exists yet, so those rows carry
/// `.crossReferenced`, not `.verified`.
///
/// ```
/// [0]  0x02   Report ID
/// [1]  bit 7: contact stride selector — 8 bytes/contact if set, 9 if clear
///      bit 3: BTN_0   bit 2: BTN_1   bit 1: BTN_2   bit 0: BTN_3
/// For i in 0, 1 (fixed slot per finger), at offset = (bit7 ? 8*i : 9*i):
///   [offset+3] bit 7: contact down; bits 6:0 + [offset+4]: X, BE16 & 0x7FF
///   [offset+5:6]                     Y, BE16 & 0x7FF
/// ```
///
/// Touch on the INTUOSHT generation (CTH-480/680) and the 16FG Bamboos
/// (CTH-470/670) instead arrives in the 64-byte BPT3 container above.
///
/// ---
///
/// **Report layout (pen in proximity):**
/// ```
/// [0]  0x10   Report ID
/// [1]  status — see below
/// [2:3] X     BE16
/// [4:5] Y     BE16
/// [6:7] pressure: (d6 << 3) | (d7 >> 5) — 11-bit
///              → right-shift by 1 if maxPressure ≤ 1023 (10-bit hardware)
/// [8]  tilt X (4-bit signed, centre=8) — decoded when spec.hasTilt; zero otherwise
/// [9]  tilt Y (4-bit signed, centre=8) — decoded when spec.hasTilt; zero otherwise
/// ```
///
/// **Status byte d1:**
/// ```
/// bit 7    in proximity
/// bits 4:3 tool type: 0 = pen,  1 = eraser,  2 = mouse
/// bit 2    BTN_STYLUS2 (barrel button 2)
/// bit 1    BTN_STYLUS  (barrel button 1)
/// bit 0    BTN_TOUCH   (tip contact)
/// ```
///
/// Eraser is identified directly from the tool-type field — no prior
/// enter-prox packet or serial number exchange (ABS_MISC not present).
///
/// **Pad report (when pen NOT in proximity, d7 byte):**
/// - CTH-460/470/480/490 (buttonCount ≥ 4): 0x08=btn0, 0x20=btn1, 0x10=btn2, 0x40=btn3
/// - CTL-460/470/660    (buttonCount ≥ 2): 0x01=btn0, 0x02=btn1
/// - CTT-460            (buttonCount = 0): no buttons, no output
///
/// Pad proximity signal (ABS_MISC = PAD_DEVICE_ID) fires when any button bit
/// is non-zero; clears on all-zero.  We emit `AuxButtons` every time since
/// InputInjector handles idempotent button state.
public struct BambooDecoder: TabletReportDecoder {

    /// Creates a decoder. Keep one per device, with its own ``DecoderState``.
    public init() {}

    /// Decodes one report. See ``TabletReportDecoder/decode(report:spec:state:deviceFamily:)``.
    public mutating func decode(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        // Report ID 0x02 is overloaded on INTUOSHT hardware: a 9/10-byte pen
        // report and a 64-byte touch/pad container share it, distinguished only
        // by length. Dispatch on length before anything else — without this the
        // container would be decoded as pen coordinates.
        if report[0] == 0x02, report.count == BPT3ContainerDecoder.reportLength {
            return BPT3ContainerDecoder.decode(report: report, spec: spec, state: &state)
        }
        if report[0] == 0x02, report.count == 20 {
            return decodeBPTTouch(report: report, spec: spec)
        }
        if report[0] == 0x02, (9...10).contains(report.count) {
            return decodeBPT(report: report, spec: spec, state: &state)
        }
        // Bamboo Pad (CTH-300/301): pen and touch share one 0x10 container,
        // 32 bytes wireless or 64 over USB. Every other 0x10 here is 9–10.
        if report[0] == 0x10, report.count == 32 || report.count == 64 {
            return decodeBambooPad(report: report, spec: spec, state: &state)
        }
        guard report.count >= 10, report[0] == 0x10 else { return [] }

        let status = report[1]
        let inProximity = (status & 0x80) != 0

        if !inProximity {
            var results: [DecodeResult] = []
            // Emit pen-out on proximity falling edge.
            if state.prevInProximity {
                state.prevInProximity = false
                results.append(
                    .pen(
                        TabletPoint(
                            x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                            pressure: 0, maxPressure: spec.maxPressure,
                            tiltX: 0, tiltY: 0, rotation: 0.0,
                            penButton1: false, penButton2: false,
                            eraser: state.isEraser, inProximity: false, hoverDistance: 0)))  // Not reported by Bamboo format
            }
            // Decode pad buttons (only when device has express keys).
            if spec.buttonCount > 0 {
                results.append(contentsOf: decodePad(report: report, spec: spec))
            }
            return results
        }

        // ── Pen / eraser in proximity ─────────────────────────────────────────
        let toolType = (status >> 3) & 0x03  // 0=pen, 1=eraser, 2=mouse
        let isEraser = toolType == 1

        var results: [DecodeResult] = []

        // Fire toolEnter on proximity rising edge.
        if !state.prevInProximity {
            state.isEraser = isEraser
            state.prevInProximity = true
            results.append(
                .toolEnter(
                    ToolIdentity(
                        serial: 0,
                        toolCode: isEraser ? 0x080A : 0x0802,
                        isEraser: isEraser,
                        isMouse: false)))
        }

        let x = Int(UInt16(report[3]) | UInt16(report[2]) << 8)
        let y = Int(UInt16(report[5]) | UInt16(report[4]) << 8)
        state.lastX = x
        state.lastY = y

        // 11-bit pressure; right-shift for 10-bit (maxPressure ≤ 1023) devices.
        let rawPressure = (Int(report[6]) << 3) | (Int(report[7]) >> 5)
        let pressure = spec.maxPressure <= 1023 ? rawPressure >> 1 : rawPressure

        // Tilt: 4-bit signed (range 0–15, centre = 8) in report[8]/report[9].
        // Only valid on devices with hasTilt = true; other models leave these
        // bytes as zero, which decodes as -8 (non-zero garbage) without the gate.
        var tiltX = 0.0
        var tiltY = 0.0
        if spec.hasTilt {
            tiltX = Double((Int(report[8]) & 0x0F) - 8) / 8.0
            tiltY = Double((Int(report[9]) & 0x0F) - 8) / 8.0
        }

        results.append(
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: tiltX, tiltY: tiltY, rotation: 0.0,
                    penButton1: (status & 0x02) != 0,
                    penButton2: (status & 0x04) != 0,
                    eraser: isEraser,
                    inProximity: true,
                    hoverDistance: 0)))  // Not reported by Bamboo format

        return results
    }

    // MARK: - BAMBOO_PT pen report (Report ID 0x02, 9 bytes)

    /// Kernel `wacom_bpt_pen()` layout:
    /// ```
    /// [0] 0x02 Report ID
    /// [1] status — bit 0 tip, bit 1 barrel 1, bit 2 barrel 2,
    ///              bit 3 eraser tool, bit 5 in proximity
    /// [2:3] X  LE16    [4:5] Y  LE16    [6:7] pressure LE16
    /// [8] hover distance
    /// ```
    /// No express-key bits here — CTH pad buttons ride the separate touch
    /// interface, and the CTL pen-only models have no express keys at all.
    ///
    /// Verified 2026-07-28 against a real CTL-460 (0x00D4) capture (3613 events:
    /// hover, tip contact, both barrel buttons, eraser, proximity exit) — every
    /// bit and byte offset above matched with no discrepancies. Bits 0x01 (tip)
    /// and 0x10 were observed toggling independently but aren't read here: tip
    /// contact is inferred from pressure instead, and 0x10's role (possibly a
    /// near/far proximity-zone flag) doesn't affect current decode correctness.
    private mutating func decodeBPT(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout DecoderState
    ) -> [DecodeResult] {
        let status = report[1]
        let inProximity = (status & 0x20) != 0

        if !inProximity {
            guard state.prevInProximity else { return [] }
            state.prevInProximity = false
            return [
                .pen(
                    TabletPoint(
                        x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: false, penButton2: false,
                        eraser: state.isEraser, inProximity: false, hoverDistance: 0))
            ]
        }

        let isEraser = (status & 0x08) != 0
        var results: [DecodeResult] = []

        if !state.prevInProximity {
            state.isEraser = isEraser
            state.prevInProximity = true
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
        state.lastX = x
        state.lastY = y
        let pressure = Int(UInt16(report[6]) | UInt16(report[7]) << 8)

        results.append(
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,  // Tilt not reported by BAMBOO_PT
                    penButton1: (status & 0x02) != 0,
                    penButton2: (status & 0x04) != 0,
                    eraser: isEraser,
                    inProximity: true,
                    hoverDistance: Int(report[8]))))

        return results
    }

    // MARK: - BAMBOO_PT touch report (Report ID 0x02, 20 bytes)

    /// Kernel `wacom_bpt_touch()` layout — see the type-level doc comment for
    /// the byte diagram. Two fixed slots; an empty result means both fingers
    /// lifted, matching `DecodeResult.touch`'s documented convention.
    private func decodeBPTTouch(
        report: HIDReport,
        spec: DigitizerSpec
    ) -> [DecodeResult] {
        let padByte = report[1]
        var contacts: [TouchContact] = []
        for i in 0..<2 {
            let offset = (padByte & 0x80) != 0 ? 8 * i : 9 * i
            let xHi = report[offset + 3]
            guard (xHi & 0x80) != 0 else { continue }
            let x = Int((UInt16(xHi) << 8 | UInt16(report[offset + 4])) & 0x07FF)
            let y = Int((UInt16(report[offset + 5]) << 8 | UInt16(report[offset + 6])) & 0x07FF)
            contacts.append(TouchContact(id: i, x: x, y: y, contactArea: nil, contactMinor: nil))
        }

        var results: [DecodeResult] = [.touch(contacts)]
        if spec.buttonCount > 0 {
            let buttons = [
                (padByte & 0x08) != 0,  // BTN_0
                (padByte & 0x04) != 0,  // BTN_1
                (padByte & 0x02) != 0,  // BTN_2
                (padByte & 0x01) != 0,  // BTN_3
            ]
            results.append(.aux(AuxButtons(buttons: buttons)))
        }
        return results
    }

    // MARK: - Bamboo Pad container (0x10, 32/64 bytes)

    /// Layout from the pad's own descriptors. [1] says which halves are
    /// live: bit 0 pen, bit 1 touch. [2..8] is the pen interface's report 3
    /// minus its ID: flags (bit 0 tip, 1 barrel, 2 eraser, 3 invert, 5 in
    /// range), then X, Y, and pressure as LE u16. [9] is the touch header:
    /// bits 0–3 mark live fingers, 0x40 and 0x80 the two click buttons. Each
    /// finger at [10 + 3n] packs 12-bit X and Y. No capture exists yet.
    private func decodeBambooPad(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout DecoderState
    ) -> [DecodeResult] {
        var results: [DecodeResult] = []
        let parts = report[1]
        let flags = report[2]
        let penInRange = (parts & 0x01) != 0 && (flags & 0x20) != 0

        if penInRange {
            let isEraser = (flags & 0x0C) != 0
            if !state.prevInProximity {
                state.prevInProximity = true
                state.isEraser = isEraser
                results.append(
                    .toolEnter(
                        ToolIdentity(
                            serial: 0, toolCode: isEraser ? 0x080A : 0x0802,
                            isEraser: isEraser, isMouse: false)))
            }
            let x = Int(UInt16(report[3]) | UInt16(report[4]) << 8)
            let y = Int(UInt16(report[5]) | UInt16(report[6]) << 8)
            let pressure = Int(UInt16(report[7]) | UInt16(report[8]) << 8)
            state.lastX = x
            state.lastY = y
            results.append(
                .pen(
                    TabletPoint(
                        x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: (flags & 0x01) != 0 || (flags & 0x04) != 0 ? pressure : 0,
                        maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: (flags & 0x02) != 0, penButton2: false,
                        eraser: state.isEraser, inProximity: true, hoverDistance: 0)))
        } else if state.prevInProximity {
            state.prevInProximity = false
            results.append(
                .pen(
                    TabletPoint(
                        x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: false, penButton2: false,
                        eraser: state.isEraser, inProximity: false, hoverDistance: 0)))
        }

        if (parts & 0x02) != 0 {
            let header = report[9]
            var contacts: [TouchContact] = []
            for id in 0..<4 where (header & (1 << id)) != 0 {
                let base = 10 + id * 3
                let x = Int(report[base]) | (Int(report[base + 1] & 0x0F) << 8)
                let y = (Int(report[base + 2]) << 4) | (Int(report[base + 1]) >> 4)
                contacts.append(TouchContact(id: id, x: x, y: y, contactArea: nil, contactMinor: nil))
            }
            results.append(.touch(contacts))
            if spec.buttonCount > 0 {
                results.append(.aux(AuxButtons(buttons: [(header & 0x40) != 0, (header & 0x80) != 0])))
            }
        }
        return results
    }

    // MARK: - Pad buttons

    private func decodePad(
        report: HIDReport,
        spec: DigitizerSpec
    ) -> [DecodeResult] {
        let padByte = report[7]
        let buttons: [Bool]
        if spec.buttonCount >= 4 {
            // CTH-460/470/480/490 four-button layout (kernel wacom_bpt_pad).
            buttons = [
                (padByte & 0x08) != 0,  // BTN_0 (top-left)
                (padByte & 0x20) != 0,  // BTN_1
                (padByte & 0x10) != 0,  // BTN_2
                (padByte & 0x40) != 0,  // BTN_3 (bottom-left)
            ]
        } else {
            // CTL-460/470/660 two-button layout.
            buttons = [
                (padByte & 0x01) != 0,  // BTN_0
                (padByte & 0x02) != 0,  // BTN_1
            ]
        }
        return [.aux(AuxButtons(buttons: buttons))]
    }
}
