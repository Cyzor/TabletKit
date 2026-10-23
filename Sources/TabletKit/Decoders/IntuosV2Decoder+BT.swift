// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

// Bluetooth-side decoders for the IntuosV2 family. USB and BLE stay in
// `IntuosV2Decoder.swift`.
//
// Covers:
//   • 0x80 / 361-byte container — the same 7 packed pen frames as the
//     99-byte container ([1...98]), plus touch woven in at offset 109 for any
//     device with `hasFingerTouch`, plus a pad sub-report and battery byte
//     starting at 281
//   • 0x80 / 99-byte container  — 7 packed pen frames only, nothing past [99]
//   • 0x80 RF wireless status   — ACK-40401 dongle
//
// Length, not model, decides the container; both the PTH-660 and PTH-860
// can send either.

import Foundation

extension IntuosV2Decoder {

    // MARK: - BT frame coordinate/pressure/tilt helper

    /// Decodes position, pressure, and tilt from one Bluetooth pen frame, the
    /// same in both containers.
    ///
    /// Tilt is `rawByte / 64.0` when `spec.tiltMaxDegrees` is set: three pens
    /// on a PTH-860 saturate at exactly ±64. Otherwise `/127.0`, so unmeasured
    /// families don't change.
    ///
    /// Every pen-frame loop here shares an exit threshold: an Art Pen's
    /// rotation sensor drops frames at the boundary without leaving, so an
    /// exit needs `proximityExitFrames` bad frames in a row. A firmware exit
    /// (`!prox && !inRange`) takes effect at once, as in the kernel.
    func decodeBTFrame(_ f: UnsafePointer<UInt8>, spec: DigitizerSpec)
        -> (x: Int, y: Int, pressure: Int, tiltX: Double, tiltY: Double, hoverDistance: Int)
    {
        let x = f.le16(at: 1)
        let y = f.le16(at: 3)
        let pressure = f.le16(at: 5) & 0x1FFF
        // Reads tiltMaxDegrees as "measured?", not as an angle. That holds
        // while every measured device's raw ceiling equals its degree range;
        // one that differs needs its own divisor.
        let tiltDivisor = spec.tiltMaxDegrees != nil ? 64.0 : 127.0
        let tiltX = Double(Int8(bitPattern: f[7])) / tiltDivisor
        let tiltY = Double(Int8(bitPattern: f[8])) / tiltDivisor
        let hoverDistance = Int(f[13])
        return (x, y, pressure, tiltX, tiltY, hoverDistance)
    }

    // MARK: - BT Wireless pen (0x80, Bluetooth Classic/LE transport variant)
    //
    // Coordinates and pressure are LE u16, as in the BLE 0x01 report. Frame
    // flag byte, per the kernel's wacom_intuos_pro2_bt_pen():
    //   0x80 = valid frame
    //   0x40 = proximity
    //   0x20 = range (in-range vs hover/contact distinction)
    //   0x10 = invert (selects BTN_TOOL_RUBBER vs BTN_TOOL_PEN at first-in-range)
    //   0x09 = BTN_TOUCH mask (kernel reports tip as bit0 OR bit3)
    //   0x04 = BTN_STYLUS2 (barrel button 2)
    //   0x02 = BTN_STYLUS (barrel button 1)
    //
    // Per-frame eraser detection reads bit 3 (0x08), which the eraser end's
    // contact lights. The toolEnter takes eraser-ness from the tool code
    // at bytes 103:104 regardless.

