// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom Bamboo consumer HID report format.
///
/// Used by the CTT-460, CTH-460/461/470/480/490, CTH-661/670, CTL-460/470/660,
/// and related Bamboo and Wacom One models. Report layouts, by ID and length:
///
/// **0x02, 9 bytes:** the 2009–2011 Bamboo pen (kernel `wacom_bpt_pen()`),
/// sent once feature report `[0x02, 0x02]` takes the tablet out of mouse
/// mode (see `TabletSpec.initSteps`). Confirmed on a CTL-460 (0x00D4). The
/// INTUOSHT models (CTH-480/680, CTL-480/680) send the same layout at 10
/// bytes. Their INTUOSHT2 successors (CTH-490/690, CTL-490/690) use
/// `.intuosV1`; see `BPT3ContainerDecoder` for the generations.
///
/// **0x02, 64 bytes:** the BPT3 touch/pad container, passed to
/// `BPT3ContainerDecoder`. Checked before the pen path, which shares the ID.
///
/// **0x02, 20 bytes:** touch on the older CTH-460/461 (kernel
/// `wacom_bpt_touch()`), on its own interface. Two fixed slots of big-endian
/// 11-bit coordinates in a 480×320 space, plus the 4 express keys in byte 1.
/// From the kernel; no capture exists.
/// ```
/// [0]  0x02   Report ID
/// [1]  bit 7: contact stride — 8 bytes/contact if set, 9 if clear
///      bit 3: BTN_0   bit 2: BTN_1   bit 1: BTN_2   bit 0: BTN_3
/// For i in 0, 1, at offset = (bit7 ? 8*i : 9*i):
///   [offset+3] bit 7: contact down; bits 6:0 + [offset+4]: X, BE16 & 0x7FF
///   [offset+5:6]                     Y, BE16 & 0x7FF
/// ```
/// Touch on the CTH-480/680 and the CTH-470/670 arrives in the BPT3
/// container instead.
///
/// **0x10, 32 or 64 bytes:** the Bamboo Pad's combined pen and touch
/// container; see `decodeBambooPad`.
///
/// The CTT-460 is touch-only, with no pen interface or buttons.
package struct BambooDecoder: TabletReportDecoder {

    /// Creates a decoder. ``DeviceDecoder`` keeps one per device, with its state.
    public init() {}

    /// Decodes one report. See ``TabletReportDecoder/decode(report:spec:state:deviceFamily:)``.
    public mutating func decode(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        // Report ID 0x02 is overloaded on INTUOSHT hardware: a 9/10-byte pen
        // report and a 64-byte touch/pad container share it, distinguished only
        // by length. Dispatch on length before anything else — without this the
        // container would be decoded as pen coordinates.
        guard report.count > 0 else { return [] }
        if report[0] == 0x02, report.count == BPT3ContainerDecoder.reportLength {
            return BPT3ContainerDecoder.decode(report: report, spec: spec, slots: &state.bpt3TouchSlots)
        }
        if report[0] == 0x02, report.count == 20 {
            return decodeBPTTouch(report: report, spec: spec)
        }
        if report[0] == 0x02, (9...10).contains(report.count) {
            return decodeBPT(report: report, spec: spec, state: &state)
        }
        // Bamboo Pad (CTH-300/301): pen and touch share one 0x10 container,
        // 32 bytes wireless or 64 over USB.
        if report[0] == 0x10, report.count == 32 || report.count == 64 {
            return decodeBambooPad(report: report, spec: spec, state: &state)
        }
        return []
    }

    // MARK: - BAMBOO_PT pen report (Report ID 0x02, 9 bytes)

    /// Kernel `wacom_bpt_pen()` layout:
    /// ```
    /// [0] 0x02 Report ID
    /// [1] status — bit 0 tip, bit 1 barrel 1, bit 2 barrel 2,
    ///              bit 3 eraser tool, bit 5 ready (pressure and barrels
    ///              valid), bit 6 position valid, bit 7 in range
    /// [2:3] X  LE16    [4:5] Y  LE16    [6:7] pressure LE16
    /// [8] hover distance
    /// ```
    /// No express-key bits here — CTH pad buttons ride the separate touch
    /// interface, and the CTL pen-only models have no express keys at all.
    ///
    /// As in the kernel, the pen arrives with its first position and stays
    /// until the range bit clears, and only the tip bit means contact.
    /// High in the hover the tablet sends a position without the ready bit,
    /// and pressure runs ahead of the tip bit as the pen lands and lifts.
    /// Bit 0x10's role is unknown.
    private mutating func decodeBPT(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State
    ) -> [DecodeResult] {
        let status = report[1]
        let inRange = (status & 0x80) != 0
        let hasPosition = (status & 0x40) != 0
        let ready = (status & 0x20) != 0

        if !inRange {
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

        guard hasPosition || state.prevInProximity else { return [] }
        var results: [DecodeResult] = []

        if hasPosition {
            let isEraser = (status & 0x08) != 0
            if !state.prevInProximity {
                state.prevInProximity = true
                results.append(
                    .toolEnter(
                        ToolIdentity(
                            serial: 0,
                            toolCode: isEraser ? 0x080A : 0x0802,
                            isEraser: isEraser,
                            isMouse: false)))
            }
            state.isEraser = isEraser
            state.lastX = report.le16(at: 2)
            state.lastY = report.le16(at: 4)
        }

        let touching = ready && (status & 0x01) != 0
        let pressure = touching ? report.le16(at: 6) : 0

        results.append(
            .pen(
                TabletPoint(
                    x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,  // Tilt not reported by BAMBOO_PT
                    penButton1: ready && (status & 0x02) != 0,
                    penButton2: ready && (status & 0x04) != 0,
                    eraser: state.isEraser,
                    inProximity: true,
                    hoverDistance: Int(report[8]))))

        return results
    }

    // MARK: - BAMBOO_PT touch report (Report ID 0x02, 20 bytes)

    /// Kernel `wacom_bpt_touch()` layout; see the type's doc comment. An
    /// empty result means both fingers lifted.
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
            let x = report.be16(at: offset + 3) & 0x07FF
            let y = report.be16(at: offset + 5) & 0x07FF
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
        state: inout State
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
            let x = report.le16(at: 3)
            let y = report.le16(at: 5)
            let pressure = report.le16(at: 7)
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
                let x = report.le16(at: base) & 0x0FFF
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
}

extension BambooDecoder {
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
        /// Active BPT3 touch contacts by slot. Containers carry only changes.
        package var bpt3TouchSlots: [Int: TouchContact] = [:]

        package init() {}
    }
}
