// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom IntuosV1 HID report format.
///
/// "V1" names TabletKit's protocol generation, not Wacom's marketing
/// generation — despite the name, Intuos3 hardware (PTZ-xxx) is handled
/// by the separate `Intuos3Decoder`, not this one; see that file's header
/// for the incompatible status-byte difference.
///
/// Used by: PTH-851 (0x0317), DTK-2400 (0x00F4), and any tablet using
/// the 10-byte IntuosV1 report layout. (PTZ-631W is Intuos3 hardware —
/// see `Intuos3Decoder`, not this file, despite the name similarity.)
///
/// Report ID routing:
///   0x01  BLE HOGP pen report (23 bytes)  — Intuos Pro over Bluetooth LE
///   0x03  Pad report (10 bytes): ring + express keys — sent over USB and the
///         ACK-40401 wireless dongle alike (confirmed by capture on PTH-850);
///         not just BLE despite the historical "HOGP" framing.
///   0x11  Auxiliary (express key) report — some other IntuosV1-family models
///         may use this instead; not observed on PTH-850.
///   0x0C  Intuos4 (PTK-xxx) pad report: ring + express keys (kernel
///         WACOM_REPORT_INTUOSPAD); distinct layout from 0x11 and 0x03.
///   0x02  USB pen report (10 bytes, Report ID 0x02 variant)
///   0x02  BPT3 touch/pad container (64 bytes) — INTUOSHT2 consumer
///         pen-and-touch models (CTH-690); gated on spec.hasFingerTouch
///   0x03  PTK-540WL BT aggregated report (22 bytes: 2 frames + power byte)
///         — gated on length; the short BLE pad report (also 0x03) still
///         hits its own path below.
///   0x04  PTK-540WL BT aggregated report (32 bytes: 3 frames + power byte)
///   0x10  USB pen report (10 bytes, Report ID 0x10 variant)
///   0x80  Wireless status report (ACK-40401 RF dongle)
///
/// On BLE connections the device uses 13-bit pressure (max 8191); the decoder
/// overrides `spec.maxPressure` to 8191 for BLE reports only.
public struct IntuosV1Decoder: TabletReportDecoder {

    public init() {}

    public func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        let id = report[0]