    func decodeBTPen(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard report.count >= 15 else { return [] }

        var results: [DecodeResult] = []

        // 361-byte layout:
        // [0] = 0x80 (report ID)
        // [1..98] = up to 7 × 14-byte pen frames (oldest first)
        // [99..102] = pen serial LE, the same value USB reports
        // [103:104] = tool code LE (e.g., 0x0804 = Art Pen)
        // [281..285] = pad sub-report (center button, express keys, touch ring)
        //
        // Per-frame flag byte (f[0]):
        // 0x80 = frame valid / pen in proximity (0 = empty frame, break loop)
        // 0x40 = digitizer active (set when pen is hovering or touching)
        // 0x20 = pen in range (set while hovering or touching)
        // 0x08 = eraser tool
        // 0x04 = BTN_STYLUS2 (barrel button 2)
        // 0x02 = BTN_STYLUS (barrel button 1)

        let toolCode: UInt16 = report.count >= 105 ? UInt16(report.le16(at: 103)) : 0
        // Without the serial a pen was filed under its tool code over
        // Bluetooth and its serial over USB: two entries, two sets of settings.
        let serial: UInt32 = report.count >= 105
            ? report.le32(at: 99)
            : 0
        let isMouse = (toolCode & 0x000F) == 0x0006
        // Art Pen tool codes: 0x0804, 0x1108.
        // Note: 0x1108 has bit3 set, so the standard (toolCode & 0x0008) eraser test
        // would misclassify it as eraser. Use per-frame flags bit3 for eraser instead;
        // toolEnter isEraser is only for known eraser tool codes.
        let isArtPen = toolCode == 0x0804 || toolCode == 0x1108
        // Eraser detection for toolEnter: standard Wacom convention is bit3 of toolCode,
        // but exclude known Art Pen codes that happen to have bit3 set.
        let toolIsEraser = !isArtPen && (toolCode & 0x0008) != 0

        // Every report repeats the tool code, even after the pen leaves, so a
        // pen that's out is announced only with a frame that has it in range.
        let hasInRangeFrame = (0..<7).contains { i in
            let offset = 1 + i * 14
            return offset + 14 <= report.count && report[offset] & 0xA0 == 0xA0
        }
        if toolCode != 0 && (toolCode != state.lastToolCode || serial != state.lastSerial)
            && (state.prevInProximity || hasInRangeFrame)
        {
            state.lastToolCode = toolCode
            state.lastSerial = serial
            state.currentToolCode = toolCode
            state.toolIsMouse = isMouse
            results.append(
                .toolEnter(
                    ToolIdentity(
                        serial: serial, toolCode: toolCode,
                        isEraser: toolIsEraser,
                        isMouse: isMouse)))

            emitToolCompatibility(
                toolCode: toolCode, deviceFamily: deviceFamily,
                toolIsSupported: &state.toolIsSupported, results: &results)
        }

        // Process up to 7 pen frames (oldest first), 14 bytes each. Exit
        // detection thresholds bad frames rather than exiting immediately —
        // see `decodeBTFrame`'s doc comment for why.
        for i in 0..<7 {
            let frameOffset = 1 + i * 14
            // Stop early if the report is truncated mid-frame. Bounds-check
            // spirit of upstream input-wacom 09bc480.
            guard frameOffset + 14 <= report.count else { break }
            let f = report.pointer.advanced(by: frameOffset)
            let flags = f[0]

            // Invalid frame (bit7=0): threshold before treating as exit, same
            // as the !inRange path below.
            if (flags & 0x80) == 0 {
                state.exitFrameCount += 1
                if i == 0 && state.exitFrameCount >= proximityExitFrames
                    && state.prevInProximity
                {
                    state.lastToolCode = 0  // force toolEnter on re-entry
                    results.append(state.leaveProximity(spec: spec))
                }
                break
            }

            // Kernel model (wacom_intuos_pro2_bt_irq): exit when !prox &&
            // !inRange. At the boundary, inRange (bit5) drops before prox
            // (bit6): 0xE0 → 0xC0 → 0x80. Only exit when both clear —
            // 0xC0 alone is boundary noise, thresholded below.
            let prox = (flags & 0x40) != 0
            let inRange = (flags & 0x20) != 0
            let isExitSignal = !prox && !inRange

            if isExitSignal {
                // Genuine exit: fires immediately, no threshold.
                if state.prevInProximity {
                    state.lastToolCode = 0  // force toolEnter on re-entry
                    results.append(state.leaveProximity(spec: spec))
                }
                break
            }

            // Edge noise while the pen is out isn't a return. Only an in-range
            // frame brings it back, as in the Linux driver; otherwise a lone
            // 0xC0 after an exit reads as a hovering pen that never leaves.
            if !inRange && !state.prevInProximity { continue }

            // Boundary noise (0xC0, prox=1/inRange=0): threshold before
            // exiting, but keep decoding and sending point data below — only
            // the exit itself is suppressed.
            if !inRange {
                state.exitFrameCount += 1
                if state.exitFrameCount >= proximityExitFrames && state.prevInProximity {
                    state.lastToolCode = 0  // force toolEnter on re-entry
                    results.append(state.leaveProximity(spec: spec))
                    break
                }
                // Continue to decode point data below — don't break on boundary noise
            } else {
                // Good frame (inRange=1) — reset boundary counter and record entry if needed.
                state.exitFrameCount = 0
                state.prevInProximity = true
            }

            // 0x10 eraser end in range or 0x08 eraser touching; 0x08 alone
            // shows a hovering eraser as the pen. Weak frames carry neither
            // bit, so they keep the last state.
            if inRange { state.isEraser = (flags & 0x18) != 0 }
            let isEraser = state.isEraser
            let (x, y, rawPressure, rawTiltX, rawTiltY, hoverDistance) = decodeBTFrame(f, spec: spec)
            let (pressure, barrel1, barrel2) = Self.unpackGripPen(
                toolCode: state.currentToolCode, isEraser: isEraser, pressure: rawPressure,
                button1: (flags & 0x02) != 0, button2: (flags & 0x04) != 0,
                maxPressure: spec.maxPressure)
                let tiltX = inRange ? rawTiltX : state.lastTiltX
                let tiltY = inRange ? rawTiltY : state.lastTiltY
                if inRange {
                    state.lastTiltX = tiltX
                    state.lastTiltY = tiltY
                    state.hasValidTiltFrame = true
                }

            // Rotation: f[9:10], signed LE16, Art Pen only; other pens send
            // garbage here. Confirmed on a PTH-660 with an Art Pen.
            //
            // Boundary-noise frames (0xC0, !inRange) carry zero, so hold the
            // last in-range reading.
            var rotation = 0.0
            if isArtPen {
                if inRange {
                    let rawRot = f.signedLE16(at: 9)
                    // Invert direction to match USB path: clockwise twist → increasing degrees.
                    var r = rawRot
                    if r < 0 { r += 3600 }
                    state.lastRotation = Double((3600 - r) % 3600) / 10.0  // degrees [0, 360)
                }
                rotation = state.lastRotation
            }

            state.lastX = x
            state.lastY = y

            results.append(
                .pen(
                    TabletPoint(
                        x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: pressure, maxPressure: spec.maxPressure,
                        tiltX: tiltX, tiltY: tiltY, rotation: rotation,
                        penButton1: barrel1,
                        penButton2: barrel2,
                        eraser: isEraser,
                        inProximity: true,
                        hoverDistance: hoverDistance)))
        }

        // The pad sub-report sits at byte 281 of the 361-byte container:
        // byte[281] = center button (0x40 when pressed, 0x00 otherwise)
        // byte[282] = keys pressed, one bit each from the top, set for as long
        //             as a key is held (PTH-860, observed)
        // byte[283] = keys touched: set while a finger rests on a key, pressed
        //             or not, so it can't stand for a press
        // byte[284] = battery: bit7=charging, bits6:0=percent
        // byte[285] = ring byte: bit7=ring active, bits0-6=position (0–71); 0x7F=no touch
        if report.count >= 286 {
            let mechanicalByte = report[282]   // keys held down
            let ringByte = report[285]
            let btnByte = report[281]
            if mechanicalByte != state.lastBTPadKeys   // catches both press (0→n) and release (n→0)
                || ringByte != state.lastBTPadRing
                || btnByte != state.lastBTPadBtn
            {
                state.lastBTPadKeys = mechanicalByte
                state.lastBTPadRing = ringByte
                state.lastBTPadBtn = btnByte
                let buttons = (0..<8).map { (mechanicalByte & (1 << $0)) != 0 }
                let ringActive = ringByte != 0x7F
                results.append(
                    .aux(
                        AuxButtons(
                            buttons: buttons,
                            mechanicalMask: mechanicalByte,
                            touchRingActive: ringActive,
                            touchRingButtonDown: (btnByte & 0x40) != 0,
                            touchRingPosition: ringActive ? (ringByte & 0x7F) : 0x7F)))
            }
        }

        // Battery byte is at offset 284 in the 361-byte BT container.
        // Kernel source: wacom_intuos_pro2_bt_battery(), wacom_wac.c ~line 1503.
        // bit7 = charging flag; bits6:0 = battery percentage (0–100, direct value).
        // Only emit on change to avoid flooding with redundant events.
        if report.count >= 285 {
            let batByte = report[284]
            if batByte != state.lastBatteryByte {
                state.lastBatteryByte = batByte
                results.append(
                    .battery(percent: Int(batByte & 0x7F), charging: (batByte & 0x80) != 0))
            }
        }

        return results
    }

