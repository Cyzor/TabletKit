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
        deviceFamily: String
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        let id = report[0]

        if id == 0x01 && length >= 11 {
            return decodeBLEPen(
                report: report, length: length, spec: spec, state: &state,
                deviceFamily: deviceFamily)
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
        // USB pen reports are exactly 10 bytes. PTH-850 (no touch, no Bluetooth — uses
        // an RF dongle) exposes Interface 1 as vendor-specific (Report ID 0x02, ~32-byte
        // payload, confirmed by capture 2026-07-17): content unidentified, plausibly tied
        // to the wireless dongle mechanism, not touch. Reject longer reports so this
        // payload is never decoded as garbage pen coordinates/pressure.
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
        deviceFamily: String
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

        // Boundary noise: proximity=1 but confidence=0 (status=0x40).
        // Don't exit yet - wait for sustained state.
        if !highConfidence {
            state.exitFrameCount += 1
            if state.exitFrameCount >= DecoderState.exitThreshold && state.prevInProximity {
                state.exitFrameCount = 0
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
                    hoverDistance: (Int(report[9]) >> 2))))
        return results
    }

    // MARK: - Tool-change packet (status bits 7:2 == 0xC0)

    private func decodeToolChange(
        report: UnsafePointer<UInt8>,
        state: inout DecoderState,
        deviceFamily: String
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
        deviceFamily: String
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
