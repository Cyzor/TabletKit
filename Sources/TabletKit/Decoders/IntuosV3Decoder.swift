// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom IntuosV3 HID report format.
///
/// "V3" names TabletKit's protocol generation, unrelated to `Intuos3Decoder`
/// (Wacom's own "Intuos3" marketing generation, PTZ-xxx, a much older and
/// differently-shaped protocol) despite the adjacent number.
///
/// Used by: PTK-470 (0x03F5), PTK-670 (0x03F7), PTK-870 (0x03F9) — the
/// current-generation Intuos Pro — and the Movink 13 (0x03F0) pen display.
/// Ported from OpenTabletDriver's `IntuosV3ReportParser` and the three
/// associated report structs.
///
/// Report ID routing:
/// 0x1F  Pen report, 16-bit XY (gated on data[1] == 0x01) — main path
/// 0x1E  Extended pen report, 24-bit XY  (note: collides with IntuosV2's
///       offset-pen ID; dispatch is per-decoder so this is fine)
/// 0x11  Aux report — 8 outer express keys, 2 cluster-center keys, two
///       relative-step scroll wheels (dials)
///
/// Byte layout differs from IntuosV2's main 0x10 path: the pen-status byte
/// sits at [2] instead of [1]. See
/// `Notes/Scratch/Upstream-Sync-2026-05-15.md` for the full diff table.
///
/// 0x11 and 0x1E are hardware-confirmed against real PTK-870 and Movink 13
/// captures — see `decodeAuxReport`/`decodeExtendedPenReport`. 0x1F is still
/// synthesized from OTD source tables; no capture uses that report ID.
public struct IntuosV3Decoder: TabletReportDecoder {

    /// Largest single-frame move, in device units, still treated as the pen
    /// tip while the barrel-takeover gate is armed — see `decodeBLEReport`.
    /// Sits inside a measured empty gap: genuine re-entries move at most 254
    /// units per frame, barrel jumps at least 2648.
    private static let bleBarrelJumpThreshold = 1000.0

    /// How many consecutive samples the barrel gate may reject before it
    /// gives up and trusts the pen again — see `decodeBLEReport`. Without a
    /// bound the gate can latch permanently: a rejected sample deliberately
    /// does not update the reference position, so a pen that leaves the edge
    /// and keeps going lands further from that stale reference on every
    /// subsequent report and never satisfies the continuity test again. At
    /// this device's report rate 32 samples is roughly a third of a second,
    /// which bounds a misfire to a brief stall instead of a dead pen.
    private static let bleBarrelMaxConsecutiveDrops = 32

    /// Width of the border band, in device units, within which a report is
    /// treated as suspect. 4000 units is 20mm at this family's uniform 200
    /// units/mm. Used by both transports: it arms the Bluetooth barrel gate,
    /// and bounds the USB out-of-surface rule.
    ///
    /// An earlier version armed only when a coordinate sat exactly on a
    /// limit. That misses the case that matters most in practice: the pen
    /// hovering over the top bezel, where the tip has physically left the
    /// drawable area but the digitizer still resolves a position a couple of
    /// thousand units short of the limit, so nothing ever rails and the gate
    /// never arms. Three captures deliberately worrying at that band
    /// (`ptk-870-bt-top-bermuda-triangle-0{1,2,3}.txt`) contained 96 barrel
    /// jumps between them, and EVERY one occurred with the gate disarmed and
    /// the previous sample at Y >= 1500 — never at a limit. Widening the arm
    /// condition to this band takes all of them, plus the four edge-bounce
    /// and full-width see-saw captures, to zero.
    private static let surfaceBorderBand = 4000

    /// True when a decoded point lies within the border band, meaning the
    /// tip is at, past, or hovering over the edge of the drawable area and
    /// the reported position may be coming from the pen's barrel instead.
    private static func isNearSurfaceLimit(x: Int, y: Int, spec: DigitizerSpec) -> Bool {
        distanceToNearestEdge(x: x, y: y, spec: spec) <= surfaceBorderBand
    }

    /// Width of the rim, in device units, within which a report carrying no
    /// close tip fix is treated as the pen being off the drawable surface
    /// entirely rather than as a position — see `decodeBLEReport`. 1700 units
    /// is 8.5mm.
    ///
    /// Sized from where the dead zone actually ends, not guessed: with a
    /// 1000-unit rim the groove traces themselves went quiet, but captures of
    /// the bezel on either side of the groove line still leaked — 175 samples
    /// from `ptk-870-bt-upper-bezel.txt` at Y 1002-1170 and 59 from
    /// `ptk-870-bt-top-bezel-contact.txt` at Y 1001-1631, every one of them
    /// just past the old boundary. This covers them.
    ///
    /// Widening is close to free for real work: the in-bounds border trace,
    /// pressure, tilt and the hover sweeps hold 94-100% at every width tried
    /// between 1000 and 2800, because they carry a close tip fix and this
    /// rule only ever looks at reports that do not. What it does cost is
    /// hover high enough to lose the tip fix within 8.5mm of an edge, which
    /// is the deliberate trade: on this hardware that signal is
    /// indistinguishable from a pen sitting in the groove.
    private static let rimBand = 1700

    private static func distanceToNearestEdge(x: Int, y: Int, spec: DigitizerSpec) -> Int {
        Swift.min(x, spec.maxX - x, y, spec.maxY - y)
    }

    public init() {}

