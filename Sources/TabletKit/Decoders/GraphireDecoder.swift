// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom Graphire / PenPartner / Volito / early consumer line.
///
/// Ported from the kernel's `wacom_graphire_irq()`. Covers USB Graphire 2–4
/// (0x0011–0x0017), PenPartner (0x0003), the original Graphire
/// (0x0004/0x0010), and the Volito, PenStation, and Bamboo One CTF-430.
/// `WACOM_MO` (Bamboo Fun CTE-450/650, MTE-450) shares the pen path and has
/// its own pad and ring layout in `decodePad`; the pen path is confirmed on
/// a CTE-650. The Graphire Wireless (CTE-630BT, 0x0081) sends the same
/// report over Bluetooth with its own ID and bytes 6–7; see `isGraphireBluetooth`.
///
/// **Report layout — Report ID 0x02 (kernel `WACOM_REPORT_PENABLED`), 8 bytes:**
/// ```
/// [0]  0x02   Report ID
/// [1]  status — see below
/// [2:3] X     LE16
/// [4:5] Y     LE16
/// [6]   pressure low byte / mouse wheel (signed) / G4 distance
/// [7]   pressure high (bits 0-1) / pad buttons and mouse wheel (G4) / distance
/// ```
///
/// **Status byte d[1]:**
/// ```
/// bit 7  (0x80)  in proximity
/// bits 5..6 (0x60)  tool: 0=pen, 1=eraser, 2=mouse-with-wheel, 3=mouse
/// bit 2  (0x04)  BTN_STYLUS2 / mouse middle
/// bit 1  (0x02)  BTN_STYLUS  / mouse right
/// bit 0  (0x01)  BTN_TOUCH   / mouse left
/// ```
///
/// Pen pressure is 10-bit, in bytes 6–7, and counts only while the tablet
/// sets BTN_TOUCH. Distance is `d[7] & 0x3F`. Out of range, the report
/// carries the pad; see `decodePad`.
///
/// **Graphire Wireless — Report ID 0x03, 8 bytes** (kernel `GRAPHIRE_BT`):
/// pressure is 9-bit, `d[6]` plus status bit 3 as its top bit; the mouse
/// wheel is `d[6]` bits 0–1; `d[7]` holds the two pad buttons in bits 1 and 0
/// and a battery level in bits 2–4.
package struct GraphireDecoder: TabletReportDecoder {

    /// Creates a decoder. ``DeviceDecoder`` keeps one per device, with its state.
    public init() {}

    /// Decodes one report. See ``TabletReportDecoder/decode(report:spec:state:deviceFamily:)``.
    public mutating func decode(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let bluetooth = spec.isGraphireBluetooth
        guard report.count >= 8, report[0] == (bluetooth ? 0x03 : 0x02) else { return [] }

        let status = report[1]
        let inProximity = (status & 0x80) != 0
        // Tool field: 0=pen, 1=eraser, 2=mouse w/wheel, 3=mouse no wheel.
        let toolField = (status >> 5) & 0x03
        let isMouse = toolField == 2 || toolField == 3
        let isEraser = toolField == 1

        var results: [DecodeResult] = []
        if bluetooth { appendBattery(&results, report: report, state: &state) }

        // ── Proximity exit ────────────────────────────────────────────────────
        if !inProximity {
            if state.prevInProximity {
                state.prevInProximity = false
                let exitEraser = state.isEraser
                state.isEraser = false
                results.append(
                    .pen(
                        TabletPoint(
                            x: state.lastX, y: state.lastY,
                            maxX: spec.maxX, maxY: spec.maxY,
                            pressure: 0, maxPressure: spec.maxPressure,
                            tiltX: 0, tiltY: 0, rotation: 0.0,
                            penButton1: false, penButton2: false,
                            eraser: exitEraser, inProximity: false, hoverDistance: 0)))
            }
            appendPad(&results, report: report, spec: spec)
            return results
        }

        // ── Pen / eraser / mouse in proximity ────────────────────────────────
        // Fire toolEnter on rising edge.
        if !state.prevInProximity {
            state.prevInProximity = true
            state.isEraser = isEraser
            state.toolIsMouse = isMouse
            // Synthetic tool codes consistent with BambooDecoder:
            //   0x080A = eraser, 0x0802 = pen, 0x0007 = generic mouse.
            let toolCode: UInt16 = isMouse ? 0x0007 : (isEraser ? 0x080A : 0x0802)
            results.append(
                .toolEnter(
                    ToolIdentity(
                        serial: 0,
                        toolCode: toolCode,
                        isEraser: isEraser,
                        isMouse: isMouse)))
        }

        let x = report.le16(at: 2)
        let y = report.le16(at: 4)
        state.lastX = x
        state.lastY = y

        if isMouse {
            // No pressure. Pad models (Graphire 4, Bamboo Fun) carry the
            // wheel in d[7] bits 0–2; the rest send -(signed)d[6]. Both as
            // in the kernel.
            let wheelDelta =
                bluetooth
                ? (toolField == 2 ? ((report[6] & 0x01) != 0 ? -1 : (report[6] & 0x02) != 0 ? 1 : 0) : 0)
                : spec.buttonCount > 0
                ? Int(report[7] & 0x04) - Int(report[7] & 0x03)
                : -Int(Int8(bitPattern: report[6]))
            results.append(
                .pen(
                    TabletPoint(
                        x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        // Left, right, then middle in bits 0–2, as in the
                        // kernel; slots match the Intuos mice.
                        penButton1: (status & 0x01) != 0,
                        penButton2: (status & 0x02) != 0,
                        eraser: false,
                        inProximity: true,
                        hoverDistance: 0,
                        mouseMiddleButton: (status & 0x04) != 0,
                        mouseWheelDelta: wheelDelta)))
            return results
        }

        // The tablet's own contact bit decides touch, as in the kernel. Bytes
        // 6–7 also carry light pressure while approaching, sliding, and
        // lifting, which would otherwise press and drag. Capped so the 8-bit
        // PenPartner isn't fed a 10-bit value.
        let touching = (status & 0x01) != 0
        let raw = bluetooth ? Int(report[6]) | Int(status & 0x08) << 5 : report.le16(at: 6) & 0x3FF
        let pressure = touching ? min(raw, spec.maxPressure) : 0
        // Pad models carry button bits in d[7], so no distance for them, as
        // in the kernel.
        let hoverDistance = spec.buttonCount > 0 ? 0 : Int(report[7] & 0x3F)

        results.append(
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: (status & 0x02) != 0,
                    penButton2: (status & 0x04) != 0,
                    eraser: isEraser,
                    inProximity: true,
                    hoverDistance: hoverDistance)))
        appendPad(&results, report: report, spec: spec)

        return results
    }

    // MARK: - Pad (Graphire 4 only)

    /// The kernel reads the pad from every report, pen in range or not; pad
    /// bits never overlap the pressure bits (d[7] & 0x03).
    private func appendPad(
        _ results: inout [DecodeResult], report: HIDReport, spec: DigitizerSpec
    ) {
        guard spec.buttonCount > 0 else { return }
        results.append(contentsOf: decodePad(report: report, spec: spec))
    }

    /// Decode the pad from d[7] (and d[8] on WACOM_MO).
    /// Kernel reference: `wacom_graphire_irq()` WACOM_G4 / WACOM_MO branches.
    ///
    /// G4 (2 buttons): d[7] bit 6 = BTN_BACK, bit 7 = BTN_FORWARD,
    /// bits 3..5 = relative wheel.
    ///
    /// MO — Bamboo Fun CTE-450/650, Bamboo MTE-450 (4 buttons + ring):
    /// d[7] 0x08 = BACK, 0x10 = FORWARD, 0x20/0x40 = lower-left/right FN;
    /// d[8] bit 7 = finger on ring, bits 0..6 = position 0–71.
    /// Emitted in reading order (upper-left, upper-right, lower-left,
    /// lower-right) — kernel key names matched to the CTE-650 manual's
    /// layout. A capture confirms the bits, not which bit is which key.
    private func decodePad(
        report: HIDReport,
        spec: DigitizerSpec
    ) -> [DecodeResult] {
        let padByte = report[7]
        if spec.isGraphireBluetooth {
            return [.aux(AuxButtons(buttons: [(padByte & 0x02) != 0, (padByte & 0x01) != 0]))]
        }
        // Only the MO models have four buttons; G4 has two.
        if spec.buttonCount >= 4, report.count >= 9 {
            let ringByte = report[8]
            let ringActive = (ringByte & 0x80) != 0
            return [.aux(AuxButtons(
                buttons: [
                    (padByte & 0x08) != 0,   // < (BACK)
                    (padByte & 0x10) != 0,   // > (FORWARD)
                    (padByte & 0x20) != 0,   // FN, lower left
                    (padByte & 0x40) != 0,   // FN, lower right
                ],
                touchRingActive: ringActive,
                touchRingPosition: ringActive ? ringByte & 0x7F : 0x7F))]
        }
        // Two physical buttons on Graphire 4 — map to AuxButtons[0..1].
        let buttons = [
            (padByte & 0x40) != 0,   // BTN_BACK
            (padByte & 0x80) != 0,   // BTN_FORWARD
        ]
        return [.aux(AuxButtons(buttons: buttons))]
    }

    /// The Graphire Wireless's battery, from `d[7]` bits 2–4, when it
    /// changes. Level 7 means it's plugged in; the percentages are the kernel's.
    private func appendBattery(_ results: inout [DecodeResult], report: HIDReport, state: inout State) {
        let level = Int(report[7] >> 2 & 0x07)
        guard level != state.lastBatteryLevel else { return }
        state.lastBatteryLevel = level
        let percent = [1, 15, 25, 35, 50, 70, 100, 100][level]
        results.append(.battery(percent: percent, charging: level == 7))
    }
}

extension GraphireDecoder {
    /// What this decoder remembers between reports.
    package struct State: DecoderState {
        /// Last X, held for frames that carry no position.
        package var lastX: Int = 0
        /// Last Y, held for frames that carry no position.
        package var lastY: Int = 0
        /// Whether the last report had the pen in range.
        package var prevInProximity: Bool = false
        /// Whether the eraser end is in range, held through weak frames.
        package var isEraser: Bool = false
        /// Whether the tool in range is a mouse.
        package var toolIsMouse: Bool = false
        /// The Graphire Wireless's last battery level, sent again only on a change.
        package var lastBatteryLevel: Int? = nil

        package init() {}
    }
}
