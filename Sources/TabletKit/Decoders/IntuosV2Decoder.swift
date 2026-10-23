// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom IntuosV2 HID report format.
///
/// "V2" is TabletKit's protocol generation, unrelated to `Intuos3Decoder`.
/// Used by the PTH-460 (0x0392/0x03DC), PTH-660 (0x0357), PTH-860 (0x0358),
/// and other tablets with the 192-byte IntuosV2 layout.
///
/// Report IDs:
/// 0x01 BLE pen report (23 bytes)
/// 0x03 BLE pad report (9 bytes)
/// 0x10 USB pen report (192 bytes), the main path
/// 0x11 express keys + touch ring
/// 0x1E offset pen report; see `decodeOffsetPenReport`
/// 0x21 finger touch (PTH-660/860); see `decodeTouchReport`. The touch
///      format of the DTH-271, DTH-135, and DTH-1320 is unconfirmed.
/// 0x80 wireless status, or Bluetooth Classic pen batches
package struct IntuosV2Decoder: TabletReportDecoder {

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
        switch report[0] {
        case 0x01:
            // The PTH-660/860 expose a standard USB HID mouse interface (usagePage=0x01)
            // that carries 4-byte button reports for cordless mouse accessories (KC-100).
            // BLE HOGP pen reports share Report ID 0x01 but are ≥ 23 bytes.
            // Distinguish by length: ≤ 8 bytes → USB mouse buttons; otherwise → BLE pen.
            if report.count <= 8 {
                // [0]=0x01 [1]=buttons(bit0=L,bit1=R,bit2=M) [2]=relX [3]=relY
                return [.mouseButton(report[1])]
            }
            return decodeBLEPen(
                report: report, spec: spec, state: &state,
                deviceFamily: deviceFamily)
        case 0x03:
            guard let aux = decodeBLEPadAux(report: report) else { return [] }
            return [.aux(aux)]
        case 0x10:
            // Body reads through report[16] (hover distance / mouse scroll counter)
            // unconditionally; reject short reports here so the body can rely on it.
            // Mirrors the bounds-check spirit of upstream input-wacom 09bc480.
            guard report.count >= 17 else { return [] }
            return decodePenReport(
                report: report, spec: spec, state: &state,
                deviceFamily: deviceFamily)
        case 0x1E:
            return decodeOffsetPenReport(report: report, spec: spec, state: &state)
        case 0x11:
            return decodeAuxReport(report: report)
        case 0x21:
            guard report.count >= 10 else { return [] }
            return decodeTouchReport(report: report)
        case 0x80:
            // Report ID 0x80 is shared by three distinct payloads:
            // • RF wireless status (report[1] = 0x02/0x05/0x06)
            // • PTH-860 BT Classic: 99 bytes — 1 header + 7 × 14-byte pen frames
            //   (wacom_intuos_pro2_bt_irq / INTUOSP2_BT kernel type)
            // • PTH-660 BT Classic: 361 bytes — single pen sub-report + pad at offset 281
            if report.count >= 2 && (report[1] == 0x02 || report[1] == 0x05 || report[1] == 0x06) {
                return decodeWireless(report: report)
            }
            if report.count == 99 {
                return decodeBTClassicFrames(
                    report: report, spec: spec, state: &state,
                    deviceFamily: deviceFamily)
            }
            var results = decodeBTPen(
                report: report, spec: spec, state: &state,
                deviceFamily: deviceFamily)
            // Touch is woven into the same 361-byte container at offset 109.
            // Only the Intuos Pro Gen 2 family with capacitive touch carries it
            // (PTH-660 BT 0x0360, PTH-860 BT 0x0361); spec.hasFingerTouch gates
            // the work for every other device that lands here.
            if spec.hasFingerTouch {
                results.append(contentsOf: decodeBTTouch(report: report, state: &state))
            }
            return results
        case 0x81:
            // INTUOSHT3_BT container (consumer Intuos BT S/M over Bluetooth).
            // Distinct geometry from the 0x80 Pro frames above — see
            // `decodeIntuosHT3BTFrames`.
            return decodeIntuosHT3BTFrames(
                report: report, spec: spec, state: &state)
        default:
            return []
        }
    }

    // BT-side decoders (0x80 in its many shapes) and the shared per-frame
    // helper live in `IntuosV2Decoder+BT.swift`.

    /// The Intuos4 Grip Pen's barrel buttons arrive inside pressure, over USB
    /// and Bluetooth alike: bit 11 for the lower, bit 12 for the upper, with
    /// the tip bit set even while hovering. Its own pressure is the low 11
    /// bits. The eraser end, other tools, and Bluetooth reports that keep
    /// the tip's tool code while erasing pass through unchanged.
    static func unpackGripPen(
        toolCode: UInt16, isEraser: Bool, pressure: Int, button1: Bool, button2: Bool,
        maxPressure: Int
    ) -> (pressure: Int, button1: Bool, button2: Bool) {
        guard toolCode == 0x0802, !isEraser else { return (pressure, button1, button2) }
        return ((pressure & 0x07FF) * maxPressure / 0x07FF,
                button1 || (pressure & 0x0800) != 0,
                button2 || (pressure & 0x1000) != 0)
    }

    // MARK: - Standard pen report (0x10)

    private func decodePenReport(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let status = report[1]
        // USB IntuosV2 status byte: bit6=proximity, bit5=highConfidence.
        // Kernel model (wacom_intuos_pro_irq): exit when !prox && !conf (status < 0x20).
        // Sequence at boundary: 0x60 (prox=1, conf=1) → 0x40 (prox=1, conf=0) → 0x00 (both=0).
        // The Art Pen's rotation sensor flips 0x60 ↔ 0x40; only both bits
        // clear is an exit.
        let prox = (status & 0x40) != 0
        let highConfidence = (status & 0x20) != 0
        let isExitSignal = !prox && !highConfidence

        if isExitSignal {
            // Genuine firmware exit signal — both proximity and confidence lost.
            // Don't threshold this; kernel fires it immediately.
            if state.prevInProximity {
                state.lastSerial = 0  // force toolEnter on re-entry
                state.lastToolCode = 0
                return [state.leaveProximity(spec: spec, holdingOrientation: true)]
            }
            return []
        }

        // Boundary noise: prox=1 but highConfidence=0 (status = 0x40), from
        // the Art Pen's rotation sensor in motion. Repeat the last state so
        // apps don't see a gap that snaps rotation to 0°.
        if !highConfidence {
            state.exitFrameCount += 1
            if state.exitFrameCount >= proximityExitFrames && state.prevInProximity {
                state.lastSerial = 0  // force toolEnter on re-entry
                state.lastToolCode = 0
                return [state.leaveProximity(spec: spec, holdingOrientation: true)]
            }

            // Below threshold, the pen is likely still down: repeat the last
            // state, once a valid frame has arrived since tool-enter. Cached
            // tilt keeps the azimuth from snapping to 0°, which wobbled
            // strokes. Hover reads 0, since these frames don't measure it.
            if state.prevInProximity && state.hasValidTiltFrame {
                return [
                    .pen(
                        TabletPoint(
                            x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                            pressure: 0, maxPressure: spec.maxPressure,
                            tiltX: state.lastTiltX, tiltY: state.lastTiltY,
                            rotation: state.lastRotation,
                            penButton1: false, penButton2: false,
                            // Held like tilt: a hard-coded false flipped the
                            // eraser to the pen on every weak frame at the
                            // edge of range.
                            eraser: state.isEraser, inProximity: true, hoverDistance: 0))
                ]
            }
            return []
        }

        state.exitFrameCount = 0
        state.prevInProximity = true

        var results: [DecodeResult] = []

        // Extract pen serial (bytes 17–20 LE) and tool code (bytes 21–22 LE).
        // Fire toolEnter whenever the active tool changes — either by serial (pens)
        // or by toolCode alone when serial = 0 (some mouse accessories).
        if report.count >= 27 {
            let serial = report.le32(at: 17)
            let toolCode = UInt16(report.le16(at: 21))
            // Boundary-noise frames (0x40) carry zero tool code. Don't overwrite the
            // valid code from the last good frame.
            if toolCode != 0 {
                state.currentToolCode = toolCode

                let toolChanged =
                    serial != 0
                    ? serial != state.lastSerial
                    : (toolCode != 0 && toolCode != state.lastToolCode)
                if toolChanged {
                    state.lastSerial = serial
                    state.lastToolCode = toolCode
                    let isMouse = (toolCode & 0x000F) == 0x0006
                    state.toolIsMouse = isMouse
                    // Eraser: standard Wacom bit3 convention, but exclude Art Pen
                    // variants (0x0804, 0x1108) that happen to have bit3 set.
                    let artPen = toolCode == 0x0804 || toolCode == 0x1108
                    results.append(
                        .toolEnter(
                            ToolIdentity(
                                serial: serial,
                                toolCode: toolCode,
                                isEraser: !artPen && (toolCode & 0x0008) != 0,
                                isMouse: isMouse)))

                    // Check tool compatibility and emit warning if unsupported
                    emitToolCompatibility(
                        toolCode: toolCode, deviceFamily: deviceFamily,
                        toolIsSupported: &state.toolIsSupported, results: &results)
                }
            }
        }

        // IntuosV2 coordinate decode — 24-bit LE (2 bytes + 1-byte extension).
        let x = report.le24(at: 2)
        let y = report.le24(at: 5)
        state.lastX = x
        state.lastY = y

        // ── Mouse path ─────────────────────────────────────────────────────────
        // Position only. The descriptor declares byte [16] as hover distance,
        // and a KC-100 capture moves it with height alone, so it's no wheel.
        // The tablet sends no mouse buttons on any report.
        if (state.currentToolCode & 0x000F) == 0x0006 && state.currentToolCode != 0 {
            let wheelDelta = 0
            results.append(
                .pen(
                    TabletPoint(
                        x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: (status & 0x02) != 0,
                        penButton2: (status & 0x04) != 0,
                        eraser: false, inProximity: true, hoverDistance: 0,  // Not reported by mouse
                        mouseMiddleButton: (report[9] & 0x02) != 0,
                        mouseWheelDelta: wheelDelta)))
            return results
        }

        // ── Pen path ───────────────────────────────────────────────────────────
        // Pressure: 13-bit value (d[8] + lower 5 bits of d[9]) per kernel spec.
        let (pressure, button1, button2) = Self.unpackGripPen(
            toolCode: state.currentToolCode, isEraser: (status & 0x18) != 0,
            pressure: report.le16(at: 8) & 0x1FFF,
            button1: (status & 0x02) != 0, button2: (status & 0x04) != 0,
            maxPressure: spec.maxPressure)
        // The PTH-660 descriptor declares tilt as [-64, 63] degrees,
        // matching the Bluetooth path. /127.0 is the fallback for families
        // whose descriptor hasn't been checked.
        let tiltDivisor = spec.tiltMaxDegrees != nil ? 64.0 : 127.0
        let tiltX = Double(Int8(bitPattern: report[10])) / tiltDivisor
        let tiltY = Double(Int8(bitPattern: report[11])) / tiltDivisor

        // Cache tilt so that !highConfidence passthrough frames can hold the last
        // real value instead of emitting (0, 0) and snapping Rebelle's azimuth to 0°.
        state.lastTiltX = tiltX
        state.lastTiltY = tiltY
        state.hasValidTiltFrame = true

        // Rotation (Twist): Bytes 12–13, signed 16-bit, scaled by 10 (e.g. 1800 = 180.0°).
        // Only valid for Art Pen variants (0x0804, 0x1108); other pens report garbage/defaults.
        // Cache in state.lastRotation so boundary-noise frames can hold the last real value.
        let isArtPen = state.currentToolCode == 0x0804 || state.currentToolCode == 0x1108
        let rawRot = report.signedLE16(at: 12)
        // Rotation: 1800 counts per revolution (0.2° each), range -900..899,
        // as in the kernel. Negated so a clockwise twist increases degrees,
        // which macOS apps expect.
        var rotation = isArtPen ? (900.0 - Double(rawRot)) / 5.0 : 0.0
        if rotation < 0 { rotation += 360.0 }
        if rotation >= 360 { rotation -= 360.0 }
        if isArtPen {
            state.lastRotation = rotation
            state.hasValidRotationFrame = true
        }

        // Proximity distance (hover height): Byte 16, 0-63 scale.
        // 0 = tip in contact, 1-63 = hover height (kernel: features.distance_max = 63).
        // When the pen approaches the tablet, distance decreases toward 0.
        let hoverDistance = Int(report[16])
        // 0x10 Invert (eraser end in range) as well as 0x08 Eraser (eraser
        // pressed), per the PTH-860 descriptor: Eraser alone made the eraser
        // exist only in contact, so apps saw each eraser stroke as the pen.
        state.isEraser = (status & 0x18) != 0

        results.append(
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: tiltX, tiltY: tiltY, rotation: rotation,
                    penButton1: button1,
                    penButton2: button2,
                    eraser: state.isEraser,
                    inProximity: true,
                    hoverDistance: hoverDistance)))

        return results
    }

    // MARK: - Offset pen report (0x1E, driver-compatibility mode)

    /// Confirmed on a DTH-227 capture. `report[1]` is a constant 0x01
    /// sub-type byte, as on IntuosV3's 0x1F/0x1E; the status is in
    /// `report[2]`, with the same proximity and tip bits as IntuosV3's 0x1E.
    ///
    /// Field map from the kernel's `wacom_Pro2022_pen_irq`, shared by the
    /// DTH-172, 227, and 271, whose pen descriptors match:
    ///
    ///     [2] flags: bit0 tip, bits1-3 buttons, bit4 eraser, bit5 invert,
    ///                bit6 range, bit7 proximity
    ///     [3] X LE24   [6] Y LE24   [9] pressure LE16
    ///     [11] tiltX LE16 signed    [13] tiltY LE16 signed
    ///     [15] rotation LE16 signed [17] fingerwheel LE16
    ///     [19] height   [20] tool UID LE64   [28] tool type
    ///     [30] scan time            [32] sequence number
    ///
    /// OTD's `IntuosV2OffsetReport` reads tilt and hover from the wrong
    /// bytes. Only the first 34 of the 192 bytes carry data; bit 3 is a
    /// third barrel button that `TabletPoint` has no field for.
    private func decodeOffsetPenReport(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State
    ) -> [DecodeResult] {
        // 20 bytes covers through the height byte at 19. Real devices send 192;
        // the shortest capture on hand is exactly 20.
        guard report.count >= 20 else { return [] }
        let status = report[2]
        let prox = (status & 0x80) != 0

        if !prox {
            guard state.prevInProximity else { return [] }
            state.prevInProximity = false
            return [
                .pen(
                    TabletPoint(
                        x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: state.lastTiltX, tiltY: state.lastTiltY, rotation: 0.0,
                        penButton1: false, penButton2: false,
                        eraser: false, inProximity: false, hoverDistance: 0))
            ]
        }

        let x = report.le24(at: 3)
        let y = report.le24(at: 6)
        let pressure = report.le16(at: 9)
        // Degrees over the device's own maximum: ±64 on the Wacom One 12, ±90
        // per the Cintiq Pro 22 descriptor, which is the fallback.
        let tiltScale = spec.tiltMaxDegrees ?? 90.0
        let tiltX = Double(report.signedLE16(at: 11)) / tiltScale
        let tiltY = Double(report.signedLE16(at: 13)) / tiltScale
        // Byte 19, past rotation (15) and the airbrush fingerwheel (17).
        let hoverDistance = Int(report[19])
        let isArtPen = state.currentToolCode == 0x0804 || state.currentToolCode == 0x1108

        state.prevInProximity = true
        state.lastX = x
        state.lastY = y
        state.lastTiltX = tiltX
        state.lastTiltY = tiltY
        state.hasValidTiltFrame = true

        return [
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: tiltX, tiltY: tiltY,
                    rotation: isArtPen ? state.lastRotation : 0.0,
                    penButton1: (status & 0x02) != 0,
                    penButton2: (status & 0x04) != 0,
                    eraser: (status & 0x30) != 0,  // eraser or invert, as above
                    inProximity: true,
                    hoverDistance: hoverDistance))]
    }

    // MARK: - BLE HOGP pen (0x01)

    private func decodeBLEPen(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard
            let result = decodeBLEPenReport(
                report: report, spec: spec,
                lastX: &state.lastX, lastY: &state.lastY)
        else { return [] }

        var results: [DecodeResult] = []
        if result.toolCode != 0
            && (result.serial != state.lastSerial || result.toolCode != state.lastToolCode)
        {
            state.lastSerial = result.serial
            state.lastToolCode = result.toolCode
            state.currentToolCode = result.toolCode
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

    // MARK: - Aux / express key report (0x11)

    /// Report layout (9 bytes, confirmed by capture):
    /// [0] 0x11 report ID
    /// [1] mechanical click state (use this — physical press required)
    /// [2] capacitive touch state (too sensitive; fires on lightest contact)
    /// [3] touch-ring center button (non-zero while center button is pressed)
    /// [4] touch-ring position, 0–71 (5° resolution); 0x7F = no contact
    /// [5–8] reserved
    ///
    /// Ring contact is posByte != 0x7F; ringByte is the separate center button.
    private func decodeAuxReport(
        report: HIDReport
    ) -> [DecodeResult] {
        guard report.count >= 3 else { return [] }
        let mechanicalByte = report[1]
        let ringByte: UInt8 = report.count >= 5 ? report[3] : 0
        let posByte: UInt8 = report.count >= 5 ? report[4] : 0x7F
        let buttons = (0..<8).map { bit in (mechanicalByte & (1 << bit)) != 0 }
        let ringActive = posByte != 0x7F  // finger on ring (position valid)
        let ringButtonDown = ringByte != 0  // center button pressed
        // Hardware sets bit 7 while touched; the position is 0–71 below it.
        return [
            .aux(
                AuxButtons(
                    buttons: buttons,
                    mechanicalMask: mechanicalByte,
                    touchRingActive: ringActive,
                    touchRingButtonDown: ringButtonDown,
                    touchRingPosition: ringActive ? posByte & 0x7F : 0x7F))
        ]
    }

    // MARK: - Finger touch report (0x21)

    /// 44-byte report: [0]=0x21 [1]=contact count (up to 5), then 5 × 8-byte fixed slots.
    /// Slot layout: [0]=slot_id [1]=status(0x01=down, 0x00=lift) [2..3]=X LE16 [4..5]=Y LE16
    ///              [6]=touch major [7]=touch minor
    /// Lift frame: status=0x00 for one frame at the last position, then the slot goes silent.
    ///
    /// The PTH-660's touch descriptor declares this layout field for field,
    /// with axes up to 8960 × 5920 and width/height up to 41 × 31.
    private func decodeTouchReport(
        report: HIDReport
    ) -> [DecodeResult] {
        let count = Int(report[1])
        guard count > 0 else { return [.touch([])] }
        var contacts: [TouchContact] = []
        let maxSlots = min(count, 5)
        for i in 0 ..< maxSlots {
            let base = 2 + i * 8
            guard base + 7 < report.count else { break }
            guard report[base + 1] == 0x01 else { continue }
            let x = report.le16(at: base + 2)
            let y = report.le16(at: base + 4)
            let major = Int(report[base + 6])
            let minor = Int(report[base + 7])
            contacts.append(TouchContact(
                id: Int(report[base]), x: x, y: y,
                contactArea: major, contactMinor: minor))
        }
        return [.touch(contacts)]
    }

}

extension IntuosV2Decoder {
    /// What this decoder remembers between reports.
    package struct State: DecoderState {
        /// Last X, held for frames that carry no position.
        package var lastX: Int = 0
        /// Last Y, held for frames that carry no position.
        package var lastY: Int = 0
        /// Serial at the last tool change.
        package var lastSerial: UInt32 = 0
        /// Tool code at the last tool change.
        package var lastToolCode: UInt16 = 0
        /// The tool in range.
        package var currentToolCode: UInt16 = 0
        /// Whether the last report had the pen in range.
        package var prevInProximity: Bool = false
        /// Whether the eraser end is in range, held through weak frames.
        package var isEraser: Bool = false
        /// Whether the tool in range is a mouse.
        package var toolIsMouse: Bool = false
        /// Last ExpressKey byte from the Bluetooth `0x80` container.
        package var lastBTPadKeys: UInt8 = 0
        /// Last ring byte from the Bluetooth `0x80` container.
        package var lastBTPadRing: UInt8 = 0x7F
        /// Last ring-button byte from the Bluetooth `0x80` container.
        package var lastBTPadBtn: UInt8 = 0
        /// Consecutive weak frames. The pen leaves at `proximityExitFrames`.
        package var exitFrameCount: Int = 0
        /// Whether this family fully supports the tool in range.
        package var toolIsSupported: Bool = true
        /// Last valid Art Pen rotation, in degrees.
        package var lastRotation: Double = 0
        /// Whether a real rotation has arrived since the pen entered.
        package var hasValidRotationFrame: Bool = false
        /// Whether real tilt has arrived since the pen entered.
        package var hasValidTiltFrame: Bool = false
        /// Last valid tilt, held through low-confidence frames.
        package var lastTiltX: Double = 0
        package var lastTiltY: Double = 0
        /// Last battery byte, so unchanged readings aren't sent again. 0xFF until one arrives.
        package var lastBatteryByte: UInt8 = 0xFF
        /// The device clock for each touch frame in the last report.
        package var btTouchFrameStamps: [UInt16] = []

        package init() {}

        /// Takes the pen out of range and returns the point that says so, at
        /// the last position. `holdingOrientation` puts the last tilt and
        /// rotation on that point instead of zeros, so the pen doesn't appear
        /// to snap upright as it leaves.
        mutating func leaveProximity(spec: DigitizerSpec, holdingOrientation: Bool = false) -> DecodeResult {
            let tiltX = holdingOrientation ? lastTiltX : 0
            let tiltY = holdingOrientation ? lastTiltY : 0
            let rotation = holdingOrientation ? lastRotation : 0
            exitFrameCount = 0
            prevInProximity = false
            isEraser = false
            lastTiltX = 0
            lastTiltY = 0
            hasValidTiltFrame = false
            lastRotation = 0
            hasValidRotationFrame = false
            return .pen(
                TabletPoint(
                    x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: 0, maxPressure: spec.maxPressure,
                    tiltX: tiltX, tiltY: tiltY, rotation: rotation,
                    penButton1: false, penButton2: false,
                    eraser: false, inProximity: false, hoverDistance: 0))
        }
    }
}