    // MARK: - BT finger touch (embedded in 0x80 / 361-byte container)
    //
    // Touch shares the 361-byte report with the pen, at [109..280]: four
    // 43-byte frames, per the kernel's `wacom_intuos_pro2_bt_touch()`.
    //
    // Per frame:
    //   [0] = bit7 frame-valid, bits 0..6 = contact count for the set. Only
    //         a set's first frame carries a count, for more than 5 contacts;
    //         these tablets take 5, so each frame stands alone.
    //   [1..]: up to 5 contacts, 8 bytes each
    //
    // Per contact (8 bytes):
    //   [0] = slot_id  (stable across frames per finger)
    //   [1] = status   (bit0 = down; 0 = lift)
    //   [2..3] = X LE16
    //   [4..5] = Y LE16
    //   [6] = touch major (w)
    //   [7] = touch minor (h)
    //
    // Frame bytes [41..42] are the tablet's clock, LE u16 at 0.1 ms per
    // count: sub-frames 10 ms apart, wrapping every 6.55 s. Measured on a
    // PTH-660, not the PTH-860; the kernel doesn't read it. Recorded into
    // `State.btTouchFrameStamps`; see `TouchFrame.deviceTime`.
    //
    // One `.touch` per valid frame, like the USB 0x21 path. Lifted contacts
    // are left out; an omitted contact counts as released.
    func decodeBTTouch(
        report: HIDReport,
        state: inout State
    ) -> [DecodeResult] {
        let frameBase = 109
        let frameLen = 43
        let frameCount = 4
        guard report.count >= frameBase + frameLen * frameCount else { return [] }

        var results: [DecodeResult] = []
        state.btTouchFrameStamps.removeAll(keepingCapacity: true)
        for i in 0 ..< frameCount {
            let off = frameBase + i * frameLen
            let header = report[off]
            guard (header & 0x80) != 0 else { continue }      // frame-valid bit
            let count = Int(header & 0x7F)
            guard count > 0 else { continue }                  // continuation frame; V1 ignores
            let slots = Swift.min(count, 5)
            var contacts: [TouchContact] = []
            contacts.reserveCapacity(slots)
            for j in 0 ..< slots {
                let cOff = off + 1 + j * 8
                guard (report[cOff + 1] & 0x01) != 0 else { continue }  // lift → drop
                let x = report.le16(at: cOff + 2)
                let y = report.le16(at: cOff + 4)
                let major = Int(report[cOff + 6])
                let minor = Int(report[cOff + 7])
                contacts.append(TouchContact(
                    id: Int(report[cOff]), x: x, y: y,
                    contactArea: major, contactMinor: minor))
            }
            // The sub-frame's clock, so callers time frames by when they were
            // sampled. Read last so a skipped frame adds no stamp.
            let stampOff = off + 41
            state.btTouchFrameStamps.append(
                UInt16(report.le16(at: stampOff)))
            results.append(.touch(contacts))
        }
        return results
    }

