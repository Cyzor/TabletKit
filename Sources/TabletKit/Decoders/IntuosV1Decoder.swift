// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom IntuosV1 HID report format.
///
/// "V1" is TabletKit's protocol generation, not Wacom's: Intuos3 (PTZ-xxx)
/// hardware uses `Intuos3Decoder`. Used by the PTH-851 (0x0317), DTK-2400
/// (0x00F4), and other tablets with the 10-byte IntuosV1 layout.
///
/// Report IDs:
///   0x01  BLE pen report (23 bytes)
///   0x02  USB pen report (10 bytes), or the 64-byte BPT3 touch/pad
///         container on INTUOSHT2 models (CTH-690)
///   0x03  pad: ring + express keys (10 bytes), over USB and the
///         ACK-40401 dongle alike; or, at 22 bytes, a PTK-540WL Bluetooth
///         batch of 2 frames + power byte
///   0x04  PTK-540WL Bluetooth batch of 3 frames + power byte (32 bytes)
///   0x0C  Intuos4 (PTK-xxx) pad: ring + express keys
///   0x10  USB pen report (10 bytes)
///   0x11  express keys on some models; not seen on PTH-850
///   0x80  wireless status (ACK-40401 dongle)
///
/// BLE pressure is 13-bit, so BLE reports use a max of 8191.
package struct IntuosV1Decoder: TabletReportDecoder {

    /// Creates a decoder. ``DeviceDecoder`` keeps one per device, with its state.
    public init() {}

    /// Hover field is `report[9] >> 2`, six bits — the kernel's
    /// `distance_max` equivalent.
    static let maxHoverDistance = 63

    /// Decodes one report. See ``TabletReportDecoder/decode(report:spec:state:deviceFamily:)``.
    public func decode(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard report.count >= 2 else { return [] }
        let id = report[0]

        if id == 0x01 && report.count >= 11 {
            return decodeBLEPen(
                report: report, spec: spec, state: &state,
                deviceFamily: deviceFamily)
        }
        if id == 0x03 && report.count >= 22 {
            return decodeIntuos4WLAggregated(report: report, spec: spec, state: &state, deviceFamily: deviceFamily)
        }
        if id == 0x04 && report.count >= 32 {
            return decodeIntuos4WLAggregated(report: report, spec: spec, state: &state, deviceFamily: deviceFamily)
        }
        if id == 0x03 && report.count >= 5 {
            guard let aux = decodeBLEPadAux(report: report) else { return [] }
            return [.aux(aux)]
        }
        if id == 0x11 {
            // The Cintiq 13HD and 13HD Touch are this parser's only pen displays.
            return deviceFamily == .cintiq
                ? decode13HDPadReport(report: report)
                : decodeAuxReport(report: report)
        }
        if id == 0x0C {
            return decodeIntuos4PadReport(report: report)
        }
        if id == 0x80 {
            return decodeWirelessReport(report: report)
        }
        // BPT3 touch/pad container: 64-byte Report ID 0x02 on INTUOSHT2-family
        // models (CTH-690). Gated on length alone — touch and pad are gated
        // independently inside, so pen-only models still get their express keys.
        if id == 0x02 && report.count == BPT3ContainerDecoder.reportLength {
            return BPT3ContainerDecoder.decode(report: report, spec: spec, slots: &state.bpt3TouchSlots)
        }
        // USB pen reports are exactly 10 bytes; anything longer here would
        // read as garbage coordinates.
        guard (id == 0x02 || id == 0x10) && report.count == 10 else { return [] }
        return decodeUSBPen(
            report: report, spec: spec, state: &state, deviceFamily: deviceFamily)
    }

    // MARK: - USB pen report (10-byte IntuosV1)

    private func decodeUSBPen(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let status = report[1]

        // Tool-change packet: status bits 7:2 == 0xC0.
        // Must check BEFORE testing the inProximity bit — status 0xC0 has that bit clear
        // and would otherwise fall through to proximity-out logic.
        if (status & 0xFC) == 0xC0 {
            return decodeToolChange(report: report, state: &state, deviceFamily: deviceFamily)
        }

        // IntuosV1 status byte: bit5=proximity, bit6=highConfidence.
        // Kernel model: exit when !prox && !conf (both bits clear).
        // At boundary: proximity stays 1 but confidence drops first (0x60 → 0x40 → 0x20 → 0x00).
        // Art Pen rotation sensor causes transient oscillations - threshold boundary noise.
        let inProximity = (status & 0x20) != 0
        let highConfidence = (status & 0x40) != 0
        let isExitSignal = !inProximity && !highConfidence
        // Matches 0x20/0x21 only, not every confidence-clear status: 0xA0
        // is also proximity-set/confidence-clear but an ordinary hover with
        // real pressure (GD-0608, Cyzor/tablet-driver#4).
        let isInRangeOnly = (status & 0xFE) == 0x20

        // Genuine exit: both proximity and confidence lost.
        if isExitSignal {
            if state.prevInProximity {
                state.exitFrameCount = 0
                state.prevInProximity = false
                state.toolIsMouse = false
                // Don't let one tool's wheel position or angle follow the next tool in.
                state.lastAirbrushWheel = nil
                state.lastRotation = 0
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
            return []
        }

        // In-range state, `(data[1] & 0xFE) == 0x20`: a tool is present but
        // the tablet isn't reporting position, and bytes 6-8 arrive zeroed.
        // Decoding them gives tilt -1.02 and hover pegged at 63, the PTH-850
        // wireless chatter. The kernel skips these too.
        //
        // An Art Pen still escalates a sustained run to an exit — its
        // rotation sensor oscillates the confidence bit at the tracking
        // boundary. A plain stylus must not: a hand resting at high hover
        // holds this state, and a fabricated exit resets the BPT3
        // arbitration latch, killing touch for the whole hover.
        if isInRangeOnly {
            let toolHasRotation = ToolCatalog.hasRotation(toolCode: state.currentToolCode)
            state.exitFrameCount += 1
            if toolHasRotation
                && state.exitFrameCount >= proximityExitFrames
                && state.prevInProximity
            {
                state.exitFrameCount = 0
                state.prevInProximity = false
                state.toolIsMouse = false
                // Don't let one tool's wheel position or angle follow the next tool in.
                state.lastAirbrushWheel = nil
                state.lastRotation = 0
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
            // Mid-stroke, mirror the kernel's flush: tip up, hover to max,
            // position held. Otherwise report nothing.
            guard state.prevInProximity else { return [] }
            return [
                .pen(
                    TabletPoint(
                        x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0,
                        rotation: toolHasRotation ? state.lastRotation : 0.0,
                        penButton1: false, penButton2: false,
                        eraser: state.isEraser, inProximity: true,
                        hoverDistance: Self.maxHoverDistance))
            ]
        }
        if highConfidence { state.exitFrameCount = 0 }

        let subtype = (status >> 1) & 0x0F

        // Note: high-confidence bit (status & 0x40) is intentionally not filtered here.
        // PTH-851 lift reports are already low-pressure in the raw bytes; decoding normally
        // lets pressure fall to zero naturally. Tablets with touch (PTH-850 Intuos5) emit
        // low-confidence reports during palm contact mid-stroke — special-casing them would
        // zero pressure and freeze position, breaking continuous dragging.

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
                // Deliberately not stored into `currentToolCode`: leaving it 0
                // keeps this fallback `.toolEnter` firing once per proximity
                // entry on a device that never sends a 0xC2 packet, which is
                // the existing behavior. The rotation-pen check above reads a 0
                // tool code as non-rotation, which is the right default for an
                // unknown tool anyway, so nothing needs it stored.
                results.append(
                    .toolEnter(
                        ToolIdentity(
                            serial: 0, toolCode: fallbackCode,
                            isEraser: state.isEraser, isMouse: isMouse)))

                // Check tool compatibility and emit warning if unsupported
                emitToolCompatibility(
                    toolCode: fallbackCode, deviceFamily: deviceFamily,
                    toolIsSupported: &state.toolIsSupported, results: &results)
            }
        }
        state.prevInProximity = true
        state.toolAnnouncedOutOfRange = false

        let (x, y) = IntuosPenPacket.position(report)
        state.lastX = x
        state.lastY = y

        if let mouse = IntuosPenPacket.mousePoint(report, subtype: subtype, x: x, y: y, spec: spec) {
            results.append(.pen(mouse))
            return results
        }

        // Airbrush second packet (kernel `wacom_intuos_general()` type 0x0a):
        // wheel + tilt, no pressure or buttons. Interleaved with normal pen
        // packets, so cache and let the next one carry it — emitting a `.pen`
        // here (pressure 0) would read as a tip release mid-stroke.
        // Synthesized from kernel source; hardware discontinued and unowned.
        if subtype == 0x0A {
            state.lastAirbrushWheel = (Int(report[6]) << 2) | ((Int(report[7]) >> 6) & 0x03)
            (state.lastTiltX, state.lastTiltY) = IntuosPenPacket.tilt(report)
            state.hasValidTiltFrame = true
            return results
        }

        // Art Pen rotation packet (kernel type 0x05), interleaved one-for-one
        // with pen packets. Bit 1 of its status is part of the type and bytes
        // 6–7 hold the angle, so reading it as a pen packet sent a barrel-1
        // press and bogus pressure on every other report. Confirmed on a
        // PTH-850 with an Intuos4/5 Art Pen. The next pen packet carries the
        // angle.
        if subtype == 0x05 {
            if !state.toolIsMouse { state.lastRotation = intuosRotationDegrees(report) }
            return results
        }

        // Pen path. Intuos5 (PTH-850, maxPressure 2047) carries status bit 0
        // as the lowest pressure bit.
        let pressure = IntuosPenPacket.pressure(
            report, maxPressure: spec.maxPressure, statusBit: spec.maxPressure == 2047)
        let tilt = IntuosPenPacket.tilt(report)

        results.append(
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: tilt.x,
                    tiltY: tilt.y,
                    rotation: ToolCatalog.hasRotation(toolCode: state.currentToolCode)
                        ? state.lastRotation : 0.0,
                    penButton1: (status & 0x02) != 0,
                    penButton2: (status & 0x04) != 0,
                    eraser: state.isEraser,
                    inProximity: true,
                    hoverDistance: (Int(report[9]) >> 2),
                    airbrushWheel: state.lastAirbrushWheel)))
        return results
    }

    // MARK: - Tool-change packet (status bits 7:2 == 0xC0)

    private func decodeToolChange(
        report: HIDReport,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let (serial, toolCode) = IntuosPenPacket.toolChange(report)

        // An Intuos4 at the edge of range repeats this packet between exits
        // with no position in between. Announce that tool once.
        let repeated = state.toolAnnouncedOutOfRange
            && serial == state.lastSerial && toolCode == state.currentToolCode
        state.toolAnnouncedOutOfRange = !state.prevInProximity
        if repeated { return [] }

        state.lastSerial = serial
        state.currentToolCode = toolCode
        state.isEraser = (toolCode & 0x0008) != 0
        state.toolIsMouse = (toolCode & 0x000F) == 0x0006

        var results: [DecodeResult] = [
            .toolEnter(
                ToolIdentity(
                    serial: serial, toolCode: toolCode,
                    isEraser: state.isEraser, isMouse: state.toolIsMouse))
        ]

        // Check tool compatibility and emit warning if unsupported
        emitToolCompatibility(
            toolCode: toolCode, deviceFamily: deviceFamily,
            toolIsSupported: &state.toolIsSupported, results: &results)

        return results
    }

    // MARK: - BLE HOGP pen (0x01)

    private func decodeBLEPen(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        // BLE uses 13-bit pressure regardless of the device's USB maxPressure.
        let bleSpec = DigitizerSpec(maxX: spec.maxX, maxY: spec.maxY, maxPressure: 8191)
        guard
            let result = decodeBLEPenReport(
                report: report, spec: bleSpec,
                lastX: &state.lastX, lastY: &state.lastY
            )
        else { return [] }

        var results: [DecodeResult] = []
        if result.toolCode != 0
            && (result.serial != state.lastSerial || result.toolCode != state.currentToolCode)
        {
            state.lastSerial = result.serial
            state.currentToolCode = result.toolCode
            state.isEraser = result.point.eraser
            state.toolIsMouse = result.isMouse
            results.append(
                .toolEnter(
                    ToolIdentity(
                        serial: result.serial,
                        toolCode: result.toolCode,
                        isEraser: result.point.eraser,
                        isMouse: result.isMouse)))
        }
        results.append(.pen(result.point))
        return results
    }

    // MARK: - Auxiliary (express key) report (0x11)

    /// IntuosV1 (Intuos 5 / PTH-851) has purely mechanical express keys;
    /// report[1] and report[2] are identical.  Use report[1] for consistency
    /// with IntuosV2 decoder convention.
    private func decodeAuxReport(
        report: HIDReport
    ) -> [DecodeResult] {
        guard report.count >= 2 else { return [] }
        let auxByte = report[1]
        return [.aux(AuxButtons(buttons: (0..<8).map { bit in (auxByte & (1 << bit)) != 0 }))]
    }

    /// Cintiq 13HD pad: byte 1 is a fixed 0x80 marker; buttons are
    /// `(report[4] << 1) | (report[3] & 1)`, nine of them (kernel
    /// `wacom_intuos_pad`, WACOM_13HD; matches a DTH-1300 capture).
    private func decode13HDPadReport(
        report: HIDReport
    ) -> [DecodeResult] {
        guard report.count >= 5 else { return [] }
        let mask = Int(report[4]) << 1 | Int(report[3] & 0x01)
        return [.aux(AuxButtons(buttons: (0..<9).map { mask & (1 << $0) != 0 }))]
    }

    // MARK: - Intuos4 WL Bluetooth aggregated reports (0x03 / 0x04)

    /// The PTK-540WL over Bluetooth Classic (0x00BD) batches 2–3 ordinary
    /// 10-byte Intuos4 frames into one report, plus a power byte (kernel
    /// `wacom_intuos_bt_irq`):
    ///   0x03 — [1..10] frame 1, [11..20] frame 2, [21] power
    ///   0x04 — [1..10]/[11..20]/[21..30] frames 1–3, [31] power
    /// The minimum lengths guard an out-of-bounds read, as in the kernel.
    /// Frames decode as on USB. Power byte: bits 2:0 index `batcap_i4`,
    /// bit 3 charging, bit 4 external power. No capture exists.
    private static let batcapI4: [Int] = [1, 15, 30, 45, 60, 70, 85, 100]

    private func decodeIntuos4WLAggregated(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let frameCount = report[0] == 0x03 ? 2 : 3
        let powerIndex = frameCount * 10 + 1
        guard report.count >= powerIndex + 1 else { return [] }

        var results: [DecodeResult] = []
        for frame in 0..<frameCount {
            let base = 1 + frame * 10
            let frameID = report[base]
            if frameID == 0x02 || frameID == 0x10 {
                results.append(contentsOf: decodeUSBPen(
                    report: HIDReport(pointer: report.pointer + base, count: 10), spec: spec,
                    state: &state, deviceFamily: deviceFamily))
            } else if frameID == 0x0C {
                results.append(contentsOf: decodeIntuos4PadReport(
                    report: HIDReport(pointer: report.pointer + base, count: 10)))
            }
            // Other frame IDs (e.g. tool-change packets arrive as ordinary
            // 0x02/0x10 frames with status 0xC0, handled inside decodeUSBPen)
            // need no special casing here.
        }

        let power = report[powerIndex]
        results.append(.battery(
            percent: Self.batcapI4[Int(power & 0x07)],
            charging: (power & 0x08) != 0))
        return results
    }

    // MARK: - Intuos4 pad report (0x0C)

    /// Intuos4 (PTK-xxx) ExpressKeys and touch ring, report 0x0C. The
    /// kernel's `wacom_intuos_pad()` and OTD's `Intuos4AuxReport` agree:
    ///   report[1]      — ring position, bit 0x80 = valid, low 7 bits = 0-71 step
    ///   report[2] bit 0 — ring center (mode-switch) button
    ///   report[3]      — 8 mechanical ExpressKey bits
    /// No capture exists.
    private func decodeIntuos4PadReport(
        report: HIDReport
    ) -> [DecodeResult] {
        guard report.count >= 4 else { return [] }
        let ringByte = report[1]
        let ringActive = (ringByte & 0x80) != 0
        let ringPosition = ringActive ? (ringByte & 0x7F) : 0x7F
        let ringButtonDown = (report[2] & 0x01) != 0
        let mechanicalByte = report[3]
        let buttons = (0..<8).map { bit in (mechanicalByte & (1 << bit)) != 0 }
        return [.aux(AuxButtons(buttons: buttons,
                                mechanicalMask: mechanicalByte,
                                touchRingActive: ringActive,
                                touchRingButtonDown: ringButtonDown,
                                touchRingPosition: ringPosition))]
    }

}

