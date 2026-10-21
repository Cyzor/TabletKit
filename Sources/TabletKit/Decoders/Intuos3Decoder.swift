// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom Intuos3 HID report format (PTZ-xxx, 2003–2006).
///
/// Named for Wacom's generation; unrelated to `IntuosV3Decoder`, which
/// covers the PTK-470/670/870. Covers the PTZ-431, 431W, 631, 631W (0x00B5),
/// 930, 1231, and 1231W.
///
/// **Differs from IntuosV1Decoder in three ways:**
///
/// 1. Proximity — bit 5 (`0x20`), as on IntuosV1, but frames with bit 6
///    clear are ordinary data. Both public Intuos3 recordings send runs of
///    `0xA0` (pen) and `0xB0` (puck) at zero pressure as the tool rises or
///    sits at an edge, with real positions; the kernel decodes them too.
///    Only `0x80` ends proximity. No Art Pen escalation.
///
/// 2. Aux report IDs:
///    - `0x03` (10-byte): 8 express keys packed in byte 4. *Not* a BLE pad report.
///    - `0x0C` (10-byte): touch strips in bytes 1–4, plus a 4+4 express key
///      split in the low nibbles of bytes 5 (keys 0–3) and 6 (keys 4–7).
///
/// 3. No BLE pen or 0x11 aux reports.
///
/// Everything else (USB pen coordinates, pressure, tilt, tool-change packets,
/// wireless status, mouse subtypes) is identical to IntuosV1Decoder.
package struct Intuos3Decoder: TabletReportDecoder {

    /// Creates a decoder. ``DeviceDecoder`` keeps one per device, with its state.
    public init() {}

    /// Decodes one report. See ``TabletReportDecoder/decode(report:spec:state:deviceFamily:)``.
    public func decode(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard report.count >= 2 else { return [] }
        let id = report[0]

        // Intuos3 express key — 8 keys in byte 4.
        if id == 0x03 {
            guard report.count >= 10 else { return [] }
            let byte = report[4]
            return [.aux(AuxButtons(buttons: (0..<8).map { (byte & (1 << $0)) != 0 }))]
        }

        // Intuos3 pad report (report ID 0x0C, 10 bytes).
        //
        //   Bytes 1–4: left and right touch strips, each a big-endian one-hot
        //   mask of 13 zones; zero means no contact.
        //   Bytes 5–6: express keys, 4 per low nibble. Zero on PTZ-631W.
        //
        // Bit 0 is the bottom zone on PTZ-631W, where strip scrolling runs the
        // right way. A PTZ-630 recording puts bit 0 at the top; unconfirmed.
        if id == 0x0C {
            guard report.count >= 5 else { return [] }

            // Touch strips — bytes 1–4.
            let leftRaw = UInt16(report.be16(at: 1))
            let rightRaw = UInt16(report.be16(at: 3))
            let leftActive = leftRaw != 0
            let rightActive = rightRaw != 0

            // Express keys (4+4 split variant) — bytes 5–6.  Zero on PTZ-631W.
            var buttons = [Bool](repeating: false, count: 8)
            if report.count >= 7 {
                let lo = report[5]
                let hi = report[6]
                buttons =
                    (0..<4).map { (lo & (1 << $0)) != 0 }
                    + (0..<4).map { (hi & (1 << $0)) != 0 }
            }

            return [
                .aux(
                    AuxButtons(
                        buttons: buttons,
                        touchStrip1Active: leftActive,
                        touchStrip1Position: leftActive
                            ? UInt8(leftRaw.trailingZeroBitCount) : 0xFF,
                        touchStrip2Active: rightActive,
                        touchStrip2Position: rightActive
                            ? UInt8(rightRaw.trailingZeroBitCount) : 0xFF))
            ]
        }

        if id == 0x80 {
            return decodeWirelessReport(report: report)
        }

        guard (id == 0x02 || id == 0x10) && report.count >= 10 else { return [] }
        return decodeUSBPen(
            report: report, spec: spec, state: &state, deviceFamily: deviceFamily)
    }

    // MARK: - USB pen report (10-byte IntuosV1 format, Intuos3 status layout)

    private func decodeUSBPen(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let status = report[1]

        // Tool-change packet: status bits 7:2 == 0xC0.
        // Same pre-check as IntuosV1 — must fire before proximity test.
        if (status & 0xFC) == 0xC0 {
            return decodeToolChange(report: report, state: &state, deviceFamily: deviceFamily)
        }

        let inProximity = (status & 0x20) != 0
        let subtype = (status >> 1) & 0x0F

        // In range but not reporting position (0x20 or 0x21): bytes 6–8 are
        // zero, so decoding them would peg tilt and hover. Mid-stroke, hold
        // the position with the tip up, as the kernel does.
        if (status & 0xFE) == 0x20 {
            guard state.prevInProximity else { return [] }
            return [
                .pen(
                    TabletPoint(
                        x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: false, penButton2: false,
                        eraser: state.isEraser, inProximity: true,
                        hoverDistance: IntuosV1Decoder.maxHoverDistance))
            ]
        }

        if !inProximity {
            state.prevInProximity = false
            state.toolIsMouse = false
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

        var results: [DecodeResult] = []

        // Fallback onToolEnter on first proximity entry (no prior tool-change packet).
        if !state.prevInProximity {
            let isMouse = subtype == 0x06 || subtype == 0x08
            state.toolIsMouse = isMouse
            if state.currentToolCode == 0 {
                let fallbackCode: UInt16 =
                    isMouse
                    ? (subtype == 0x06 ? 0x0806 : 0x0016)
                    : (state.isEraser ? 0x080A : 0x0802)
                results.append(
                    .toolEnter(
                        ToolIdentity(
                            serial: 0, toolCode: fallbackCode,
                            isEraser: state.isEraser, isMouse: isMouse)))
            }
        }
        state.prevInProximity = true

        let (x, y) = IntuosPenPacket.position(report)
        state.lastX = x
        state.lastY = y

        if let mouse = IntuosPenPacket.mousePoint(report, subtype: subtype, x: x, y: y, spec: spec) {
            results.append(.pen(mouse))
            return results
        }

        // Pen path — same pressure and tilt encoding as IntuosV1.
        let pressure = IntuosPenPacket.pressure(
            report, maxPressure: spec.maxPressure, statusBit: spec.maxPressure > 1023)
        let tilt = IntuosPenPacket.tilt(report)

        results.append(
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: tilt.x,
                    tiltY: tilt.y,
                    rotation: 0.0,
                    penButton1: (status & 0x02) != 0,
                    penButton2: (status & 0x04) != 0,
                    eraser: state.isEraser,
                    inProximity: true,
                    hoverDistance: (Int(report[9]) >> 2))))
        return results
    }

    // MARK: - Tool-change packet

    private func decodeToolChange(
        report: HIDReport,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let (serial, toolCode) = IntuosPenPacket.toolChange(report)

        state.lastSerial = serial
        state.currentToolCode = toolCode
        state.isEraser = (toolCode & 0x0008) != 0
        state.toolIsMouse = (toolCode & 0x000F) == 0x0006

        return [
            .toolEnter(
                ToolIdentity(
                    serial: serial, toolCode: toolCode,
                    isEraser: state.isEraser, isMouse: state.toolIsMouse))
        ]
    }

}

extension Intuos3Decoder {
    /// What this decoder remembers between reports.
    package struct State: DecoderState {
        /// Last X, held for frames that carry no position.
        package var lastX: Int = 0
        /// Last Y, held for frames that carry no position.
        package var lastY: Int = 0
        /// Serial at the last tool change.
        package var lastSerial: UInt32 = 0
        /// The tool in range.
        package var currentToolCode: UInt16 = 0
        /// Whether the last report had the pen in range.
        package var prevInProximity: Bool = false
        /// Whether the eraser end is in range, held through weak frames.
        package var isEraser: Bool = false
        /// Whether the tool in range is a mouse.
        package var toolIsMouse: Bool = false

        package init() {}
    }
}