    // MARK: - BT Classic pen (0x80, length == 99, PTH-860)
    //
    // Seven pen frames per packet, as in the kernel's
    // wacom_intuos_pro2_bt_irq.
    //
    // Packet layout: [0]=header, [1..14]=frame0, [15..28]=frame1, ..., [85..98]=frame6
    //
    // Per-frame flag byte (f[0]):
    // 0x80 = frame valid — skip entire frame if clear
    // 0x40 = pen in prox — set on proximity entry
    // 0x20 = pen in range — set while hovering or touching
    // 0x08 = eraser tool
    // 0x04 = BTN_STYLUS2 (barrel 2)
    // 0x02 = BTN_STYLUS (barrel 1)
    // 0x01 = BTN_TOUCH
    //
    // Tilt bytes are signed. This container's pad data isn't decoded.

    /// Report ID `0x81` — the `INTUOSHT3_BT` Bluetooth container used by the
    /// consumer Intuos BT S/M (CTL-4100WL `0x0377`/`0x03C6`, CTL-6100WL
    /// `0x0379`/`0x03C8`). Kernel type `INTUOSHT3_BT`, dispatched to
    /// `wacom_intuos_pro2_bt_irq` alongside the Pro models but with a
    /// different geometry: **four 8-byte pen frames**, not seven 14-byte ones.
    ///
    /// Layout, confirmed on a CTL-4100WL Bluetooth capture:
    ///
    /// | Offset | Meaning |
    /// |---|---|
    /// | 0 | Report ID (`0x81`) |
    /// | 1, 9, 17, 25 | Four 8-byte pen frames |
    /// | 33 | Pen serial, little-endian |
    /// | 41 | Tool ID, little-endian |
    /// | 44 | ExpressKey bitmap, bits 0-3 |
    /// | 45 | Battery: bit 7 charging, bits 0-6 percent |
    ///
    /// Each frame: status byte, X and Y as unsigned LE 16-bit, pressure as
    /// unsigned LE 16-bit, then hover distance. **No tilt** — this family
    /// doesn't report it, unlike the Pro path above.
    ///
    /// Status bits match the Pro frames (bit 7 valid, 6 proximity, 5 range,
    /// 4 eraser, 2/1 barrel buttons), so both share the exit threshold.
    func decodeIntuosHT3BTFrames(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State
    ) -> [DecodeResult] {
        // Kernel accepts this family from 46 bytes; bytes 44/45 must exist
        // before the pad and battery reads below.
        guard report.count >= 46 else { return [] }

        var results: [DecodeResult] = []

        for i in 0..<4 {
            let f = report.pointer.advanced(by: 1 + i * 8)
            guard (f[0] & 0x80) != 0 else { continue }  // frame not valid

            let inProx = (f[0] & 0x40) != 0
            let inRange = (f[0] & 0x20) != 0
            let eraser = (f[0] & 0x10) != 0
            let barrel2 = (f[0] & 0x04) != 0
            let barrel1 = (f[0] & 0x02) != 0

            if !inProx && !inRange {
                if state.prevInProximity {
                    state.exitFrameCount = 0
                    state.prevInProximity = false
                    results.append(
                        .pen(
                            TabletPoint(
                                x: state.lastX, y: state.lastY,
                                maxX: spec.maxX, maxY: spec.maxY,
                                pressure: 0, maxPressure: spec.maxPressure,
                                tiltX: 0, tiltY: 0, rotation: 0.0,
                                penButton1: false, penButton2: false,
                                eraser: false, inProximity: false, hoverDistance: 0)))
                }
                break
            }

            if !inRange {
                state.exitFrameCount += 1
                if state.exitFrameCount >= proximityExitFrames && state.prevInProximity {
                    state.exitFrameCount = 0
                    state.prevInProximity = false
                    results.append(
                        .pen(
                            TabletPoint(
                                x: state.lastX, y: state.lastY,
                                maxX: spec.maxX, maxY: spec.maxY,
                                pressure: 0, maxPressure: spec.maxPressure,
                                tiltX: 0, tiltY: 0, rotation: 0.0,
                                penButton1: false, penButton2: false,
                                eraser: false, inProximity: false, hoverDistance: 0)))
                    break
                }
            } else {
                state.exitFrameCount = 0
                state.prevInProximity = true
            }

            // Out of range: coordinates in the frame are stale, so hold the
            // last good position rather than reporting them. Reporting the raw
            // bytes here is what produced periodic cursor jumps to (0,0) in
            // OTD's first attempt at this family.
            let x = inRange ? f.le16(at: 1) : state.lastX
            let y = inRange ? f.le16(at: 3) : state.lastY
            let pressure = f.le16(at: 5)
            let hoverDistance = Int(f[7])

            state.lastX = x
            state.lastY = y

            results.append(
                .pen(
                    TabletPoint(
                        x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: pressure, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: barrel1, penButton2: barrel2,
                        eraser: eraser, inProximity: true, hoverDistance: hoverDistance)))
        }

        // Pad and battery ride in every container, valid pen frame or not —
        // emitting them unconditionally is what keeps the ExpressKeys alive
        // while the pen is out of range.
        let padMask = report[44]
        results.append(
            .aux(AuxButtons(buttons: (0..<4).map { (padMask >> $0) & 1 != 0 })))

        let battery = report[45]
        results.append(
            .battery(percent: Int(battery & 0x7F), charging: (battery & 0x80) != 0))

        return results
    }