/// Art Pen barrel angle from a 10-byte rotation packet (kernel
/// `wacom_intuos_general`, type 0x05), in degrees, clockwise increasing.
/// The raw value spans -900...899 for one turn.
func intuosRotationDegrees(_ report: HIDReport) -> Double {
    let t = (Int(report[6]) << 3) | ((Int(report[7]) >> 5) & 7)
    let absZ = (report[7] & 0x20) != 0
        ? (t > 900 ? (t - 1) / 2 - 1350 : (t - 1) / 2 + 450)
        : 450 - t / 2
    var degrees = Double(900 - absZ) / 1800.0 * 360.0
    if degrees < 0 { degrees += 360.0 }
    if degrees >= 360 { degrees -= 360.0 }
    return degrees
}

extension IntuosV1Decoder {
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
        /// A tool change arrived and no position has followed it yet.
        package var toolAnnouncedOutOfRange: Bool = false
        /// Whether the tool in range is a mouse.
        package var toolIsMouse: Bool = false
        /// Active BPT3 touch contacts by slot. Containers carry only changes.
        package var bpt3TouchSlots: [Int: TouchContact] = [:]
        /// Consecutive weak frames. The pen leaves at `proximityExitFrames`.
        package var exitFrameCount: Int = 0
        /// Whether this family fully supports the tool in range.
        package var toolIsSupported: Bool = true
        /// Airbrush wheel, held because it arrives in its own report.
        package var lastAirbrushWheel: Int? = nil
        /// Last valid Art Pen rotation, in degrees.
        package var lastRotation: Double = 0
        /// Whether real tilt has arrived since the pen entered.
        package var hasValidTiltFrame: Bool = false
        /// Last valid tilt, held through low-confidence frames.
        package var lastTiltX: Double = 0
        package var lastTiltY: Double = 0

        package init() {}
    }
}