    public func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        switch report[0] {
        case 0x1F:
            // OTD gates on data[1] == 0x01; other 0x1F payloads are unknown.
            guard length >= 14, report[1] == 0x01 else { return [] }
            return decodePenReport(
                report: report, length: length, spec: spec, state: &state,
                deviceFamily: deviceFamily)
        case 0x1E:
            guard length >= 20 else { return [] }
            return decodeExtendedPenReport(
                report: report, length: length, spec: spec, state: &state,
                deviceFamily: deviceFamily)
        case 0x11:
            return decodeAuxReport(report: report, length: length)
        case 0x1A:
            guard length >= 20 else { return [] }
            return decodeBLEReport(
                report: report, length: length, spec: spec, state: &state,
                deviceFamily: deviceFamily)
        case 0x1B:
            // Only byte [1] is read, which the length >= 2 guard above covers.
            return decodeBatteryReport(report: report, state: &state)
        case 0x06:
            guard length >= 20 else { return [] }
            return decodeAltBLEReport(report: report, length: length)
        default:
            return []
        }
    }

    // MARK: - 0x1B battery status

    /// BLE status report, emitted once per second. Captures are 20 bytes,
    /// but only byte [1] carries data — [2...19] are zero in every one on
    /// hand — so the dispatch guard requires just that byte, not the full
    /// declared length.
    ///
    ///   [1] bit7   = charging
    ///   [1] bits6:0 = battery percentage (0–100, direct value)
    ///
    /// Same encoding as the kernel's `wacom_intuos_gen3_bt_battery()`
    /// (`wacom_wac.c` ~line 1532), though that reads it at data[45] of the
    /// BT Classic container rather than from a report of its own — the
    /// kernel has no feature row for this PID at all, so the offset here
    /// comes from captures, not from upstream.
    ///
    /// Confirmed across ~50 PTK-870 BT captures: values with bit7 clear span
    /// 0x51–0x64 (81–100%) and never exceed 100 once masked, while the
    /// charging captures read 0xCC (76%) and 0xE4 (100%) — impossible as raw
    /// percentages, and both taken while plugged in.
    ///
    /// Only emit on change; at 1 Hz this is mostly about avoiding redundant
    /// published-property churn downstream.
    private func decodeBatteryReport(
        report: UnsafePointer<UInt8>,
        state: inout DecoderState
    ) -> [DecodeResult] {
        let batByte = report[1]
        guard batByte != state.lastBatteryByte else { return [] }
        state.lastBatteryByte = batByte
        return [.battery(percent: Int(batByte & 0x7F), charging: (batByte & 0x80) != 0)]
    }

    // MARK: - 0x1F standard pen report (16-bit XY)

    /// OTD IntuosV3Report.cs layout (14+ bytes):
    ///   [0]     = 0x1F  report ID
    ///   [1]     = 0x01  sub-type discriminator (other values are unknown)
    ///   [2]     pen status: bit1=button1, bit2=button2, bit5=eraser, bit6=prox
    ///   [3..4]  X coordinate, LE u16
    ///   [5..6]  Y coordinate, LE u16
    ///   [7..8]  pressure, LE u16
    ///   [9]     tilt X, signed byte
    ///   [10]    unused/padding
    ///   [11]    tilt Y, signed byte
    ///   [12]    unused/padding
    ///   [13]    hover distance
    ///
    /// OTD does not document a tool-enter / serial field for this family, so
    /// we cannot emit `.toolEnter` events — downstream tool compatibility
    /// checks won't fire. The IntuosV3Decoder targets unverified hardware
    /// (PTK-470/670/870); without a capture we can't fill that gap.
    private func decodePenReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let status = report[2]
        let prox = (status & 0x40) != 0

        if !prox {
            // Pen left proximity. Emit a synthetic exit frame so downstream
            // doesn't leave a phantom in-proximity state.
            guard state.prevInProximity else { return [] }
            state.prevInProximity = false
            return [
                .pen(
                    TabletPoint(
                        x: state.lastX, y: state.lastY,
                        maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: state.lastTiltX, tiltY: state.lastTiltY,
                        rotation: 0.0,
                        penButton1: false, penButton2: false,
                        eraser: false, inProximity: false, hoverDistance: 0))
            ]
        }

        let x = Int(UInt16(report[3]) | UInt16(report[4]) << 8)
        let y = Int(UInt16(report[5]) | UInt16(report[6]) << 8)
        let pressure = Int(UInt16(report[7]) | UInt16(report[8]) << 8)
        let tiltX = Double(Int8(bitPattern: report[9])) / 127.0
        let tiltY = Double(Int8(bitPattern: report[11])) / 127.0
        let hoverDistance = Int(report[13])

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
                    tiltX: tiltX, tiltY: tiltY, rotation: 0.0,
                    penButton1: (status & 0x02) != 0,
                    penButton2: (status & 0x04) != 0,
                    eraser: (status & 0x20) != 0,
                    inProximity: true,
                    hoverDistance: hoverDistance))
        ]
    }

    // MARK: - 0x1E extended pen report (24-bit XY)

    /// Layout confirmed 2026-09-07 against real PTK-870 pen captures
    /// (`whot/wacom-recordings`) and 2026-09-08 against a Movink 13 (DTH-135)
    /// capture (OpenTabletDriver PR #3679, ~26k reports, Pro Pen 3). Bit 7 is
    /// proximity, bit 6 is the tip switch — the previous code checked bit 6
    /// for proximity (an unverified port from IntuosV2), which dropped the
    /// hover that precedes each stroke and misfired proximity-exit at the
    /// hover/touch boundary. The Movink capture presses all three barrel
    /// buttons individually (bits 1/2/3), confirming those bits too. Bit 0
    /// tracks the tip switch, not a button, on both devices' captures.
    ///
    ///   [0]       = 0x1E  report ID
    ///   [2]       pen status: bit0=tip-switch echo (not a button),
    ///                        bit1=button1, bit2=button2, bit3=button3,
    ///                        bit5=eraser, bit6=tip switch, bit7=proximity
    ///   [3..5]    X coordinate, 24-bit (LE u16 at [3..4] | byte[5] << 16)
    ///   [6..8]    Y coordinate, 24-bit (LE u16 at [6..7] | byte[8] << 16)
    ///   [9..10]   pressure, LE u16
    ///   [11..12]  tilt X, signed LE i16
    ///   [13..14]  tilt Y, signed LE i16
    ///   [15..16]  Art Pen barrel rotation, signed LE16, -900..899 range,
    ///             1800 counts per revolution — same convention as
    ///             IntuosV2Decoder's rotation field (see there for the
    ///             kernel citation), just at a different offset. Gated on
    ///             the tip switch (status bit6, 0x40), not on pressure.
    ///             Previously misread as a single byte at [15]; that was
    ///             just the low byte of this wider field (see call site).
    ///   [19]      hover distance — smallest with the tip down, rising as the
    ///             pen lifts, railed at 255 once it is out of range. The BLE
    ///             report carries the same field at its own byte [15].
    ///
    /// Same report ID as IntuosV2's "offset" report, but the byte layout is
    /// completely different. Per-decoder dispatch keeps the two separate.
    private func decodeExtendedPenReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let status = report[2]
        let prox = (status & 0x80) != 0

        if !prox {
            guard state.prevInProximity else { return [] }
            state.prevInProximity = false
            return [
                .pen(
                    TabletPoint(
                        x: state.lastX, y: state.lastY,
                        maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: state.lastTiltX, tiltY: state.lastTiltY,
                        rotation: 0.0,
                        penButton1: false, penButton2: false,
                        eraser: false, inProximity: false, hoverDistance: 0))
            ]
        }

        let x = Int(UInt16(report[3]) | UInt16(report[4]) << 8) | (Int(report[5]) << 16)
        let y = Int(UInt16(report[6]) | UInt16(report[7]) << 8) | (Int(report[8]) << 16)
        let pressure = Int(UInt16(report[9]) | UInt16(report[10]) << 8)
        let rawTiltX = Int16(bitPattern: UInt16(report[11]) | UInt16(report[12]) << 8)
        let rawTiltY = Int16(bitPattern: UInt16(report[13]) | UInt16(report[14]) << 8)
        // Confirmed 2026-09-08 against a real Movink 13 (DTH-135) capture
        // (OpenTabletDriver PR #3679, ~26k reports): raw tilt only ever spans
        // -64...63, i.e. the field is already in degrees, not a 16-bit
        // fraction — Int16.max was the wrong divisor. Matches the ±64°
        // convention IntuosV2Decoder already uses via spec.tiltMaxDegrees.
        let tiltDivisor = spec.tiltMaxDegrees ?? 64.0
        let tiltX = Double(rawTiltX) / tiltDivisor
        let tiltY = Double(rawTiltY) / tiltDivisor
        let hoverDistance = Int(report[19])

        // Rotation (Art Pen barrel twist): signed LE16 at bytes [15..16],
        // gated on the tip switch, not on pressure. Only meaningful for Art
        // Pen variants (0x0804, 0x1108); other pens leave this at 0/garbage.
        //
        // CORRECTED 2026-09-19: previously read as a single byte at [15]
        // (255 counts/revolution). That was really just the low byte of
        // this wider field — the old decode ran ~7x too fast and backwards,
        // matching the user's live report of rotation being "about 4x too
        // fast, spinning the opposite direction" in both MockTab and
        // Rebelle. Confirmed against `ptk-870-usb-art-pen-pressure+rotation.txt`:
        // a deliberate ~1-turn gesture now unwraps to exactly -1.00 laps.
        let isArtPen = state.currentToolCode == 0x0804 || state.currentToolCode == 0x1108
        let tipSwitch = (status & 0x40) != 0
        let rawRotation = Int16(bitPattern: UInt16(report[15]) | UInt16(report[16]) << 8)
        var rotation = isArtPen && tipSwitch ? (900.0 - Double(rawRotation)) / 5.0 : 0.0
        if rotation < 0 { rotation += 360.0 }
        if rotation >= 360 { rotation -= 360.0 }

        // Off the drawable surface: the pen is in the moulded groove around
        // the tablet, or over the bezel, and should produce nothing.
        //
        // Same underlying hardware behaviour the BLE path deals with — a pen
        // past the edge keeps being reported, at a position that folds back
        // INSIDE the rim rather than clamping to it (measured on USB at a
        // median 791 units in, against ~850 over BLE, so this is the
        // digitizer, not a transport quirk). Wired does not suppress it any
        // more than wireless does.
        //
        // USB leaps exactly like BLE does, and for the same reason — an
        // earlier version of this comment claimed it did not, on the strength
        // of a groove trace that runs ALONG each edge and never crosses one.
        // That data could not contain a leap. Captures that do cross
        // (`ptk-870-usb-see-saw-top.txt`, `ptk-870-usb-edge-bounce-right.txt`)
        // hold 129 and 26 leaps up to 4965 units, none explained by a gap or
        // a proximity break, and 152 of those 155 carry a railed hover
        // distance on BOTH endpoints. It is the same barrel takeover.
        //
        // USB needs none of the state the BLE gate grew, though, because it
        // states the distance outright instead of implying it. One test on
        // byte [19] covers both the groove and the leaps: the leap endpoints
        // sit around 2266 units from an edge, so the band has to be the full
        // border band rather than the narrower rim. At that width both leap
        // captures go to zero and the groove trace drops to 2%, while
        // in-bounds work holds 99.4% and 99.5%.
        //
        // Do not widen it further. The reference hover frame below survives
        // by 459 units at 4000 and is cut at 5000.
        //
        // The rail alone is NOT enough, and a reference recording caught that
        // before it shipped: `pen.pen-strong-vertical.hid` from
        // whot/wacom-recordings contains a legitimate hover frame reading 255
        // at X 51% / Y 11% of the surface — mid-tablet, nowhere near an edge.
        // So 255 means "at or past the sensing limit", which a pen held high
        // over the middle of the tablet reaches just as a pen in the groove
        // does. Pairing it with the rim separates them: it keeps that frame,
        // and every width tried from 1000 to 4000 units keeps it while still
        // taking 98% of the groove. Reusing the BLE rim width so the two
        // transports draw the same border rather than each carrying a number.
        //
        // Deliberately also requires no pressure and no tip switch, which
        // changes nothing on the captures (identical numbers either way) but
        // bounds the blast radius: this function is shared with the Movink 13,
        // for which no groove capture exists. A device that left byte [19]
        // pinned at 255 would lose hover near its edges rather than the pen.
        if hoverDistance == 255, pressure == 0, (status & 0x40) == 0,
            Self.distanceToNearestEdge(x: x, y: y, spec: spec) <= Self.surfaceBorderBand
        {
            return []
        }

        var results: [DecodeResult] = []

        // Pen serial (bytes 20-23 LE) and tool code (bytes 24-25 LE) —
        // confirmed byte-for-byte 2026-09-16 against a real PTK-870 capture
        // using a known-identity pen (Wacom Art Pen, tool code 0x0804,
        // serial 0x038000CE): both fields decoded to the pen's real,
        // documented values at exactly these offsets. Both read 0 while out
        // of proximity. Byte 26 (high byte of the declared 32-bit tool-code
        // usage 0x005C) carries some other flag/capability value, not part
        // of the tool code itself — not read here. Same
        // lastSerial/lastToolCode change-detection pattern as
        // IntuosV2Decoder.decodeOffsetPenReport.
        if length >= 26 {
            let serial =
                UInt32(report[20])
                | UInt32(report[21]) << 8
                | UInt32(report[22]) << 16
                | UInt32(report[23]) << 24
            let toolCode = UInt16(report[24]) | UInt16(report[25]) << 8
            if toolCode != 0 {
                state.currentToolCode = toolCode
                let toolChanged =
                    serial != 0
                    ? serial != state.lastSerial
                    : toolCode != state.lastToolCode
                if toolChanged {
                    state.lastSerial = serial
                    state.lastToolCode = toolCode
                    // Standard Wacom bit3 convention, excluding Art Pen
                    // variants that happen to have bit3 set — same
                    // exclusion IntuosV2Decoder applies.
                    let artPen = toolCode == 0x0804 || toolCode == 0x1108
                    results.append(
                        .toolEnter(
                            ToolIdentity(
                                serial: serial, toolCode: toolCode,
                                isEraser: !artPen && (toolCode & 0x0008) != 0,
                                isMouse: false)))
                    emitToolCompatibility(
                        toolCode: toolCode, deviceFamily: deviceFamily,
                        state: &state, results: &results)
                }
            }
        }

        state.prevInProximity = true
        state.lastX = x
        state.lastY = y
        state.lastTiltX = tiltX
        state.lastTiltY = tiltY
        state.hasValidTiltFrame = true

        var point = TabletPoint(
            x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
            pressure: pressure, maxPressure: spec.maxPressure,
            tiltX: tiltX, tiltY: tiltY, rotation: rotation,
            penButton1: (status & 0x02) != 0,
            penButton2: (status & 0x04) != 0,
            eraser: (status & 0x20) != 0,
            inProximity: true,
            hoverDistance: hoverDistance)
        // IntuosV3 extended reports carry a third pen barrel button at bit 3
        // of the status byte. The 0x1F standard report has no equivalent.
        point.penButton3 = (status & 0x08) != 0
        results.append(.pen(point))
        return results
    }

    // MARK: - 0x11 aux report (express keys + dial presses + two relative wheels)

    /// Layout confirmed 2026-07-28 against a real PTK-870 (Intuos Pro L gen3)
    /// capture (`whot/wacom-recordings`, MIT-licensed) — both the device's own
    /// HID descriptor (which declares this report field-by-field, including
    /// usage names) and per-action recordings of every control on the pad:
    ///   [0]   = 0x11 report ID
    ///   [1]   = express-key byte — **all 8 keys**, one bit each (bits 0–7)
    ///   [2]   = reserved/constant
    ///   [3]   = cluster-center keys — bit 0 = left cluster, bit 1 = right
    ///           cluster (descriptor names this usage "Wacom Button Center");
    ///           bits 2–7 reserved
    ///   [4]   = left dial raw 7-bit signed rotation delta  (bits 0–6; bit 7 ignored)
    ///   [5]   = right dial raw 7-bit signed rotation delta (bits 0–6; bit 7 ignored)
    ///
    /// `pen.buttons.hid` in that capture set presses each of the 8 express
    /// keys individually — every press lights exactly one bit of byte [1],
    /// byte [3] stays zero throughout. `pen.center-buttons.hid` presses the
    /// two cluster-center keys individually — each lights exactly one bit of byte
    /// [3] alone. `pen.left/right-dial-cw/ccw.hid` confirm the wheel bytes
    /// below decode correctly (sign, direction) against real dial clicks.
    ///
    /// This superseded an earlier layout ported from OTD's
    /// `IntuosV3AuxReport.cs`, which treated byte [3]'s two bits as extra
    /// *express keys* interleaved into a 10-button array at positions 4 and
    /// 9. That model was never hardware-verified (see the header of
    /// `IntuosV3DecoderTests.swift`) and this capture contradicts it directly:
    /// byte [3] carries the dial buttons, not express keys, and there are
    /// only 8 express keys, not 10.
    ///
    /// Note these are keys in the middle of each express-key cluster, not dial
    /// presses — the dials rotate only, per vendor documentation, which also
    /// gives the middle key a default action of "Dial toggle". Routing it to a
    /// ring-center binding below is therefore a reasonable analogue rather than
    /// a literal match; a dial-mode cycle would be closer to the hardware's
    /// intent, but that is a new action type, not a decoder concern.
    ///
    /// The left cluster-center key is surfaced via the existing
    /// `AuxButtons.touchRingButtonDown` field, the same one IntuosV1/IntuosV2/
    /// Xencelabs already use for a single ring's center click. The right
    /// cluster-center key now has its own `touchRing2ButtonDown` field
    /// (bit 0x02 of byte 3, confirmed against a real PTK-870 capture
    /// 2026-09-16 — both bits independently observed toggling). Neither
    /// field is actually how this hardware's mode-cycle toggle is used in
    /// practice, though: real PTK-670/870 units have no physical center
    /// press on either dial, so the toggle is assigned to an ordinary
    /// ExpressKey instead (`ButtonBinding.Kind.ringCycle`/`.ringCycle2`),
    /// which reads `touchRingActiveSlotIndex`/`touchRingActiveSlotIndex2`
    /// directly rather than either of these button-down bits. Both fields
    /// stay decoded for completeness and for any future hardware that does
    /// wire a real center press to this bit position.
    ///
    /// Wheel deltas are emitted as .wheel(index:delta:) results so
    /// InputInjector can route them through touchRingSlots (scroll /
    /// key-press / off) without further state in this decoder.
    private func decodeAuxReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        let primary = report[1]
        let dialButtons: UInt8 = length >= 4 ? report[3] : 0
        let buttons: [Bool] = (0..<8).map { bit in (primary & (1 << bit)) != 0 }
        var results: [DecodeResult] = [
            .aux(
                AuxButtons(
                    buttons: buttons, mechanicalMask: primary,
                    touchRingButtonDown: (dialButtons & 0x01) != 0,
                    touchRing2ButtonDown: (dialButtons & 0x02) != 0))
        ]
        // Sign-extend 7-bit values: shift the sign bit into bit 7, then
        // arithmetic-shift right to propagate it across the Int8 range.
        if length >= 5 {
            let leftDelta = Int((Int8(bitPattern: report[4]) << 1) >> 1)
            if leftDelta != 0 { results.append(.wheel(index: 0, delta: leftDelta)) }
        }
        if length >= 6 {
            let rightDelta = Int((Int8(bitPattern: report[5]) << 1) >> 1)
            if rightDelta != 0 { results.append(.wheel(index: 1, delta: rightDelta)) }
        }
        return results
    }

    // MARK: - 0x1A Bluetooth LE report (pen + pad, single multiplexed interface)

    /// PTK-470/670/870 over Bluetooth LE expose one HID interface (usage
    /// page 0x01, usage 0x80 "System Control" — the whole descriptor is
    /// reused as a vendor payload wrapper, not a real System Control
    /// collection) instead of USB's separate pen/aux interfaces. All pen and
    /// pad data multiplexes through this single report ID.
    ///
    /// Requires the device's DATAMODE feature report ([0x02, 0x02]) to have
    /// been sent first — see `WacomDeviceRegistry`'s `.intuosV3` `initSteps`
    /// and `WacomKnownDevice.open()`'s BLE exception for `.intuosV3`.
    /// Without it the tablet emits report 0x06 instead. That report is NOT
    /// inert — see `decodeAltBLEReport` below, which corrects an earlier
    /// comment here that assumed it was and never routed it.
    ///
    /// This is Wacom's Intuos Pro 2 Bluetooth pen frame (Linux `input-wacom`
    /// `wacom_intuos_pro2_bt_pen`) with the two coordinates widened from 16
    /// to 20 bits each and bit-packed, which shifts every field after them by
    /// one byte. Recognising that shape is what finally made the layout fall
    /// out: the status byte at [3] matches that function's `frame[0]`
    /// bit-for-bit, and every field below lands on exactly the maximum the
    /// USB registry entry already declares for this device (X 69800, Y 39000,
    /// pressure 8191, tilt ±64) — four independent agreements that no
    /// coincidental byte mapping produces.
    ///
    ///   [0]      = 0x1A  report ID
    ///   [1]      packet-class + slot discriminator (see below)
    ///   [3]      pen status, same bits as `wacom_intuos_pro2_bt_pen`'s
    ///            `frame[0]`: bit7 = in range, bit6 = close enough for tilt
    ///            and pressure to be valid, bit4 = eraser/inverted, bit2 =
    ///            barrel button 2, bit1 = barrel button 1, bit0 = tip switch.
    ///            Confirmed: bit0 agrees with pressure > 0 on 11,000+ samples
    ///            across five captures with 2 disagreements (the contact
    ///            transition frame itself); bit2 is the only barrel bit ever
    ///            seen set, during a deliberate button hold in
    ///            `ptk-870-left-to-right.txt`; bit7/bit6 gate exactly which
    ///            fields the device bothers to fill in (see below). The whole
    ///            observed value set is 0x00/0x80/0xC0/0xC1/0xC4/0xC5, which
    ///            decomposes cleanly under this reading and under no other.
    ///            bit1 and bit4 are assigned from the matching upstream
    ///            layout, not from a capture — no capture pressed the other
    ///            barrel button or inverted the pen.
    ///
    ///            `[3] == 0x00` is the proximity-exit frame, and it is the
    ///            answer to a question this investigation spent two capture
    ///            rounds on: the exit event was being searched for as an
    ///            `0x80`-class value of the [1] discriminator, following the
    ///            legacy Intuos state machine, and it is not there. It is
    ///            here. `ptk-870-pen-2-proximity.txt` (three deliberate
    ///            approach/withdraw cycles) shows the sequence
    ///            0x80 → 0xC0 → 0x80 → 0x00 exactly three times, one
    ///            single-frame 0x00 per withdrawal.
    ///   [4..6]   X coordinate, 20 bits: [4] low, [5] mid, low nibble of [6]
    ///            high. **The high nibble is the whole story of this
    ///            device's edge behavior.** X was read as a plain LE16 for
    ///            two prior rounds, and 69800 does not fit in 16 bits: every
    ///            stroke crossing 65536 (327.7mm from the left edge — the
    ///            rightmost ~21mm of a 349mm surface) wrapped to a small
    ///            value and the cursor jumped to the opposite edge. The
    ///            earlier "X freezes at 4264 near the right corners" finding
    ///            was this same bit: 4264 is 69800 − 65536, i.e. the pen
    ///            resting at the true right edge with bit 16 discarded. A
    ///            previous search for the missing byte correctly found that
    ///            no whole byte increments at the wrap — because the carry
    ///            lands in a nibble that shares byte [6] with Y's low bits,
    ///            which a byte-granular search cannot see. Verified on the
    ///            two wrap events in `ptk-870-bt-x-shape-edge.txt` (bit sets
    ///            on the 65531 → 10 climb, clears on the 7 → 65526 descent)
    ///            and across all 34 captures on hand: reconstructed X reaches
    ///            exactly 69800 at the right edge and never once exceeds it.
    ///   [6..8]   Y coordinate, 20 bits: high nibble of [6] low, then [7],
    ///            then [8]. Same value the previous code produced — it read
    ///            [6..8] as a 24-bit field and scaled by 39000/624000, which
    ///            is exactly a shift of 4 — but written as the field the
    ///            hardware actually sends, which is what frees [6]'s low
    ///            nibble for X above. 624000 was never a hardware ceiling;
    ///            it is 39000 × 16.
    ///   [9..10]  pressure, LE u16, real range 0…8191 = `spec.maxPressure`.
    ///            The previous code read byte [10] alone, whose observed
    ///            0…31 ceiling was recorded as "probably these older pens'
    ///            real mechanical range." It was not: [10] is the high byte,
    ///            31 << 8 | 255 = 8191, and `ptk-870-pressure-spiral.txt`
    ///            walks the full 13-bit range smoothly. Reading [10] alone
    ///            reported every stroke at 1/256th of its true force.
    ///   [11]     tilt X, signed byte, ±64 (`spec.tiltMaxDegrees`)
    ///   [12]     tilt Y, signed byte, ±64
    ///            Both confirmed against four held-static poses, which are
    ///            bit-identical frame to frame for every byte up to [12] and
    ///            so isolate tilt cleanly: lean left gives [11] = +60, lean
    ///            right −60, with [12] ≈ 0; lean up gives [12] = +57, lean
    ///            down −59, with [11] ≈ 0. `ptk-870-tilt.txt` walks [11]
    ///            smoothly from 0 through −64 (flat left), back through 0 to
    ///            +63 (flat right) and home, saturating at both rails.
    ///            Sign is passed through unnegated, as every other decoder
    ///            here does; checked against the USB path rather than
    ///            assumed, by comparing the same natural-grip gesture on both
    ///            transports (`ptk-870-usb-hover-left-to-right.txt` median
    ///            tilt +13/−34, BLE +11/−8 — same signs, same axes).
    ///   [15]     hover distance — 20 with the tip down, rising as the pen
    ///            lifts, railed at 255 once it is out of range. Confirmed
    ///            2026-09-18 against pressure as ground truth (every
    ///            tip-down sample in two pressure captures reads exactly 20)
    ///            and cross-checked against USB, whose 0x1E report carries
    ///            the same field at its own byte [19] with the same
    ///            behaviour — railed at 255 in a groove trace, ~100-117 in
    ///            bounds. NOT read by this decoder, deliberately: inside the
    ///            rim it agrees with the status byte's close-fix bit on
    ///            100.00% of 132,754 samples with zero disagreements in
    ///            either direction, so the rule below is already a distance
    ///            test and reading this would change nothing. Recorded
    ///            because it explains WHY that rule works, and because a
    ///            future question about hover height should start here.
    ///   [18]     buttons — one-hot, bits 0-3 = left ExpressKeys (4 keys),
    ///            bits 4-7 = right ExpressKeys (4 keys). Confirmed via
    ///            isolated left-only and right-only key-press captures.
    ///   [19]     dial + cluster-active flags — bit0 = left-key-cluster
    ///            active, bit1 = right-key-cluster active, bit2 = left dial
    ///            active, bit3 = left dial rotating CCW (clear = CW), bit4 =
    ///            right dial active, bit5 = right dial rotating CCW (clear =
    ///            CW). Confirmed via isolated left-dial/right-dial/CW/CCW
    ///            captures — no bit overlap with the button bits. NOT
    ///            confirmed: per-frame step magnitude. The one raw sequential
    ///            dial capture on hand shows the active bit held across many
    ///            consecutive reports at a steady ~10 Hz for the whole
    ///            rotation gesture, not one report per physical detent —
    ///            emitting `delta: ±1` on every such frame below is a
    ///            placeholder that will over-report rotation speed if that
    ///            reading is right. A capture of a single, deliberate,
    ///            one-detent dial click (versus a multi-second continuous
    ///            spin) is needed to confirm whether this field ticks once
    ///            per detent or free-runs while held.
    ///
    /// Still unassigned: [2] and [16..17]. [2] tracks [3]'s upper bits
    /// loosely (0x00 while out of range, 0x80 or 0x20 in range) and may be a
    /// tool-type or slot field; [16..17] change every frame even under a
    /// held-static pose, so they're timing or sequence data.
    ///
    /// [13..14] is Art Pen barrel rotation, confirmed 2026-09-19 against two
    /// labelled stand captures (`ptk-870-bt-wacom-stand-art-pen.txt`, `-02`):
    /// a signed 12-bit count at byte [13] plus [14]'s low nibble, same
    /// -900..899/5-counts-per-degree convention as USB, just narrower and
    /// packed differently. [14]'s high nibble is a separate 16-step rolling
    /// frame counter — it must be masked off, not folded into the rotation
    /// value, or the counter aliases as rotation noise. Decoded
    /// unconditionally, not gated on tip switch or tool identity — see
    /// `decodeBLEReport`'s rotation comment for why gating on tool code
    /// doesn't work here and why decoding unconditionally is still safe. The
    /// Art Pen wheel upstream also carries in this region is not decoded
    /// here.
    ///
    /// Discriminator byte [1] follows Wacom's legacy Intuos proximity
    /// state-machine bit convention (`wacom_intuos_inout()` in the Linux
    /// `input-wacom` driver): high bits are a packet-class field, the low
    /// bit is a slot index. Every discriminator value actually observed
    /// decomposes cleanly: `0x02` = idle, `0x21`/`0x22` = in-range (class
    /// 0x20, slot 1/0), `0x41`/`0x42` = in-range/reporting (class 0x40, slot
    /// 1/0). It is NOT the proximity signal — `0x02` carries live hover and
    /// contact data throughout — and proximity is read from [3] instead, per
    /// above. Frames whose [3..9] payload matches one of the two
    /// bit-identical per-slot templates (`c0 81 90 80 24 04 08` slot 0,
    /// `c0 88 95 80 35 02 08` slot 1) are sync/keepalive markers, not pen
    /// data, and are filtered out — the slot-1 one is the edge bounceback,
    /// see the filter's own comment.
    ///
    /// Discriminator `0x01` is dual-purpose. Most `0x01` frames are a fixed
    /// phantom point (X 17244, Y 9752, recurring byte-for-byte in live bug
    /// captures) and are rejected outright below. But the very first `0x01`
    /// frame after a pen enters proximity is different: a one-shot
    /// announcement carrying the pen's real serial and tool code at
    /// [4..9] — byte-for-byte identical to the extended USB report's
    /// [20..25] field (see `decodeExtendedPenReport`), confirmed
    /// 2026-09-18 on a deliberate two-pen swap capture
    /// (`ptk-870-bt-tool-swap.txt`): Pen 1's announcement carried serial
    /// 0x2618435c/toolCode 0x0200 (Pro Pen 3), Pen 2's carried a different
    /// serial and toolCode 0x0802, and both matched that same pen's
    /// USB-decoded identity exactly. Byte [10] in this frame has no USB
    /// counterpart and is left undecoded. This is why identity is read
    /// before, not after, the phantom-point rejection below — the
    /// announcement is real data, just not a position.
    ///
    /// This is also the fix for the PTK-870 misreporting its pen as an Art
    /// Pen over Bluetooth: USB already decoded tool identity correctly, but
    /// nothing here did, so `state.lastToolCode` simply never left whatever
    /// it was last set to.
    private func decodeBLEReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let discriminator = report[1]
        let status = report[3]

        // Fixed sync/keepalive templates — not live pen data, one per slot.
        // Computed here (not just below) because they've been observed
        // arriving mistagged as discriminator 0x01: their constant bytes
        // then decode to a syntactically valid but fake serial+toolCode,
        // trusted as a permanent new pen. See the fuller template comment
        // below this function's serial/toolCode read.
        let isTemplateFrame =
            (report[3] == 192 && report[4] == 129 && report[5] == 144
                && report[6] == 128 && report[7] == 36 && report[8] == 4
                && report[9] == 8)
            || (report[3] == 192 && report[4] == 136 && report[5] == 149
                && report[6] == 128 && report[7] == 53 && report[8] == 2
                && report[9] == 8)

        // Tool-enter announcement — see the discriminator note above. Read
        // before the phantom-point/template rejection below so this one real
        // 0x01 frame isn't thrown out with the rest of them; the frame is
        // still identity-only and never reaches position decode.
        // `!isTemplateFrame` guards the mistagged-template case above.
        if discriminator == 0x01, length >= 10, !isTemplateFrame {
            let serial =
                UInt32(report[4])
                | UInt32(report[5]) << 8
                | UInt32(report[6]) << 16
                | UInt32(report[7]) << 24
            let toolCode = UInt16(report[8]) | UInt16(report[9]) << 8
            if toolCode != 0 {
                state.currentToolCode = toolCode
                let toolChanged =
                    serial != 0
                    ? serial != state.lastSerial
                    : toolCode != state.lastToolCode
                if toolChanged {
                    state.lastSerial = serial
                    state.lastToolCode = toolCode
                    let artPen = toolCode == 0x0804 || toolCode == 0x1108
                    var announceResults: [DecodeResult] = [
                        .toolEnter(
                            ToolIdentity(
                                serial: serial, toolCode: toolCode,
                                isEraser: !artPen && (toolCode & 0x0008) != 0,
                                isMouse: false))
                    ]
                    emitToolCompatibility(
                        toolCode: toolCode, deviceFamily: deviceFamily,
                        state: &state, results: &announceResults)
                    return announceResults
                }
            }
        }

        // Fixed sync/keepalive templates — not live pen data. There is one
        // per slot, and they are byte-identical across every occurrence in
        // every capture on hand except byte [14]'s rolling frame counter:
        //
        //   slot 0 (discriminator 0x41): c0 81 90 80 24 04 08 11 00 04 08
        //   slot 1 (discriminator 0x21): c0 88 95 80 35 02 08 11 00 02 08
        //
        // Only the 0x41 one was known until 2026-09-18, because no earlier
        // capture exercised slot 1 meaningfully. The 0x21 template is the
        // "edge bounceback": it is emitted as the pen leaves the active
        // area, and it decodes to a fixed phantom point near the middle of
        // the tablet (X 38280, Y 9048) carrying a fixed phantom pressure of
        // 4360 — so a cursor correctly pinned at the edge gets thrown back
        // into view for a single frame, then returns to the edge. Confirmed
        // on four deliberate see-saw captures, one per edge
        // (`ptk-870-bt-edge-bounce-{left,right,top,bottom}.txt`): 26 of these
        // frames appear bracketed on both sides by a railed coordinate, at
        // all four edges, always decoding to the same two values regardless
        // of which edge the pen crossed or where it was.
        //
        // Both templates carry the same giveaway pressure bytes ([9..10] =
        // 08 11) and differ only at [12], which tracks the slot — but they
        // are matched here on their full literal [3..9] signature rather
        // than on that shared pattern, since each signature occurs with
        // exactly one [3..13] byte row and only ever alongside its own
        // discriminator, making the literal match both unambiguous and
        // narrower than a heuristic. (`isTemplateFrame` itself is computed
        // above, before the announcement branch, so both position decode and
        // identity share one check.)

        var results: [DecodeResult] = []

        // Buttons/dial are multiplexed into every frame, including idle
        // ones — decode unconditionally so a key/dial action fires even
        // when the pen itself isn't in proximity.
        let dialFlags = report[19]
        let buttons: [Bool] = (0..<8).map { bit in (report[18] & (1 << bit)) != 0 }
        results.append(
            .aux(
                AuxButtons(
                    buttons: buttons, mechanicalMask: report[18],
                    touchRingButtonDown: (dialFlags & 0x01) != 0,
                    touchRing2ButtonDown: (dialFlags & 0x02) != 0)))
        if (dialFlags & 0x04) != 0 {
            results.append(.wheel(index: 0, delta: (dialFlags & 0x08) != 0 ? -1 : 1))
        }
        if (dialFlags & 0x10) != 0 {
            results.append(.wheel(index: 1, delta: (dialFlags & 0x20) != 0 ? -1 : 1))
        }

        guard discriminator != 0x01, !isTemplateFrame else { return results }

        // Out of range. The coordinate bytes still hold the last tracked
        // position in this frame, so ignore them and emit one synthetic exit
        // rather than a final point at a stale location.
        guard (status & 0x80) != 0 else {
            // The barrel gate deliberately SURVIVES this. An earlier version
            // disarmed here, reasoning that the pen had genuinely left and
            // the next approach deserved a clean slate. On real hardware
            // that was the single biggest hole in the gate: while ghosting
            // in the bezel the tablet emits a one-frame proximity exit of
            // its own, and disarming on it let the very next barrel sample
            // through as a fresh position. In a full-width top-edge see-saw
            // that one line accounted for most of the surviving jumps —
            // removing it took that capture from 54 to 3.
            guard state.prevInProximity else { return results }
            state.prevInProximity = false
            // Force re-latch on the next approach — the announcement frame
            // may belong to a different pen next time, and there's no other
            // signal that says so.
            state.lastSerial = 0
            state.lastToolCode = 0
            results.append(
                .pen(
                    TabletPoint(
                        x: state.lastX, y: state.lastY,
                        maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: state.lastTiltX, tiltY: state.lastTiltY,
                        rotation: 0.0,
                        penButton1: false, penButton2: false,
                        eraser: false, inProximity: false, hoverDistance: 0)))
            return results
        }

        let x = Int(report[4]) | Int(report[5]) << 8 | Int(report[6] & 0x0f) << 16
        let y = Int(report[6] >> 4) | Int(report[7]) << 4 | Int(report[8]) << 12
        // Both fields are wide enough to express values the sensor never
        // reaches, so an out-of-range reading means a frame that isn't a
        // position at all. Drop it rather than clamping it to an edge: a
        // clamp would park the cursor at a border it was never near.
        guard x <= spec.maxX, y <= spec.maxY else { return results }

        // Off the drawable surface entirely — the pen is in the moulded
        // groove around the rim, or over the bezel, where it should produce
        // nothing at all.
        //
        // This is a different failure from the barrel leaps below, and it
        // does not look like one: groove motion is smooth and continuous, so
        // the continuity gate has nothing to say about it and passes 100% of
        // it through. What the user sees is not a jump but well-behaved
        // tracking from a pen that is nowhere near the surface.
        //
        // Position cannot separate these two cases, which is the surprise
        // here. Four deliberately labelled captures settle it: a trace along
        // the legitimate top border (`ptk-870-bt-top-border.txt`, described
        // as tracking flawlessly) sits at Y = 0 exactly, at the limit, for
        // essentially every sample — while traces along the physical grooves
        // beyond each edge (`ptk-870-bt-{top,bottom,left}-groove.txt`) report
        // coordinates that fold back roughly 850 units INSIDE the limit. The
        // out-of-bounds pen reads as further inside the surface than the
        // in-bounds one, so no inset, matte or clamp can tell them apart.
        //
        // The status byte can, cleanly. The in-bounds border trace carries a
        // close tip fix (bit 6) in 99.8% of its samples; the three groove
        // traces carry one in 0%, 0% and 4%. The tablet knows it has lost the
        // tip and says so. Bit 6 alone is not enough — it also clears during
        // ordinary high hover, which must keep tracking — so this pairs it
        // with the rim, where the fold-back lands. Measured at this width:
        // the grooves and the bezel captures drop to 0-17% of their samples
        // while the border trace, pressure, tilt and the hover sweeps all
        // stay at 96-100%.
        // Arming the barrel gate here as well as below is deliberate: a
        // sample rejected by the rim rule still tells us where the pen is,
        // and the rim is precisely where barrel takeover starts. Returning
        // without arming would leave the gate asleep for the samples that
        // follow the pen back out of the groove.
        if (status & 0x40) == 0,
            Self.distanceToNearestEdge(x: x, y: y, spec: spec) <= Self.rimBand
        {
            state.bleOutsideSurface = true
            state.bleBarrelDropCount = 0
            return results
        }

        // Barrel-takeover gate.
        //
        // Once the pen tip passes the edge of the sensing surface, this
        // hardware keeps reporting a position — but it is no longer coming
        // from the tip. It comes from the pen's barrel, and the cursor snaps
        // inward to wherever the barrel is. Confirmed 2026-09-18 on four
        // deliberate see-saw captures, one per edge: every large jump at a
        // boundary points along the reported tilt vector, mean angular error
        // 7.2° where unrelated vectors would average 90°, and `|tilt| >= 40`
        // occurs in 49% of railed frames versus 0% of interior frames. It is
        // not the eraser end taking over (the same thing happens on a Pro
        // Pen 3, which has no eraser) and it is not a decode error — the
        // bytes are a faithful reading of a measurement of the wrong end of
        // the pen.
        //
        // There is no single-frame signal that separates this from ordinary
        // behaviour: the ghost reports status 0x80 with zero tilt near a
        // border, and so does legitimate high hover (570 of 571 frames in a
        // capture the user described as tracking well) and so does
        // deliberate edge tracing. Filtering on that signature costs both
        // outright. What does separate them is continuity. Measured across
        // all 59 transitions off a railed edge in those captures: a genuine
        // re-entry moves at most 254 units in a frame (mean 60), while every
        // barrel jump is at least 2648 — a 10x gap with nothing in it, so
        // the threshold below sits in empty space rather than being tuned to
        // a distribution's tail.
        //
        // Hence: entering the border band arms the gate, because that is
        // where the tip may already be off the drawable area. While armed, a
        // discontinuous sample is the barrel and is dropped; a continuous one
        // that lands back inside the band's inner edge is the tip and disarms
        // the gate. The continuity check deliberately applies to samples
        // sitting on a limit as well — an earlier version exempted them, and
        // the ghost simply slid along the boundary instead, jumping thousands
        // of units in Y while pinned at X = maxX.
        //
        // The gate survives a proximity exit on purpose — see the exit
        // branch above for why, it was the largest single hole in the first
        // version — and bounds its own rejections, because a rejected sample
        // does not update the reference position and an unbounded gate can
        // therefore latch forever against a stale one.
        //
        // KNOWN LIMIT, measured, not glossed: on a full-width top-edge
        // see-saw this takes jumps over 1500 units from 125 to 3 and the
        // worst single jump from 5558 to 3234, but it does not reach zero.
        // Arming more eagerly (on status 0x80 near a border) was tried and
        // rejected: it takes legitimate edge tracing to zero retention.
        if state.bleOutsideSurface {
            let dx = Double(x - state.lastX)
            let dy = Double(y - state.lastY)
            let step = (dx * dx + dy * dy).squareRoot()
            if step > Self.bleBarrelJumpThreshold,
                state.bleBarrelDropCount < Self.bleBarrelMaxConsecutiveDrops
            {
                state.bleBarrelDropCount += 1
                return results
            }
            if step <= Self.bleBarrelJumpThreshold,
                !Self.isNearSurfaceLimit(x: x, y: y, spec: spec)
            {
                state.bleOutsideSurface = false
            }
            state.bleBarrelDropCount = 0
        }
        if Self.isNearSurfaceLimit(x: x, y: y, spec: spec) {
            state.bleOutsideSurface = true
            state.bleBarrelDropCount = 0
        }

        let pressure = Int(report[9]) | Int(report[10]) << 8
        let tiltDivisor = spec.tiltMaxDegrees ?? 64.0
        let tiltX = Double(Int8(bitPattern: report[11])) / tiltDivisor
        let tiltY = Double(Int8(bitPattern: report[12])) / tiltDivisor

        // Art Pen barrel rotation: same signed-count convention as USB
        // (-900..899, 5 counts/degree), but packed into 12 bits here instead
        // of 16 — bytes [13..14], with [14]'s high nibble reused as a
        // free-running frame counter. Sign-extend from bit 11, not bit 15.
        // Confirmed against two labelled stand captures that hold the pen at
        // known angles and twist it through several turns
        // (`ptk-870-bt-wacom-stand-art-pen.txt`, `-02.txt`): decoded values
        // track every labelled pose to within 2° and unwrap cleanly across
        // multi-revolution twists.
        //
        // Not gated on tool identity: BLE's tool-enter announcement (`0x01`)
        // is one-shot and often never arrives in a session (confirmed: zero
        // `0x01` frames across an entire capture where the pen was already
        // in proximity when capture started), so `currentToolCode` can't be
        // trusted to gate this per-session. Decoding unconditionally is
        // safe — checked across every non-Art-Pen BT capture on hand
        // (thousands of real position frames: edge traces, grooves, bezel
        // work, tilt tests), this field sits pinned at 179.6–180.0° (raw
        // count 0, i.e. inert) the entire time. A pen with no rotation
        // sensor reports a fixed neutral value here, not noise.
        let packed = UInt16(report[13]) | (UInt16(report[14] & 0x0F) << 8)
        let rawRotation = Int16(bitPattern: packed << 4) >> 4
        var rotation = (900.0 - Double(rawRotation)) / 5.0
        if rotation < 0 { rotation += 360.0 }
        if rotation >= 360 { rotation -= 360.0 }

        state.prevInProximity = true
        state.lastX = x
        state.lastY = y
        state.lastTiltX = tiltX
        state.lastTiltY = tiltY
        state.hasValidTiltFrame = true

        var blePoint = TabletPoint(
            x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
            pressure: pressure, maxPressure: spec.maxPressure,
            tiltX: tiltX, tiltY: tiltY, rotation: rotation,
            penButton1: (status & 0x02) != 0,
            penButton2: (status & 0x04) != 0,
            eraser: (status & 0x10) != 0,
            inProximity: true, hoverDistance: 0)
        // Same third barrel button as the USB extended report — see the
        // comment on decodeExtendedPenReport's equivalent assignment.
        blePoint.penButton3 = (status & 0x08) != 0
        results.append(.pen(blePoint))
        return results
    }

    // MARK: - 0x06 alternate BLE report (unrouted until now — see caveats below)

    /// Surfaced by exactly one capture on hand
    /// (`ptk-870-bt-art-pen-pressure+rotation.txt`, a deliberate Art Pen
    /// rotation test, ~1060 frames), and not previously handled at all — an
    /// earlier comment on `decodeBLEReport` assumed this report ID was an
    /// inert, mostly-zero idle frame sent before DATAMODE is armed. It is
    /// not: this capture's data-mode init already ran (the device is also
    /// emitting normal `0x1A` battery/pen activity implied by the session),
    /// and 0x06 carries what looks like live pen data throughout, changing
    /// on nearly every frame. Whether it is a genuine alternate pen-motion
    /// report on some connection/firmware state, or something specific to
    /// this one gesture, is unknown — this is the only capture that has it.
    ///
    /// Byte-by-byte survey of all 1060 frames in that capture:
    ///   [0]      = 0x06  report ID
    ///   [1]      = 0x01  constant in every frame — unexplained
    ///   [2]      status-like: 0x41 in 1038/1060 frames, 0x40 in 22, 0x00 in
    ///             the single last frame (proximity exit?). Consistent with
    ///             the bit0=tip-switch convention used elsewhere in this
    ///             file (0x41 = 0x40 | 0x01), but that is pattern-matching,
    ///             not confirmation — no capture exists with the tip
    ///             deliberately lifted mid-stream to check bit0 toggles
    ///             independently of bit6.
    ///   [3]      strongest rotation candidate. Full 0-255 range, wraps
    ///             cleanly, not gated on the tip switch the way
    ///             `decodeExtendedPenReport`'s rotation field is. That other
    ///             field turned out to be a signed LE16, not a single byte,
    ///             so this one may have the same problem — but no adjacent
    ///             byte here varies enough to pair with it as an LE16 half
    ///             ([4] and [6] barely move; [3], [5], [7] are each
    ///             independently full-range). Don't copy that formula here
    ///             without new evidence pinning down the real field.
    ///   [4]      constant 0x3c/0x3d (60/61) — plausible high byte of a
    ///             stationary X, but with only two adjacent values seen
    ///             across the whole capture there is no way to derive a bit
    ///             width or scale factor from this alone.
    ///   [5]      varies smoothly 0-254 — plausible X or Y low byte, again
    ///             unconfirmed: the pen was held roughly stationary while
    ///             rotating in place, so small smooth drift is equally
    ///             consistent with hand tremor as with a real position
    ///             field, and there is no second capture to cross-check
    ///             against.
    ///   [6]      constant 0x29/0x2a/0x2b (41-43) — same caveat as [4].
    ///   [7..8]   LE u16, mixed with [6]'s low range in a way that doesn't
    ///            resolve cleanly to either X or Y against this decoder's
    ///            existing 20-bit BLE coordinate packing (`decodeBLEReport`
    ///            unpacks X from [4..6] and Y from [6..8] sharing a
    ///            nibble of [6] — this report's [4..8] span doesn't fit
    ///            that shape, since [4] and [6] are each observed constant
    ///            while [7..8] move together). Left unassigned.
    ///   [9..10]  LE i16 (signed), NOT pressure. A prior quick pass guessed
    ///            pressure here; checking it against this capture rules
    ///            that out: read as signed, the value sweeps smoothly
    ///            400 → 300 → ... → 0 → -100 → -200 and back over the
    ///            course of the capture, tracking in step with the [3]
    ///            rotation candidate's movement, and pressure cannot go
    ///            negative on any decoder in this file. Quantized in exact
    ///            steps of 100 the entire time — never an intermediate
    ///            value — which also doesn't match this device's smooth
    ///            13-bit pressure curve seen on `decodeBLEReport`/
    ///            `decodeExtendedPenReport`. Most likely a second rotation-
    ///            adjacent signed field (sub-count? a coarser companion to
    ///            [3]?) but not confidently identified.
    ///   [11..12] mostly 0, occasionally (0x9c, 0xff) = -100 read as LE i16,
    ///            correlated with the same stretches [9..10] go negative.
    ///            Unassigned; likely related to whatever [9..10] is.
    ///   [13]     varies 27-255, moves opposite in trend to [3] over long
    ///            stretches — possibly a second angle representation, not
    ///            confirmed.
    ///   [14]     changes on every single frame, full 0-255 range — a
    ///            rolling counter or sub-frame timestamp, matching the
    ///            pattern `decodeBLEReport`'s own header documents for its
    ///            byte [14] high nibble.
    ///   [15..16] together span the full 0-255 range and increment roughly
    ///            monotonically across the capture (only local wobble) —
    ///            almost certainly a 16-bit frame counter or device
    ///            timestamp, same role as `decodeBLEReport`'s [13]/[16..17].
    ///   [17]     constant 100 (0x64) — unassigned, possibly a fixed
    ///            capability/slot marker.
    ///   [18..19] constant 0x00 — unassigned/padding.
    ///
    /// Given how much of this layout is genuinely unverified — X/Y bit
    /// width and scale cannot be derived from two adjacent stationary
    /// samples, the pressure-shaped field turned out not to be pressure,
    /// and the whole report has appeared in exactly one capture — this
    /// deliberately does NOT attempt a full pen-motion decode. Emitting
    /// `.pen` from a guessed coordinate packing risks a wrong position
    /// silently overwriting good state from `decodeBLEReport`/
    /// `decodeExtendedPenReport` on whatever device or mode combination
    /// triggers this report. Even the rotation candidate at [3] is not
    /// emitted: its gating rule and field width/scale are both unconfirmed
    /// (see the survey above). This is a different field from the one
    /// `decodeBLEReport` now decodes at [13..14] on the normal `0x1A`
    /// report — that one's confirmed; this one still isn't.
    ///
    /// So for now this function only records that the report exists and
    /// returns no results — better than silently dropping it through
    /// `default` with no trace it was ever seen. If a future capture
    /// confirms byte [3]'s gating rule and either pins down [4..8] as real
    /// coordinates or confirms they should stay ignored, promote this to
    /// return an actual `.pen`/rotation update.
    private func decodeAltBLEReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex
    ) -> [DecodeResult] {
        []
    }
}
