// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom IntuosV3 HID report format.
///
/// "V3" is TabletKit's protocol generation, unrelated to `Intuos3Decoder`.
/// Used by the PTK-470 (0x03F5), PTK-670 (0x03F7), and PTK-870 (0x03F9)
/// Intuos Pro, and the Movink 13 (0x03F0) pen display.
///
/// Report IDs:
/// 0x1A  Bluetooth LE pen and pad; see `decodeBLEReport`
/// 0x1E  extended pen report, 24-bit XY; see `decodeExtendedPenReport`
/// 0x1F  pen report, 16-bit XY, from OpenTabletDriver's tables; never seen
///       in a capture
/// 0x11  aux: 8 express keys, 2 cluster-center keys, 2 dials
/// 0x1B  Bluetooth LE battery
/// 0x06  Bluetooth LE standard digitizer report, sent without DATAMODE
///
/// The pen-status byte sits at [2], not [1] as on IntuosV2's 0x10. 0x11 and
/// 0x1E are confirmed on PTK-870 and Movink 13 captures.
package struct IntuosV3Decoder: TabletReportDecoder {

    /// Largest single-frame move, in device units, still treated as the pen
    /// tip while the barrel-takeover gate is armed — see `decodeBLEReport`.
    /// Sits inside a measured empty gap: genuine re-entries move at most 254
    /// units per frame, barrel jumps at least 2648.
    private static let bleBarrelJumpThreshold = 1000.0

    /// Consecutive samples the barrel gate may reject before trusting the pen
    /// again; see `decodeBLEReport`. A rejected sample doesn't move the
    /// reference, so without a bound a pen that keeps going never passes the
    /// continuity test. 32 samples is about a third of a second.
    private static let bleBarrelMaxConsecutiveDrops = 32

    /// Width of the border band, in device units, within which a report is
    /// suspect: 4000 units is 20mm at 200 units/mm. It arms the Bluetooth
    /// barrel gate and bounds the USB off-surface rule.
    ///
    /// A pen over the bezel still resolves a position a couple of thousand
    /// units short of the limit, so arming only at the limit missed every
    /// barrel jump in the captures; this band catches them all.
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
    /// Sized from captures: at 1000 units the bezel on either side of the
    /// groove still leaked. Wider costs little, since in-bounds work carries
    /// a close tip fix and this rule only looks at reports without one. It
    /// does drop high hover within 8.5mm of an edge, which on this hardware
    /// looks the same as a pen in the groove.
    private static let rimBand = 1700

    private static func distanceToNearestEdge(x: Int, y: Int, spec: DigitizerSpec) -> Int {
        Swift.min(x, spec.maxX - x, y, spec.maxY - y)
    }

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
        case 0x1F:
            // OTD gates on data[1] == 0x01; other 0x1F payloads are unknown.
            guard report.count >= 14, report[1] == 0x01 else { return [] }
            return decodePenReport(
                report: report, spec: spec, state: &state,
                deviceFamily: deviceFamily)
        case 0x1E:
            guard report.count >= 20 else { return [] }
            return decodeExtendedPenReport(
                report: report, spec: spec, state: &state,
                deviceFamily: deviceFamily)
        case 0x11:
            return decodeAuxReport(report: report, state: &state)
        case 0x1A:
            guard report.count >= 20 else { return [] }
            var results = decodeBLEReport(
                report: report, spec: spec, state: &state,
                deviceFamily: deviceFamily)
            Self.inferArtPenFromRotation(&results, state: &state)
            return results
        case 0x1B:
            // Only byte [1] is read, which the length >= 2 guard above covers.
            return decodeBatteryReport(report: report, state: &state)
        case 0x06:
            guard report.count >= 13 else { return [] }
            return decodeStandardDigitizerReport(
                report: report, spec: spec, state: &state,
                deviceFamily: deviceFamily)
        default:
            return []
        }
    }

    // MARK: - 0x1B battery status

    /// BLE status report, once per second. It's 20 bytes, but only byte [1]
    /// carries data, so the guard needs just that byte.
    ///
    ///   [1] bit7   = charging
    ///   [1] bits6:0 = battery percent
    ///
    /// The same encoding as the kernel's `wacom_intuos_gen3_bt_battery()`,
    /// at an offset taken from captures. Emitted only on change.
    private func decodeBatteryReport(
        report: HIDReport,
        state: inout State
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
    /// No serial or tool code is known for this report, so no `.toolEnter`
    /// goes out.
    private func decodePenReport(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
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

        let x = report.le16(at: 3)
        let y = report.le16(at: 5)
        let pressure = report.le16(at: 7)
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

    /// Confirmed on PTK-870 captures (`whot/wacom-recordings`) and a
    /// Movink 13 capture that presses all three barrel buttons.
    ///
    ///   [0]       = 0x1E  report ID
    ///   [2]       pen status: bit0=tip-switch echo (not a button),
    ///                        bit1=button1, bit2=button2, bit3=button3,
    ///                        bit5=eraser, bit6=tip switch, bit7=proximity
    ///             bit6 is also set on every hover frame with measured tilt, so
    ///             it may mean "range", as in Wacom's Pro 2022 report.
    ///   [3..5]    X coordinate, 24-bit (LE u16 at [3..4] | byte[5] << 16)
    ///   [6..8]    Y coordinate, 24-bit (LE u16 at [6..7] | byte[8] << 16)
    ///   [9..10]   pressure, LE u16
    ///   [11..12]  tilt X, signed LE i16
    ///   [13..14]  tilt Y, signed LE i16
    ///   [15..16]  Art Pen barrel rotation, signed LE16, -900..899, 1800
    ///             counts per revolution, as in IntuosV2Decoder
    ///   [19]      hover distance — smallest with the tip down, rising as the
    ///             pen lifts, railed at 255 once it is out of range. The BLE
    ///             report carries the same field at its own byte [15].
    private func decodeExtendedPenReport(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let status = report[2]
        let prox = (status & 0x80) != 0

        if !prox {
            guard state.prevInProximity else { return [] }
            state.prevInProximity = false
            // The held rotation belongs to the pen that just left. Clearing it
            // here stops the next tool that enters from inheriting it — the
            // same reason IntuosV2Decoder clears on its own exit paths.
            state.lastRotation = 0.0
            state.hasValidRotationFrame = false
            // Force a fresh `.toolEnter` on the next approach: `toolChanged`
            // compares against `lastSerial`, and the app learns the tool code
            // only from a `.toolEnter`.
            state.lastSerial = 0
            state.lastToolCode = 0
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

        let x = report.le24(at: 3)
        let y = report.le24(at: 6)
        let pressure = report.le16(at: 9)
        let rawTiltX = report.signedLE16(at: 11)
        let rawTiltY = report.signedLE16(at: 13)
        // Raw tilt spans -64...63 on a Movink 13 capture: degrees, not a
        // 16-bit fraction.
        let tiltDivisor = spec.tiltMaxDegrees ?? 64.0
        let tiltX = Double(rawTiltX) / tiltDivisor
        let tiltY = Double(rawTiltY) / tiltDivisor
        let hoverDistance = Int(report[19])

        // Stub frame: the tablet interleaves position-only reports among full
        // ones, with tilt, rotation, and hover zeroed or railed rather than
        // measured. Stubs arrive as 0x80 (proximity only), full frames as
        // 0xC0 and up.
        //
        // A stub's 255 is the absence of a hover reading, not a measurement,
        // which is why rotation below replays its last value instead of
        // resetting. The off-surface gate further down does not exempt stubs;
        // see the note there.
        let tipSwitch = (status & 0x40) != 0

        // Rotation (Art Pen barrel twist): signed LE16 at bytes [15..16],
        // gated on the tip switch, not on pressure. Other pens leave 0 or
        // garbage here.
        let isArtPen = Self.hasBarrelRotation(state.currentToolCode)
        let rawRotation = report.signedLE16(at: 15)
        // A raw 0 is the tablet's "no reading" filler, not an angle; mapped
        // to 180° it flipped rotation between extremes. Rotation updates only
        // on frames with a count, and others replay the last reading.
        var rotation: Double
        if isArtPen && tipSwitch && rawRotation != 0 {
            rotation = (900.0 - Double(rawRotation)) / 5.0
            if rotation < 0 { rotation += 360.0 }
            if rotation >= 360 { rotation -= 360.0 }
            state.lastRotation = rotation
            state.hasValidRotationFrame = true
        } else if isArtPen && state.hasValidRotationFrame {
            rotation = state.lastRotation
        } else {
            rotation = 0.0
        }

        // Off the drawable surface: the pen is in the groove around the
        // tablet, or over the bezel, and should produce nothing.
        //
        // Past the edge the digitizer keeps reporting, at a position folded
        // back inside the rim, and leaps up to ~5000 units, on USB as on
        // Bluetooth. USB states the distance outright at byte [19], so one
        // test covers both: hover railed at 255, no pressure or tip, within
        // the border band. The leaps sit about 2266 units from an edge, so
        // the band, not the narrower rim, is the width.
        //
        // Don't widen it: a reference hover frame survives by 459 units at
        // 4000 and is cut at 5000. The rail alone isn't enough either, since
        // a pen held high over mid-tablet also reads 255
        // (`pen.pen-strong-vertical.hid` in whot/wacom-recordings).
        //
        // The pressure and tip conditions change nothing on the captures but
        // limit the damage on the Movink 13, which shares this function and
        // has no groove capture.
        //
        // Stubs meet every condition, so in-bounds stubs near an edge drop
        // too. Exempting them would undo the gate, since groove traffic is
        // mostly stubs; only distance separates the two.
        if hoverDistance == 255, pressure == 0, (status & 0x40) == 0,
            Self.distanceToNearestEdge(x: x, y: y, spec: spec) <= Self.surfaceBorderBand
        {
            return []
        }

        var results: [DecodeResult] = []

        // Pen serial (bytes 20-23 LE) and tool code (bytes 24-25 LE),
        // confirmed with a known Art Pen; both read 0 out of proximity.
        // Byte 26 is some other flag, not part of the tool code.
        if report.count >= 26 {
            let serial = report.le32(at: 20)
            let toolCode = UInt16(report.le16(at: 24))
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
                        toolIsSupported: &state.toolIsSupported, results: &results)
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

    /// Confirmed on a PTK-870, from its descriptor and recordings of every
    /// pad control (`whot/wacom-recordings`):
    ///   [0]   = 0x11 report ID
    ///   [1]   = express keys, all 8, one bit each
    ///   [2]   = reserved/constant
    ///   [3]   = cluster-center keys: bit 0 = left, bit 1 = right; bits 2–7
    ///           reserved
    ///   [4]   = left dial, 7-bit signed rotation delta (bit 7 ignored)
    ///   [5]   = right dial, 7-bit signed rotation delta (bit 7 ignored)
    ///
    /// The cluster-center keys aren't dial presses; the dials only rotate.
    /// They come out as `touchRingButtonDown` and `touchRing2ButtonDown`,
    /// like a ring's center click. Dial mode cycling uses an ordinary
    /// ExpressKey bound to `.ringCycle` instead.
    ///
    /// Dial deltas go out as `.wheel(index:delta:)`, so the app routes them
    /// through its ring slots with no state here.
    private func decodeAuxReport(
        report: HIDReport,
        state: inout State
    ) -> [DecodeResult] {
        guard report.count >= 2 else { return [] }
        let primary = report[1]
        let dialButtons: UInt8 = report.count >= 4 ? report[3] : 0
        let buttons: [Bool] = (0..<8).map { bit in (primary & (1 << bit)) != 0 }
        var results: [DecodeResult] = [
            .aux(
                AuxButtons(
                    buttons: buttons, mechanicalMask: Self.newPresses(primary, state: &state),
                    touchRingButtonDown: (dialButtons & 0x01) != 0,
                    touchRing2ButtonDown: (dialButtons & 0x02) != 0))
        ]
        // Sign-extend 7-bit values: shift the sign bit into bit 7, then
        // arithmetic-shift right to propagate it across the Int8 range.
        if report.count >= 5 {
            let leftDelta = Int((Int8(bitPattern: report[4]) << 1) >> 1)
            if leftDelta != 0 { results.append(.wheel(index: 0, delta: leftDelta)) }
        }
        if report.count >= 6 {
            let rightDelta = Int((Int8(bitPattern: report[5]) << 1) >> 1)
            if rightDelta != 0 { results.append(.wheel(index: 1, delta: rightDelta)) }
        }
        return results
    }

    /// Keys pressed since the last pad report. The key byte is live state,
    /// and Bluetooth repeats it in every in-range frame, so passed through as
    /// `mechanicalMask` it marks each frame of a held key as a fresh press.
    private static func newPresses(_ keys: UInt8, state: inout State) -> UInt8 {
        defer { state.lastExpressKeys = keys }
        return keys & ~state.lastExpressKeys
    }

    /// Art Pen (0x0804, 0x1108) and Art Pen 2 (0x0204), the pens whose
    /// barrel twist the tablet reports.
    static func hasBarrelRotation(_ toolCode: UInt16) -> Bool {
        toolCode == 0x0804 || toolCode == 0x1108 || toolCode == 0x0204
    }

    // MARK: - 0x1A Bluetooth LE report (pen + pad, single multiplexed interface)

    /// Barrel rotation decodes on every Bluetooth frame whatever the pen, and
    /// a pen without a rotation sensor sits at a fixed 180°. So a twisted
    /// barrel under a pen that isn't announced as an Art Pen means the Art
    /// Pen's announcement was missed: announce it here. One-directional,
    /// since a still Art Pen also reads 180°.
    ///
    /// `hasValidRotationFrame` is required: a pen with no barrel sensor never
    /// sets it, and rotation reads 0 until then, which is 180° off neutral.
    /// Without the check every Pro Pen 3 read as an Art Pen one frame after
    /// its real announcement.
    ///
    /// Writes `currentToolCode` only, never `lastToolCode` or `lastSerial`:
    /// those detect announcement changes, and setting them made a later real
    /// Art Pen announcement compare equal and get dropped.
    static func inferArtPenFromRotation(_ results: inout [DecodeResult], state: inout State) {
        let point = results.lazy.compactMap { result -> TabletPoint? in
            if case .pen(let point) = result { return point } else { return nil }
        }.first
        guard !Self.hasBarrelRotation(state.currentToolCode),
            let point, point.inProximity,
            state.hasValidRotationFrame,
            abs(point.rotation - 180.0) > 2.0
        else { return }
        state.currentToolCode = 0x0804
        results.insert(
            .toolEnter(ToolIdentity(serial: 0, toolCode: 0x0804, isEraser: false, isMouse: false)),
            at: 0)
    }

    /// The PTK-470/670/870 over Bluetooth LE expose one HID interface (page
    /// 0x01, usage 0x80, used as a vendor wrapper), and all pen and pad data
    /// comes through this report.
    ///
    /// Needs DATAMODE ([0x02, 0x02]) first; see the `.intuosV3` `initSteps`.
    /// Without it the tablet sends report 0x06; see
    /// `decodeStandardDigitizerReport`.
    ///
    /// The layout is the kernel's Intuos Pro 2 Bluetooth pen frame
    /// (`wacom_intuos_pro2_bt_pen`), with X and Y widened to 20 bits and
    /// bit-packed, which shifts every later field by one byte. Every field
    /// lands on the maxima the USB row declares (X 69800, Y 39000, pressure
    /// 8191, tilt ±64).
    ///
    ///   [0]      = 0x1A  report ID
    ///   [1]      packet class (low nibble) and rolling counter (high
    ///            nibble); compare only the low nibble
    ///   [3]      pen status, as the kernel's `frame[0]`: bit7 = in range,
    ///            bit6 = close enough for tilt and pressure, bit4 =
    ///            eraser/inverted, bit2 = barrel button 2, bit1 = barrel
    ///            button 1, bit0 = tip switch. bit1 and bit4 come from the
    ///            kernel; no capture exercised them. `0x00` is the
    ///            proximity-exit frame, one per withdrawal.
    ///   [4..6]   X, 20 bits: [4] low, [5] mid, low nibble of [6] high. As
    ///            a plain LE16, X wrapped past 65536 in the rightmost 21mm.
    ///   [6..8]   Y, 20 bits: high nibble of [6] low, then [7], then [8].
    ///   [9..10]  pressure, LE u16, 0…8191
    ///   [11]     tilt X, signed byte, ±64, same sign as USB
    ///   [12]     tilt Y, signed byte, ±64
    ///   [13..14] Art Pen barrel rotation: a signed 12-bit count in [13] and
    ///            [14]'s low nibble, -900..899 as on USB. [14]'s high nibble
    ///            is a frame counter and must be masked off. Decoded on
    ///            every frame; see the rotation comment below.
    ///   [15]     hover distance, 20 with the tip down, railed at 255 out of
    ///            range; USB carries it at [19]. Not read: inside the rim it
    ///            always agrees with status bit6, which the rule below uses.
    ///   [18]     keys, one-hot: bits 0-3 left ExpressKeys, bits 4-7 right
    ///   [19]     bit0 = left key cluster active, bit1 = right, bit2 = left
    ///            dial active, bit3 = left dial CCW (clear = CW), bit4 =
    ///            right dial active, bit5 = right dial CCW. One frame per
    ///            detent, so each flagged frame is a delta of ±1.
    ///
    /// Unassigned: [2], which loosely tracks [3]'s upper bits, and [16..17],
    /// which change every frame and look like timing data.
    ///
    /// Class 1 is identity, never a position: the pen's serial and tool code
    /// at [4..9], identical to the USB 0x1E report's [20..25]. Byte [10] is
    /// undecoded.
    private func decodeBLEReport(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let discriminator = report[1]
        let status = report[3]

        // Tool-enter announcement, read before the position guard rejects
        // its class. Low nibble only: the high bits are a rolling counter.
        if (discriminator & 0x0F) == 0x01, report.count >= 10 {
            let serial = report.le32(at: 4)
            let toolCode = UInt16(report.le16(at: 8))
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
                        toolIsSupported: &state.toolIsSupported, results: &announceResults)
                    return announceResults
                }
            }
        }

        // Match on class, not bytes: each pen's announcement carries its own
        // serial, so no fixed byte pattern holds.

        var results: [DecodeResult] = []

        // Buttons/dial are multiplexed into every frame, including idle
        // ones — decode unconditionally so a key/dial action fires even
        // when the pen itself isn't in proximity.
        let dialFlags = report[19]
        let buttons: [Bool] = (0..<8).map { bit in (report[18] & (1 << bit)) != 0 }
        results.append(
            .aux(
                AuxButtons(
                    buttons: buttons, mechanicalMask: Self.newPresses(report[18], state: &state),
                    touchRingButtonDown: (dialFlags & 0x01) != 0,
                    touchRing2ButtonDown: (dialFlags & 0x02) != 0)))
        if (dialFlags & 0x04) != 0 {
            results.append(.wheel(index: 0, delta: (dialFlags & 0x08) != 0 ? -1 : 1))
        }
        if (dialFlags & 0x10) != 0 {
            results.append(.wheel(index: 1, delta: (dialFlags & 0x20) != 0 ? -1 : 1))
        }

        // Class-1 frames never carry a position; compare the low nibble only,
        // since the high bits count. Decoded as coordinates, their fixed bytes
        // made a phantom tip-down point that sprang the cursor to one spot and
        // clicked. The announcement, also class 1, is read above.
        guard (discriminator & 0x0F) != 0x01 else { return results }

        // Out of range. The coordinate bytes still hold the last tracked
        // position in this frame, so ignore them and emit one synthetic exit
        // rather than a final point at a stale location.
        guard (status & 0x80) != 0 else {
            // The barrel gate survives this on purpose: in the bezel the
            // tablet sends one-frame exits of its own, and disarming on them
            // let the next barrel sample through.
            guard state.prevInProximity else { return results }
            state.prevInProximity = false
            // Force re-latch on the next approach — the announcement frame
            // may belong to a different pen next time, and there's no other
            // signal that says so.
            state.lastSerial = 0
            state.lastToolCode = 0
            // The held rotation belongs to the pen that left; replayed onto
            // the next pen's filler frames, it passed that pen off as a
            // twisted Art Pen.
            state.lastRotation = 0.0
            state.hasValidRotationFrame = false
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

        let x = report.le24(at: 4) & 0xFFFFF
        let y = Int(report[6] >> 4) | Int(report[7]) << 4 | Int(report[8]) << 12
        // Both fields are wide enough to express values the sensor never
        // reaches, so an out-of-range reading means a frame that isn't a
        // position at all. Drop it rather than clamping it to an edge: a
        // clamp would park the cursor at a border it was never near.
        guard x <= spec.maxX, y <= spec.maxY else { return results }

        // Off the drawable surface: the pen is in the groove or over the
        // bezel, and should produce nothing.
        //
        // Unlike the barrel leaps below, groove motion is smooth, so the
        // continuity gate passes it. Position can't tell either: the groove
        // reports positions folded about 850 units inside the limit, further
        // in than a pen tracing the real border. The status byte can. The
        // border trace carries a close tip fix (bit 6) in 99.8% of samples,
        // the grooves in 0–4%. Bit 6 also clears in ordinary high hover, so
        // it's paired with the rim, where the fold-back lands.
        //
        // The barrel gate arms here too: the rim is where barrel takeover
        // starts, and the samples that follow the pen out of the groove need
        // it awake.
        if (status & 0x40) == 0,
            Self.distanceToNearestEdge(x: x, y: y, spec: spec) <= Self.rimBand
        {
            state.bleOutsideSurface = true
            state.bleBarrelDropCount = 0
            return results
        }

        // Barrel-takeover gate.
        //
        // Once the tip passes the edge of the sensing surface, the position
        // comes from the pen's barrel, and the cursor snaps inward to it.
        // Each jump points along the reported tilt, on a Pro Pen 3 too, so
        // it isn't the eraser or a decode error.
        //
        // No single frame separates this from high hover or edge tracing;
        // continuity does. A genuine re-entry moves at most 254 units in a
        // frame, every barrel jump at least 2648.
        //
        // So entering the border band arms the gate. While armed, a
        // discontinuous sample is the barrel and drops; a continuous one back
        // inside the band's inner edge is the tip and disarms it. Samples on a
        // limit get the check too, or the ghost slides along the boundary.
        // The gate survives a proximity exit (see above) and bounds its own
        // rejections, since a rejected sample doesn't move the reference.
        //
        // Known limit: on a full-width top-edge see-saw, jumps over 1500
        // units drop from 125 to 3, not to zero. Arming on status 0x80 near a
        // border was tried, and it broke edge tracing.
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

        let pressure = report.le16(at: 9)
        let tiltDivisor = spec.tiltMaxDegrees ?? 64.0
        let tiltX = Double(Int8(bitPattern: report[11])) / tiltDivisor
        let tiltY = Double(Int8(bitPattern: report[12])) / tiltDivisor

        // Art Pen barrel rotation: -900..899, 5 counts per degree, as on USB,
        // but 12 bits in [13..14], with [14]'s high nibble a frame counter.
        // Sign-extend from bit 11. Tracks labeled poses within 2°.
        //
        // Not gated on tool identity: the BLE announcement often never
        // arrives in a session. Ungated is safe, since pens without a
        // rotation sensor hold raw 0 here.
        //
        // Raw 0 is the "no reading" filler, as on USB, so frames without a
        // count replay the last real reading.
        let packed = UInt16(report.le16(at: 13) & 0x0FFF)
        let rawRotation = Int16(bitPattern: packed << 4) >> 4
        var rotation: Double
        if rawRotation != 0 {
            rotation = (900.0 - Double(rawRotation)) / 5.0
            if rotation < 0 { rotation += 360.0 }
            if rotation >= 360 { rotation -= 360.0 }
            state.lastRotation = rotation
            state.hasValidRotationFrame = true
        } else if state.hasValidRotationFrame {
            rotation = state.lastRotation
        } else {
            rotation = 0.0
        }

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
            // 0x10 Eraser (pressed) or 0x20 Invert (eraser end in range), the
            // same layout as the kernel's Pro2022 report: Eraser alone made
            // the eraser exist only in contact over Bluetooth.
            eraser: (status & 0x30) != 0,
            inProximity: true, hoverDistance: 0)
        // Same third barrel button as the USB extended report — see the
        // comment on decodeExtendedPenReport's equivalent assignment.
        blePoint.penButton3 = (status & 0x08) != 0
        results.append(.pen(blePoint))
        return results
    }

    // MARK: - 0x06 standard USB HID Digitizer report (CTC-4110WL / Wacom One S)

    /// The CTC-4110WL (Wacom One S, `0x0531:0x0100`) sends its standard HID
    /// Digitizer input here when DATAMODE doesn't take. The layout comes
    /// from its descriptor and two captures. It matches `0x1F` except that
    /// tilt is a signed LE16 and there's no hover field:
    ///   [0]      = 0x06  report ID
    ///   [1]      constant `0x01`, not decoded
    ///   [2]      status: bit0 tip, bit1 barrel, bits 2–3 padding, bit4
    ///            eraser pressed, bit5 invert (eraser end in range), bit6 in
    ///            range. bit5 is read as the eraser, so it counts in range.
    ///            The descriptor declares no second barrel button, so none is
    ///            decoded; `debugBit` lets a reporter probe for one.
    ///   [3..4]   X, LE u16
    ///   [5..6]   Y, LE u16
    ///   [7..8]   pressure, LE u16
    ///   [9..10]  X tilt, signed LE16, logical ±9000; divided by
    ///            `spec.tiltMaxDegrees` if set, else that logical maximum
    ///   [11..12] Y tilt, the same
    ///   [13..17] vendor and undocumented fields, not decoded
    ///
    /// With no hover field, `hoverDistance` is 0.
    private func decodeStandardDigitizerReport(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        let status = report[2]
        let inRange = (status & 0x40) != 0

        if !inRange {
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

        let x = report.le16(at: 3)
        let y = report.le16(at: 5)
        let pressure = report.le16(at: 7)
        let tiltDivisor = spec.tiltMaxDegrees ?? 9000.0
        let rawTiltX = report.signedLE16(at: 9)
        let rawTiltY = report.signedLE16(at: 11)
        let tiltX = Double(rawTiltX) / tiltDivisor
        let tiltY = Double(rawTiltY) / tiltDivisor

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
                    // No second barrel-switch usage exists in this report's
                    // descriptor — see the doc comment above. Left false
                    // unless a diagnostic override names a specific bit to
                    // try instead (see `DigitizerSpec.debugButton2Source`).
                    penButton2: Self.debugBit(
                        spec.debugButton2Source, report: report),
                    eraser: (status & 0x20) != 0,
                    inProximity: true,
                    hoverDistance: 0))
        ]
    }

    /// Reads `source`'s bit from `report`, or `false` if `source` is `nil` or
    /// its `byteIndex` falls outside `report`'s actual length this frame —
    /// never traps on an out-of-range diagnostic pick.
    static func debugBit(
        _ source: DigitizerSpec.DebugBitSource?, report: HIDReport
    ) -> Bool {
        guard let source, source.byteIndex >= 0, source.byteIndex < report.count,
            source.bitIndex >= 0, source.bitIndex < 8
        else { return false }
        return (report[source.byteIndex] & (1 << source.bitIndex)) != 0
    }
}

extension IntuosV3Decoder {
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
        /// Whether a Bluetooth sample has reached the surface's edge, so a jump that follows is the barrel, not the tip.
        package var bleOutsideSurface: Bool = false
        /// Consecutive samples the barrel gate has dropped.
        package var bleBarrelDropCount: Int = 0
        /// ExpressKey byte from the last pad report, for telling a press from a hold.
        package var lastExpressKeys: UInt8 = 0

        package init() {}
    }
}
