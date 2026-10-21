// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for Wacom Cintiq pen-display tablets using the WACOM_24HD HID report layout.
///
/// Handles the older Cintiqs (`.cintiqV1`): DTK-2400 (0x00F4, confirmed on
/// hardware), DTH-2400 (0x00F8), DTK-2200 (0x00FA/0x00F9), DTZ-2100B
/// (0x00FB), DTZ-2100 (0x00CC), 20WSX (0x00C0), 13HD (0x00C4), and 12WX
/// (0x00C6). Touch models send touch on a separate interface, decoded by
/// `Wacom24HDTDecoder`.
///
/// **Reports:**
///   0x01 — tip switch (mouse-compatible collection)
///   0x02 — pen (10-byte IntuosV1 layout)
///   0x0C — touch rings + express keys (kernel WACOM_24HD pad layout)
///
/// **Pen report type-nibble dispatch: `(status >> 1) & 0x0F`**
///   0x00–0x03: general pen packet (position, pressure, tilt, barrel buttons)
///   0x05:      Art Pen / Marker Pen rotation (ABS_Z kernel formula)
///   0x0A:      Airbrush second packet (not yet decoded; cached state forwarded)
///
/// **Barrel button debounce:**
/// Buttons come from general packets (typeNibble 0–3) only: the rotation
/// sub-frame (status 0xEA) always has bit 1 set, which would latch barrel
/// button 1. The hardware pulses the bit about 1 frame in 5 while held, so a
/// release waits for 7 clear frames (~54 ms at 133 Hz).
///
/// **Tip-switch synthetic pressure:**
/// When Report 0x01 fires (tip physically down) but the concurrent 0x02 pressure
/// reads zero (Grip Pen hardware limitation on some Cintiqs), `tipPressureOverride`
/// injects a minimum contact pressure so apps register a click.
package struct CintiqV1Decoder: TabletReportDecoder {

    /// Creates a decoder. ``DeviceDecoder`` keeps one per device, with its state.
    public init() {}

    // ── Barrel button debounce state ──────────────────────────────────────────
    private var lastButton1: Bool = false
    private var lastButton2: Bool = false
    private var btn1ClearCount = 0
    private var btn2ClearCount = 0
    private static let buttonClearThreshold = 7

    // ── Tip-switch state (shared across Report 0x01 and Report 0x02) ─────────
    // tipPressureOverride: synthetic pressure injected when rawPressure == 0 at tip-down.
    // Set to tipContactThreshold (81) on tip-down; cleared on tip-up.
    private var tipSwitchActive: Bool = false
    private var tipPressureOverride: Int = 0
    private static let tipContactThreshold = 81

    // ── Pressure cache ────────────────────────────────────────────────────────
    // Rotation sub-frames (typeNibble 5) and airbrush wheel frames (typeNibble 0x0A)
    // do not carry pressure data.  Cache the last general-packet pressure so these
    // frames forward it unchanged — without this, every rotation frame emits pressure=0,
    // causing rapid mouseUp/mouseDown and a "dots instead of line" appearance.
    private var lastPressure: Int = 0

    // Set on proximity entry, cleared once a data packet decides whether a
    // fallback tool identity is needed — see `inRangeOnly` in `decodePen`.
    private var fallbackToolPending = false

    /// Decodes one report. See ``TabletReportDecoder/decode(report:spec:state:deviceFamily:)``.
    public mutating func decode(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard report.count >= 2 else { return [] }
        let id = report[0]

        if id == 0x01 {
            return decodeTipSwitch(report: report)
        }
        if id == 0x0C {
            return decodeExpressKeys(report: report, spec: spec)
        }
        if id == 0x11 && report.count >= 3 {
            return decodeCintiqPad(report: report)
        }
        guard (id == 0x02 || id == 0x10) && report.count >= 10 else { return [] }
        return decodePen(
            report: report, spec: spec, state: &state, deviceFamily: deviceFamily)
    }

    // MARK: - Report 0x01: physical tip-switch

    private mutating func decodeTipSwitch(report: HIDReport) -> [DecodeResult] {
        let tipDown = (report[1] & 0x01) != 0
        guard tipDown != tipSwitchActive else { return [.none] }
        tipSwitchActive = tipDown
        tipPressureOverride = tipDown ? Self.tipContactThreshold : 0
        return [.none]
    }

    // MARK: - Report 0x02/0x10: pen digitizer

    private mutating func decodePen(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let status = report[1]

        // Tool-change packet: status bits 7:2 == 0xC0.
        if (status & 0xFC) == 0xC0 {
            return decodeToolChange(report: report, state: &state, deviceFamily: deviceFamily)
        }

        let inProximity = (status & 0x20) != 0

        // Proximity-out.
        if !inProximity {
            if state.prevInProximity {
                resetProximityState(state: &state)
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

        // Packet type nibble: (status >> 1) & 0x0F — from wacom_intuos_general().
        let typeNibble = (Int(status) >> 1) & 0x0F

        // In-range packet (status 0x20/0x21): pen sensed at the edge of range,
        // sent before the tool-change packet on entry and after lift. Position
        // matches the neighboring data packets; tilt/pressure bytes are zero.
        // Linux skips these (wacom_intuos_inout); only the position is kept.
        let inRangeOnly = (status & 0xFE) == 0x20

        if typeNibble == 0x05 {
            // Art Pen / Marker Pen rotation packet — see intuosRotationDegrees.
            state.lastRotation = intuosRotationDegrees(report)

        } else if typeNibble <= 0x03 {
            // General pen packet: position, pressure, tilt, and barrel
            // buttons — see the type header for why buttons are only read
            // here, not from rotation frames.
            let curBtn1 = (status & 0x02) != 0
            let curBtn2 = (status & 0x04) != 0
            if curBtn1 {
                btn1ClearCount = 0
                lastButton1 = true
            } else {
                btn1ClearCount += 1
                if btn1ClearCount >= Self.buttonClearThreshold { lastButton1 = false }
            }
            if curBtn2 {
                btn2ClearCount = 0
                lastButton2 = true
            } else {
                btn2ClearCount += 1
                if btn2ClearCount >= Self.buttonClearThreshold { lastButton2 = false }
            }

            (state.lastX, state.lastY) = IntuosPenPacket.position(report)
            if !inRangeOnly {
                (state.lastTiltX, state.lastTiltY) = IntuosPenPacket.tilt(report)
            }
        }
        // typeNibble 0x0A (airbrush wheel): not yet decoded; falls through with cached state.

        // Only general packets carry pressure; other frames hold the last
        // value, since a zero would break strokes into dots. Captures of the
        // 12WX and 21UX confirm the 10-bit halving.
        // `tipPressureOverride` stands in below when pressure is 0 but the
        // tip switch fired.
        let pressure: Int
        if inRangeOnly {
            lastPressure = 0
            pressure = 0
        } else if typeNibble <= 0x03 {
            let raw = IntuosPenPacket.pressure(report, maxPressure: spec.maxPressure, statusBit: true)
            lastPressure = (raw == 0 && tipPressureOverride > 0) ? tipPressureOverride : raw
            pressure = lastPressure
        } else {
            pressure = lastPressure
        }

        // Fallback onToolEnter on first proximity entry (no prior tool-change
        // packet). Deferred past in-range packets: the real tool-change packet
        // follows them, and a premature serial-0 identity registers a phantom pen.
        var results: [DecodeResult] = []
        if !state.prevInProximity {
            state.prevInProximity = true
            fallbackToolPending = true
        }
        if fallbackToolPending && !inRangeOnly {
            fallbackToolPending = false
            if state.currentToolCode == 0 {
                let fallbackCode: UInt16 = state.isEraser ? 0x080A : 0x0802
                results.append(
                    .toolEnter(
                        ToolIdentity(
                            serial: 0, toolCode: fallbackCode,
                            isEraser: state.isEraser, isMouse: false)))
                emitToolCompatibility(
                    toolCode: fallbackCode, deviceFamily: deviceFamily,
                    toolIsSupported: &state.toolIsSupported, results: &results)
            }
        }

        let hoverDist = typeNibble <= 0x03 ? Int(report[9]) >> 2 : 0

        results.append(
            .pen(
                TabletPoint(
                    x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: state.lastTiltX,
                    tiltY: state.lastTiltY,
                    rotation: state.lastRotation,
                    penButton1: lastButton1 && !(!state.toolIsSupported && pressure > 0),
                    penButton2: lastButton2,
                    eraser: state.isEraser,
                    inProximity: true,
                    hoverDistance: hoverDist)))
        return results
    }

    // MARK: - Tool-change packet (status bits 7:2 == 0xC0)

    private func decodeToolChange(
        report: HIDReport,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let (serial, toolCode) = IntuosPenPacket.toolChange(report)

        state.lastSerial = serial
        state.currentToolCode = toolCode
        state.isEraser = (toolCode & 0x0008) != 0
        state.toolIsMouse = false

        var results: [DecodeResult] = [
            .toolEnter(
                ToolIdentity(
                    serial: serial, toolCode: toolCode,
                    isEraser: state.isEraser, isMouse: false))
        ]
        emitToolCompatibility(
            toolCode: toolCode, deviceFamily: deviceFamily,
            toolIsSupported: &state.toolIsSupported, results: &results)
        return results
    }

    // MARK: - Report 0x0C: touch rings + express keys + capacitive OSD buttons
    //
    // Two pad layouts share report 0x0C, as in the kernel's
    // `wacom_intuos_pad()`. Mixing them up reads 21UX2 strip swipes as
    // 24HD OSD button presses.
    //
    // DTK-2400 / Cintiq 24HD family (bezelButtonCount > 0), from a capture:
    //   byte[1] — left  touch ring: bit7=active, [6:0]=position 0–71
    //   byte[2] — right touch ring: same encoding (dual-ring models only)
    //   byte[3] — capacitive OSD touch buttons, group A — bit4 = left button
    //   byte[4] — capacitive OSD touch buttons, group B — bit6 = middle button, bit0 = right button
    //     The OSD area is one capacitive slider under three icons; a tap
    //     lands on its icon's bit, and the other bits are swipe way-points,
    //     ignored.
    //   byte[5] — 0x00 (padding)
    //   byte[6] — left  side express keys, full 8-bit mask
    //   byte[7] — 0x00 (padding)
    //   byte[8] — right side express keys, full 8-bit mask
    //   byte[9] — 0x00 (padding)
    //
    // Cintiq 21UX2 / 22HD family (bezelButtonCount == 0), from the kernel,
    // unverified on hardware:
    //   byte[1]:byte[2] and byte[3]:byte[4] are 13-bit touch-strip
    //   positions, not decoded here.
    //   byte[5] bit0 — left  center toggle
    //   byte[6]       — left  side express keys, full 8-bit mask
    //   byte[7] bit0 — right center toggle
    //   byte[8]       — right side express keys, full 8-bit mask
    //
    // buttons[] layout (AuxButtons), 24HD family:
    //   [0..7]   = byte[6] left side express keys
    //   [8..15]  = byte[8] right side express keys
    //   [16..18] = capacitive OSD buttons, left/middle/right
    //
    // buttons[] layout (AuxButtons), 21UX2/22HD family:
    //   [0..7]  = byte[6] left side express keys
    //   [8..15] = byte[8] right side express keys
    //   [16]    = byte[5] bit0, left  center toggle
    //   [17]    = byte[7] bit0, right center toggle

    private func decodeExpressKeys(
        report: HIDReport,
        spec: DigitizerSpec
    ) -> [DecodeResult] {
        guard report.count >= 7 else { return [] }

        let leftRingRaw = report[1]
        let leftRingActive = (leftRingRaw & 0x80) != 0
        let leftRingPos = leftRingActive ? (leftRingRaw & 0x7F) : UInt8(0x7F)

        var rightRingActive = false
        var rightRingPos = UInt8(0x7F)
        if spec.hasDualRings && report.count >= 3 {
            let rightRingRaw = report[2]
            rightRingActive = (rightRingRaw & 0x80) != 0
            rightRingPos = rightRingActive ? (rightRingRaw & 0x7F) : UInt8(0x7F)
        }

        let leftByte  = report[6]
        let rightByte = report.count >= 9 ? report[8] : 0
        let leftBits:  [Bool] = (0..<8).map { bit in (leftByte  & (1 << bit)) != 0 }
        let rightBits: [Bool] = (0..<8).map { bit in (rightByte & (1 << bit)) != 0 }

        let buttons: [Bool]
        if spec.bezelButtonCount > 0 {
            // DTK-2400 / 24HD family: bytes 3-4 are capacitive OSD buttons.
            let capA = report.count >= 4 ? report[3] : 0
            let capB = report.count >= 5 ? report[4] : 0
            let osdBits: [Bool] = [
                (capA & 0x10) != 0,  // left OSD button
                (capB & 0x40) != 0,  // middle OSD button
                (capB & 0x01) != 0,  // right OSD button
            ]
            buttons = leftBits + rightBits + osdBits
        } else {
            // 21UX2 / 22HD family: bytes 3-4 are touch-strip position, not
            // buttons — not decoded (no strip control type yet). Bytes 5/7
            // bit 0 are the two center toggles the 24HD path doesn't have.
            let byte5 = report[5]
            let byte7 = report.count >= 8 ? report[7] : 0
            let centerToggleBits: [Bool] = [
                (byte5 & 0x01) != 0,  // left center toggle
                (byte7 & 0x01) != 0,  // right center toggle
            ]
            buttons = leftBits + rightBits + centerToggleBits
        }

        return [
            .aux(
                AuxButtons(
                    buttons: buttons,
                    touchRingActive: leftRingActive,
                    touchRingPosition: leftRingPos,
                    touchRing2Active: rightRingActive,
                    touchRing2Position: rightRingPos))
        ]
    }

    // MARK: - Report 0x11: 27QHD onboard panel buttons (`WACOM_REPORT_CINTIQPAD`)
    //
    // Byte[2] bits 0-2 are the three panel buttons (capture-confirmed).
    // Bytes 5/7/9 drift slowly, unrelated to buttons (likely an ambient
    // sensor) — left undecoded.
    private func decodeCintiqPad(report: HIDReport) -> [DecodeResult] {
        let mask = report[2]
        let buttons: [Bool] = (0..<3).map { bit in (mask & (1 << bit)) != 0 }
        return [.aux(AuxButtons(buttons: buttons))]
    }

    // MARK: - State reset on proximity-out

    private mutating func resetProximityState(state: inout State) {
        state.prevInProximity = false
        state.lastRotation = 0.0
        state.lastTiltX = 0.0
        state.lastTiltY = 0.0
        lastButton1 = false
        lastButton2 = false
        btn1ClearCount = 0
        btn2ClearCount = 0
        tipSwitchActive = false
        tipPressureOverride = 0
        lastPressure = 0
        fallbackToolPending = false
    }
}

extension CintiqV1Decoder {
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
        /// Whether this family fully supports the tool in range.
        package var toolIsSupported: Bool = true
        /// Last valid Art Pen rotation, in degrees.
        package var lastRotation: Double = 0
        /// Last valid tilt, held through low-confidence frames.
        package var lastTiltX: Double = 0
        package var lastTiltY: Double = 0

        package init() {}
    }
}