    func decodeBTClassicFrames(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard report.count >= 99 else { return [] }

        var results: [DecodeResult] = []

        for i in 0..<7 {
            let f = report.pointer.advanced(by: 1 + i * 14)

            guard (f[0] & 0x80) != 0 else { continue }  // frame not valid — skip

            let inProx = (f[0] & 0x40) != 0
            let inRange = (f[0] & 0x20) != 0
            // Either eraser bit, held through weak frames — see the 361-byte path.
            if inRange { state.isEraser = (f[0] & 0x18) != 0 }
            let eraser = state.isEraser
            let barrel2 = (f[0] & 0x04) != 0
            let barrel1 = (f[0] & 0x02) != 0

            // Genuine exit (!prox && !inRange): fires immediately, no
            // threshold — see `decodeBTFrame`'s doc comment.
            if !inProx && !inRange {
                if state.prevInProximity {
                    results.append(state.leaveProximity(spec: spec))
                }
                break
            }

            // Boundary noise (0xC0): threshold before exiting.
            if !inRange {
                state.exitFrameCount += 1
                if state.exitFrameCount >= proximityExitFrames && state.prevInProximity {
                    results.append(state.leaveProximity(spec: spec))
                    break
                }
                // Continue to decode point data — don't suppress output on boundary noise
            } else {
                state.exitFrameCount = 0  // good frame — reset boundary counter
                state.prevInProximity = true
            }

            let (x, y, pressure, rawTiltX, rawTiltY, hoverDistance) = decodeBTFrame(f, spec: spec)
                let tiltX = inRange ? rawTiltX : state.lastTiltX
                let tiltY = inRange ? rawTiltY : state.lastTiltY
                if inRange {
                    state.lastTiltX = tiltX
                    state.lastTiltY = tiltY
                    state.hasValidTiltFrame = true
                }
            // Rotation not decoded: this form carries no tool identity, and
            // non-Art pens fill f[9:10] with noise. The 361-byte form has both.

            state.lastX = x
            state.lastY = y

            results.append(
                .pen(
                    TabletPoint(
                        x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: pressure, maxPressure: spec.maxPressure,
                        tiltX: tiltX, tiltY: tiltY, rotation: 0.0,
                        penButton1: barrel1, penButton2: barrel2,
                        eraser: eraser, inProximity: true, hoverDistance: hoverDistance)))
        }

        return results
    }

    // MARK: - Wireless status (0x80)

    // Whole-value states below have no known source. The kernel
    // (wacom_wireless_irq) reads [1] bit 0 as connected, which makes 0x02 a
    // disconnect. ACK-40401 tablets decode through IntuosV1, so this may be
    // unreachable.

    func decodeWireless(
        report: HIDReport
    ) -> [DecodeResult] {
        guard report.count >= 2 else { return [] }
        switch report[1] {
        case 0x02: return [.wireless(.active)]
        case 0x05: return [.wireless(.lost)]
        case 0x06: return [.wireless(.lowBattery)]
        default: return [.wireless(.unknown(report[1]))]
        }
    }
}