        if id == 0x01 && length >= 11 {
            return decodeBLEPen(
                report: report, length: length, spec: spec, state: &state,
                deviceFamily: deviceFamily)
        }
        if id == 0x03 && length >= 22 {
            return decodeIntuos4WLAggregated(report: report, length: length, spec: spec, state: &state, deviceFamily: deviceFamily)
        }
        if id == 0x04 && length >= 32 {
            return decodeIntuos4WLAggregated(report: report, length: length, spec: spec, state: &state, deviceFamily: deviceFamily)
        }
        if id == 0x03 && length >= 5 {
            guard let aux = decodeBLEPadReport(report: report, length: length) else { return [] }
            return [.aux(aux)]
        }
        if id == 0x11 {
            return decodeAuxReport(report: report, length: length)
        }
        if id == 0x0C {
            return decodeIntuos4PadReport(report: report, length: length)
        }
        if id == 0x80 {
            return decodeWirelessReport(report: report, length: length)
        }
        // BPT3 touch/pad container: 64-byte Report ID 0x02 on INTUOSHT2-family
        // models (CTH-690). Gated on length alone — touch and pad are gated
        // independently inside, so pen-only models still get their express keys.
        if id == 0x02 && length == BPT3ContainerDecoder.reportLength {
            return BPT3ContainerDecoder.decode(report: report, spec: spec, state: &state)
        }
        // USB pen reports are exactly 10 bytes. Anything else on this ID —
        // notably the 64-byte BPT3 container handled above, or a longer
        // vendor payload — must not fall through to the 10-byte pen decode
        // and be read as garbage coordinates/pressure.
        //
        // (An earlier note here claimed the PTH-850 has no capacitive touch
        // and its second interface is dongle telemetry. That was wrong — the
        // PTH-850 touch (L) has a working capacitive sensor whose 64-byte
        // BPT3 container arrives on the 0xFF00 interface; user-confirmed on
        // hardware 2026-08-27.)
        guard (id == 0x02 || id == 0x10) && length == 10 else { return [] }
        return decodeUSBPen(
            report: report, length: length, spec: spec, state: &state, deviceFamily: deviceFamily)
    }

    // MARK: - USB pen report (10-byte IntuosV1)

    private func decodeUSBPen(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
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

        // Genuine exit: both proximity and confidence lost.
        if isExitSignal {
            if state.prevInProximity {
                state.exitFrameCount = 0
                state.prevInProximity = false
                state.toolIsMouse = false
                // Don't let one tool's wheel position follow the next tool in.
                state.lastAirbrushWheel = nil
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

        // Confidence bit clear, proximity bit still set (status 0x20). Two
        // different things wear this shape:
        //   • Art Pen / Marker Pen: the rotation sensor makes the confidence
        //     bit oscillate at the tracking boundary. A sustained run really
        //     does mean the pen is leaving, so bridge exitThreshold frames and
        //     then synthesize the exit.
        //   • Plain stylus (Grip Pen &c.): this is just a high hover —
        //     position live in bytes 2–5, pressure/tilt zero. It can persist
        //     for the entire time a hand rests with the pen held above the
        //     tablet (~50% of hover reports on a PTH-850 Grip Pen). Escalating
        //     it fabricates a proximity exit every exitThreshold frames, which
        //     on the intuosV1+touch models resets the BPT3 pen-arbitration
        //     latch and kills capacitive touch for the whole hover.
        // So only a rotation pen escalates; for everyone else 0x20 is a hover
        // and the genuine both-bits-clear signal above is the only exit.
        if !highConfidence {
            let toolHasRotation = WacomToolCatalog.hasRotation(toolCode: state.currentToolCode)
            state.exitFrameCount += 1
            if toolHasRotation
                && state.exitFrameCount >= DecoderState.exitThreshold
                && state.prevInProximity
            {
                state.exitFrameCount = 0
                state.prevInProximity = false
                state.toolIsMouse = false
                // Don't let one tool's wheel position follow the next tool in.
                state.lastAirbrushWheel = nil
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
            // Still send point data during boundary noise - don't break decoding
        } else {
            state.exitFrameCount = 0
        }

        let subtype = (status >> 1) & 0x0F

        // Note: high-confidence bit (status & 0x40) is intentionally NOT filtered here.
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
                    state: &state, results: &results)
            }
        }
        state.prevInProximity = true

        // IntuosV1 coordinate decode: 16-bit BE with 1-bit fractional extension from byte 9.
        let x = ((Int(report[3]) | Int(report[2]) << 8) << 1) | ((Int(report[9]) >> 1) & 1)
        let y = ((Int(report[5]) | Int(report[4]) << 8) << 1) | (Int(report[9]) & 1)
        state.lastX = x
        state.lastY = y

        // Mouse subtype 0x06 (KC-100 cordless mouse).
        if subtype == 0x06 {
            let buttons = report[6]
            let whlByte = report[7]
            let wheelDelta = Int((whlByte & 0x80) >> 7) - Int((whlByte & 0x40) >> 6)
            results.append(
                .pen(
                    TabletPoint(
                        x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: (buttons & 0x01) != 0,
                        penButton2: (buttons & 0x04) != 0,
                        eraser: false, inProximity: true, hoverDistance: 0,
                        mouseMiddleButton: (buttons & 0x02) != 0,
                        mouseWheelDelta: wheelDelta)))
            return results
        }

        // Mouse subtype 0x08 (2D mouse / Intuos 1–3 cursor).
        if subtype == 0x08 {
            let btnByte = report[8]
            let wheelDelta = Int(btnByte & 0x01) - Int((btnByte & 0x02) >> 1)
            results.append(
                .pen(
                    TabletPoint(
                        x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: (btnByte & 0x04) != 0,
                        penButton2: (btnByte & 0x10) != 0,
                        eraser: false, inProximity: true, hoverDistance: 0,
                        mouseMiddleButton: (btnByte & 0x08) != 0,
                        mouseWheelDelta: wheelDelta)))
            return results
        }

        // Airbrush second packet (kernel `wacom_intuos_general()` type 0x0a):
        // wheel + tilt, no pressure or buttons. Interleaved with normal pen
        // packets, so cache and let the next one carry it — emitting a `.pen`
        // here (pressure 0) would read as a tip release mid-stroke.
        // Synthesized from kernel source; hardware discontinued and unowned.
        if subtype == 0x0A {
            state.lastAirbrushWheel = (Int(report[6]) << 2) | ((Int(report[7]) >> 6) & 0x03)
            state.lastTiltX = Double((((Int(report[7]) << 1) & 0x7E) | (Int(report[8]) >> 7)) - 64) / 63.0
            state.lastTiltY = Double((Int(report[8]) & 0x7F) - 64) / 63.0
            state.hasValidTiltFrame = true
            return results
        }

        // Pen path.
        // Pressure: 11-bit formula per kernel wacom_intuos_general().
        // data[6]<<3 provides high 8 bits; data[7]>>5 provides low 2 bits of the 11-bit field.
        // For 10-bit devices (maxPressure <= 1023), right-shift by 1 to normalize.
        // Intuos5 devices (PTH-850, maxPressure=2047) include status bit 0 as 11th bit.
        let statusBit = (spec.maxPressure == 2047) ? (Int(status) & 1) : 0
        let rawPressure = (Int(report[6]) << 3) | ((Int(report[7] & 0xC0)) >> 5) | statusBit
        let pressure = spec.maxPressure <= 1023 ? rawPressure >> 1 : rawPressure
        // Tilt X: bits [6:1] of byte 7 (shifted left 1) OR bit 7 of byte 8; biased by 64.
        let tiltXRaw = (((Int(report[7]) << 1) & 0x7E) | (Int(report[8]) >> 7)) - 64
        // Tilt Y: bits [6:0] of byte 8; biased by 64.
        let tiltYRaw = (Int(report[8]) & 0x7F) - 64

        results.append(
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: Double(tiltXRaw) / 63.0,
                    tiltY: Double(tiltYRaw) / 63.0,
                    rotation: 0.0,
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
        report: UnsafePointer<UInt8>,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let serial =
            UInt32(report[3] & 0x0F) << 28
            | UInt32(report[4]) << 20
            | UInt32(report[5]) << 12
            | UInt32(report[6]) << 4
            | UInt32(report[7]) >> 4
        let toolCode =
            UInt16(report[2]) << 4
            | UInt16(report[3]) >> 4
            | UInt16(report[7] & 0x0F) << 12
            | UInt16(report[8] & 0xF0) << 4

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
            state: &state, results: &results)

        return results
    }

    // MARK: - BLE HOGP pen (0x01)

    private func decodeBLEPen(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        // BLE uses 13-bit pressure regardless of the device's USB maxPressure.
        let bleSpec = DigitizerSpec(maxX: spec.maxX, maxY: spec.maxY, maxPressure: 8191)
        guard
            let result = decodeBLEPenReport(
                report: report, length: length, spec: bleSpec,
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
        report: UnsafePointer<UInt8>,
        length: CFIndex
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        let auxByte = report[1]
        return [.aux(AuxButtons(buttons: (0..<8).map { bit in (auxByte & (1 << bit)) != 0 }))]
    }

    // MARK: - Intuos4 WL Bluetooth aggregated reports (0x03 / 0x04)

    /// PTK-540WL over Bluetooth Classic (PID 0x00BD) batches 2–3 ordinary
    /// 10-byte Intuos4 frames into one outer report to conserve BT bandwidth,
    /// with a trailing power byte (kernel `wacom_intuos_bt_irq`):
    ///   0x03 — [0]=0x03, [1..10] frame 1, [11..20] frame 2, [21] power
    ///   0x04 — [0]=0x04, [1..10]/[11..20]/[21..30] frames 1–3, [31] power
    /// Minimum lengths are load-bearing (kernel OOB-read fix,
    /// GHSA-4mjh-m2x6-5qg4). Each embedded frame decodes exactly like USB —
    /// pen frames (0x02/0x10) through `decodeUSBPen`, pad frames (0x0C)
    /// through `decodeIntuos4PadReport`. Power byte: bits 2:0 index
    /// `batcap_i4`, bit 3 charging, bit 4 external power.
    /// Experimental: no hardware capture to confirm against, same basis as
    /// the 0x00BD registry row.
    private static let batcapI4: [Int] = [1, 15, 30, 45, 60, 70, 85, 100]

    private func decodeIntuos4WLAggregated(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let frameCount = report[0] == 0x03 ? 2 : 3
        let powerIndex = frameCount * 10 + 1
        guard length >= powerIndex + 1 else { return [] }

        var results: [DecodeResult] = []
        for frame in 0..<frameCount {
            let base = 1 + frame * 10
            let frameID = report[base]
            if frameID == 0x02 || frameID == 0x10 {
                results.append(contentsOf: decodeUSBPen(
                    report: report + base, length: 10, spec: spec,
                    state: &state, deviceFamily: deviceFamily))
            } else if frameID == 0x0C {
                results.append(contentsOf: decodeIntuos4PadReport(
                    report: report + base, length: 10))
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

    /// Intuos4 (PTK-xxx) ExpressKey panel + touch ring, sent on report ID
    /// 0x0C (kernel `WACOM_REPORT_INTUOSPAD` = 12) — a distinct report ID
    /// and byte layout from the 0x11 path above and from Intuos5's own pad
    /// report (id 0x03, `ring1 = data[2]`, `buttons = (data[4]<<1)|(data[3]&0x01)`).
    /// Layout cross-referenced against input-wacom's `wacom_intuos_pad()`
    /// (`features->type >= INTUOS4S && <= INTUOS4L` branch) and OTD's
    /// `Intuos4AuxReport`, which agree byte-for-byte:
    ///   report[1]      — ring position, bit 0x80 = valid, low 7 bits = 0-71 step
    ///   report[2] bit 0 — ring center (mode-switch) button
    ///   report[3]      — 8 mechanical ExpressKey bits
    /// Experimental: no hardware capture to confirm against, same basis as
    /// the `.crossReferenced` PTK-xxx registry entries.
    private func decodeIntuos4PadReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex
    ) -> [DecodeResult] {
        guard length >= 4 else { return [] }
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
