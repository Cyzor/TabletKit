// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom DTU HID report format.
///
/// Used by the DTU-2231 (0x00CE) and DTU-1631 (0x00F0). Ported from
/// input-wacom's `wacom_dtu_irq`; not yet validated on hardware.
///
/// One 8-byte pen report (ID 0x02, unchecked, as in the kernel). No pad,
/// tilt, rotation, hover distance, or serial. Unlike `DTUSDecoder`,
/// coordinates are little-endian and pressure is 9-bit.
package struct DTUDecoder: TabletReportDecoder {

    /// Creates a decoder. ``DeviceDecoder`` keeps one per device, with its state.
    public init() {}

    /// Decodes one report. See ``TabletReportDecoder/decode(report:spec:state:deviceFamily:)``.
    public func decode(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard report.count >= 8 else { return [] }
        return decodePenReport(report: report, spec: spec, state: &state)
    }

    // MARK: - Pen report

    /// `wacom_dtu_irq` layout (8+ bytes):
    ///   [0]     report ID 0x02
    ///   [1]     flags byte:
    ///             bit 5 (0x20): proximity
    ///             bit 4 (0x10): BTN_STYLUS2 (barrel button 2)
    ///             bits 3–2 (0x0C): tool type — non-zero = eraser
    ///             bit 1 (0x02): BTN_STYLUS (barrel button 1)
    ///   [2–3]   X, LE u16
    ///   [4–5]   Y, LE u16
    ///   [6–7]   pressure, 9 bits (0–511)
    private func decodePenReport(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State
    ) -> [DecodeResult] {
        let flags = report[1]
        let prox = (flags & 0x20) != 0

        if !prox {
            guard state.prevInProximity else { return [] }
            state.prevInProximity = false
            return [
                .pen(
                    TabletPoint(
                        x: state.lastX, y: state.lastY,
                        maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: false, penButton2: false,
                        eraser: false, inProximity: false, hoverDistance: 0))
            ]
        }

        let x = report.le16(at: 2)
        let y = report.le16(at: 4)
        let pressure = report.le16(at: 6) & 0x1FF
        let isEraser = (flags & 0x0C) != 0

        state.prevInProximity = true
        state.lastX = x
        state.lastY = y

        return [
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: (flags & 0x02) != 0,
                    penButton2: (flags & 0x10) != 0,
                    eraser: isEraser,
                    inProximity: true,
                    hoverDistance: 0))
        ]
    }
}

extension DTUDecoder {
    /// What this decoder remembers between reports.
    package struct State: DecoderState {
        /// Last X, held for frames that carry no position.
        package var lastX: Int = 0
        /// Last Y, held for frames that carry no position.
        package var lastY: Int = 0
        /// Whether the last report had the pen in range.
        package var prevInProximity: Bool = false

        package init() {}
    }
}
