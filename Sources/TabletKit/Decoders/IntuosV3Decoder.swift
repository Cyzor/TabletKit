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

    /// True raw ceiling of the BLE report's real 24-bit Y field (bytes
    /// [6..8] — see `decodeBLEReport`'s doc comment for the byte-mapping
    /// history). Measured 2026-09-17 from a single continuous top-to-bottom
    /// stroke (`ptk-870-top-to-bottom.txt`) after confirming the field
    /// neither wraps nor saturates within that stroke. Not a bit-width
    /// constant (624000 is not 2^n − 1) — an empirically measured hardware
    /// property of the PTK-870's BLE report, expected to hold for the
    /// PTK-470/670 siblings too but not yet confirmed on those specific
    /// models.
    private static let bleRawYCeiling = 624000.0

    /// True raw ceiling of the BLE report's X field (bytes [4..5], read as a
    /// plain LE16 — see `decodeBLEReport`'s doc comment). Unlike Y, X has NO
    /// missing high byte: a systematic search across 10 confirmed wrap
    /// events in every capture on hand (2026-09-18) found no companion byte
    /// anywhere in the report that increments at the wrap, and X's raw
    /// value climbs cleanly to 65535 without an early saturation plateau —
    /// so X is genuinely only a 16-bit field on this transport. The bug was
    /// elsewhere: `spec.maxX` (69800) is the USB descriptor's logical
    /// maximum, which BLE's real range doesn't reach — the opposite
    /// mismatch from Y's (Y's true BLE range was LARGER than its USB spec
    /// value; X's is SMALLER). Reading X as `min(x, spec.maxX)` therefore
    /// let a wrapped-low value stand as if it were a real position near the
    /// left edge instead of the true right edge, and let a value just under
    /// the wrap point stand uncorrected instead of being recognized as
    /// approaching this ceiling — both contributed to the reported
    /// "frozen near a fixed value" and "wraps like Pac-Man" symptoms.
    private static let bleRawXCeiling = 65535.0

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
            return decodeBLEReport(report: report, length: length, spec: spec, state: &state)
        default:
            return []
        }
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
    ///   [19]      hover distance
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
            tiltX: tiltX, tiltY: tiltY, rotation: 0.0,
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
    /// Without it the tablet emits report 0x06 instead (an inert, mostly-
    /// zero idle report — not handled here, since MockTab now always
    /// triggers data mode on connect).
    ///
    /// Layout confirmed 2026-09-17 against real PTK-870 BLE captures (raw
    /// sequential HID logs via `tools/capture/hid_input_capture.c` — the
    /// discovery-mode aggregate byteStats tool cannot reveal LE16 pairing or
    /// monotonic ordering, only per-byte marginal min/max/distinct):
    ///   [0]     = 0x1A  report ID
    ///   [1]     packet-class + slot discriminator (see below)
    ///   [4..5]  X coordinate, LE u16 — confirmed monotonic across a
    ///           corner-to-corner horizontal sweep, flat during a vertical
    ///           sweep
    ///   [6]     tilt X, signed byte — confirmed via four held-static
    ///           single-direction poses (left/right/up/down): sign flips
    ///           between opposite directions, magnitude changes, perfectly
    ///           constant when the angle itself is held fixed
    ///   [7]     tilt Y, signed byte — same confirmation, opposite axis
    ///   [6..8]  Y coordinate, 24-bit LE (byte [6] low, [7] mid, [8]
    ///           high) — three prior byte-mapping attempts for Y were each
    ///           wrong; this is the one confirmed correct, after the
    ///           mistake pattern from `[[project_xencelabs...]]`'s
    ///           cursor-tracking bug repeated itself here almost exactly
    ///           (see the postmortem quoted below).
    ///
    ///           Attempt 1 shipped `[9] low / [8] high` (chosen assuming Y
    ///           mirrors X's byte order but reversed) — produced a Y axis
    ///           frozen near one value on real hardware.
    ///
    ///           Attempt 2 kept that byte pair but added a scale factor
    ///           derived from a measured raw ceiling of 2473 (from a
    ///           dedicated full-height, five-pen sweep) — produced Y
    ///           confined to a coarse, ~10-step grid near the top of the
    ///           tablet. This looked well-supported (clean monotonic climb
    ///           in the sweep data, cross-validated across five pens,
    ///           density ratios that seemed internally consistent) but was
    ///           still wrong, in the same way three different empirically
    ///           "confirmed by a sweep" scale factors were each wrong in
    ///           turn for Xencelabs's cursor bug — see
    ///           `TabletKit/Sources/TabletKit/Decoders/XencelabsDecoder.swift`'s
    ///           header and `VendorDeviceRegistry.swift`'s Xencelabs Pen
    ///           Display comment for that history. In both cases, a field
    ///           that merely correlated with true position over a long
    ///           sweep (because it moved in roughly the right direction on
    ///           average) was mistaken for the real, precise field —
    ///           because the review that "confirmed" it used a strided or
    ///           coarse-grained sample of the sweep, which averages out a
    ///           wrong field's coarseness and hides a right field's fine
    ///           detail. Bytes [8..9] (attempt 1/2's field) DO trend
    ///           upward over a full sweep, which is exactly why every
    ///           check up to that point passed.
    ///
    ///           Found live 2026-09-17, third round, only after printing
    ///           every single consecutive raw sample in a short window
    ///           (not a stride) from `ptk-870-top-to-bottom.txt`: bytes
    ///           [6..7] read as LE16 climb with the SAME fine,
    ///           single-unit granularity as X's low byte — the real
    ///           precise field. Bytes [8..9] (the old guess) update only
    ///           in coarse steps of 4 and far less often — a real but
    ///           separate, lower-resolution field, still unidentified.
    ///           [6..7] alone still wraps at 16 bits during a genuine
    ///           full-height sweep (confirmed via
    ///           `ptk-tilt-multiple-pens-top-to-bottom.txt`, which shows 9
    ///           clean wraps, one per pen stroke, each a smooth
    ///           continuation past 65535 back to a low value at a steady
    ///           per-step rate — not a stroke break or glitch). Byte [8]
    ///           increments by exactly 1 at every one of those 9 wraps and
    ///           nowhere else, confirming it as the true third byte —
    ///           `y = report[6] | report[7]<<8 | report[8]<<16`, a true
    ///           24-bit field, the same width pattern (missing high byte)
    ///           as the Xencelabs bug's actual root cause. Measured true
    ///           ceiling for a single continuous top-to-bottom stroke:
    ///           `624000` (`ptk-870-top-to-bottom.txt`). This does NOT
    ///           match `spec.maxY` (39000, the USB-side calibration) in
    ///           either scale or magnitude — BLE's Y units are genuinely
    ///           different from USB's, so this raw 24-bit value is scaled
    ///           to `spec.maxY` the same way the old (wrong) code did,
    ///           just now against the right raw field and a value that
    ///           has actually been checked for wraparound.
    ///
    ///           X (bytes [4..5]) was re-examined for the same class of
    ///           bug given this history. Round 1 (2 wrap events) found no
    ///           companion high byte and left X as a 16-bit read with the
    ///           gap noted. Round 2 (2026-09-18, 10 confirmed wrap events
    ///           across every capture on hand, triggered by tracing a
    ///           reported "cursor freezes/teleports near the right edge,
    ///           tilt-sensitive" symptom back to its source) confirmed the
    ///           negative result with much more data — no byte anywhere in
    ///           the report increments consistently at the wrap — but also
    ///           found X's raw value climbs cleanly to 65535 with no early
    ///           saturation, unlike a field secretly missing a high byte.
    ///           **X genuinely has no third byte; the bug was `spec.maxX`
    ///           itself.** `69800` is the USB descriptor's logical maximum,
    ///           which BLE's raw 16-bit X never reaches — the opposite
    ///           mismatch from Y's (Y's true BLE range was LARGER than its
    ///           USB spec value). Clamping raw X against `spec.maxX`
    ///           (69800) let a value approaching the true 65535 ceiling
    ///           read as merely "large, not yet at the edge," and let the
    ///           wrapped-low value after 65535→0 read as a real position
    ///           near the opposite edge instead of the true right edge —
    ///           this explains both the "frozen near a small fixed value"
    ///           finding (the exact value observed, 4264, is `69800−65536`
    ///           to the unit — not a coincidence) and the "cursor wraps
    ///           Pac-Man-style" symptom. Fixed by scaling raw X against the
    ///           measured true ceiling `bleRawXCeiling` (65535) up to
    ///           `spec.maxX`, the same pattern as Y's fix, just with the
    ///           correction running in the opposite direction (BLE's true
    ///           range is smaller than spec here, not larger).
    ///   [10]    pressure, single byte — confirmed via a dedicated
    ///           press-harder capture showing a clean ramp-and-saturate
    ///           curve (two press cycles, both topping out at the same
    ///           value). Ceiling observed on the pens tested this session
    ///           was ~31 (0x1F), far below `spec.maxPressure` (8191) — this
    ///           is very likely the physical range of those specific,
    ///           older pens rather than a report-format truncation (the
    ///           curve saturates and holds flat under sustained force
    ///           rather than wrapping/glitching, which is what a truncated
    ///           high byte would look like). Scaled against
    ///           `spec.maxPressure` as-is; a pen with a wider true range
    ///           will simply report higher byte values, the same as any
    ///           other 8-bit-vs-wider pressure field elsewhere in this
    ///           decoder set.
    ///   [18]    buttons — one-hot, bits 0-3 = left ExpressKeys (4 keys),
    ///           bits 4-7 = right ExpressKeys (4 keys). Confirmed via
    ///           isolated left-only and right-only key-press captures.
    ///   [19]    dial + cluster-active flags — bit0 = left-key-cluster
    ///           active, bit1 = right-key-cluster active, bit2 = left dial
    ///           active, bit3 = left dial rotating CCW (clear = CW), bit4 =
    ///           right dial active, bit5 = right dial rotating CCW (clear =
    ///           CW). Confirmed via isolated left-dial/right-dial/CW/CCW
    ///           captures — no bit overlap with the button bits. NOT
    ///           confirmed: per-frame step magnitude. The one raw sequential
    ///           dial capture on hand shows the active bit held across many
    ///           consecutive reports at a steady ~10 Hz for the whole
    ///           rotation gesture, not one report per physical detent —
    ///           emitting `delta: ±1` on every such frame below is a
    ///           placeholder that will over-report rotation speed if that
    ///           reading is right. A capture of a single, deliberate,
    ///           one-detent dial click (versus a multi-second continuous
    ///           spin) is needed to confirm whether this field ticks once
    ///           per detent or free-runs while held.
    ///
    /// NOT YET CONFIRMED, deliberately not decoded here rather than guessed:
    /// pen barrel buttons, eraser, and tip/touch switch state for this
    /// report — no capture isolated these bits. `inProximity` is inferred
    /// from whether a live (non-idle, non-template) discriminator arrived,
    /// not from an explicit proximity bit. Tool serial/tool-code
    /// (`.toolEnter`) are also not emitted here: the legacy Intuos
    /// enter-class discriminator (`(byte[1] & 0xfc) == 0xc0`) that would
    /// carry them was never observed in ~18,000 samples across every
    /// capture taken this session, including deliberate approach/withdraw
    /// tests — see `Notes/Scratch/` PTK-870 BLE research notes. Bytes 2-3
    /// and 11-17 are also unassigned; several showed mild, unexplained
    /// drift in some captures but nothing triangulated to a specific
    /// control.
    ///
    /// Discriminator byte [1] follows Wacom's legacy Intuos proximity
    /// state-machine bit convention (`wacom_intuos_inout()` in the Linux
    /// `input-wacom` driver): high bits are a packet-class field, the low
    /// bit is a slot index. Every discriminator value actually observed
    /// this session decomposes cleanly: `0x02` = idle, `0x21`/`0x22` =
    /// in-range (class 0x20, slot 1/0), `0x41`/`0x42` = in-range/reporting
    /// (class 0x40, slot 1/0). A handful of `0xC1`/`0xC2` (enter-class)
    /// samples appeared in early discovery-mode captures but never in
    /// enough volume to be usable, and the exit class
    /// (`(byte[1] & 0xfe) == 0x80`) was never observed at all. Frames whose
    /// class is `0x40` with a byte[3]/[4..9] payload that is bit-for-bit
    /// IDENTICAL every time (a fixed template — `c0 81 90 80 24 04 08`
    /// observed in both sweep captures) are a sync/keepalive marker, not
    /// live pen data — filtered out here by requiring the frame to differ
    /// from that exact template before treating [4..10] as position data.
    private func decodeBLEReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState
    ) -> [DecodeResult] {
        let discriminator = report[1]
        let packetClass = discriminator & 0xfc

        // Fixed sync/keepalive template — not live pen data. Bytes [3..9]
        // match exactly across every occurrence observed in captured data.
        let isTemplateFrame =
            report[3] == 192 && report[4] == 129 && report[5] == 144
            && report[6] == 128 && report[7] == 36 && report[8] == 4
            && report[9] == 8

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

        // packetClass 0x00 (discriminator 0x02) is NOT a pure idle state —
        // found live 2026-09-17, third round: a dedicated hover-only sweep
        // (pen moved across the tablet without ever touching down,
        // `ptk-870-tilt-hover-left-to-right.txt`) showed clean, live,
        // monotonic X motion exclusively under discriminator 0x02 — the
        // discriminator this decoder had been treating as "no pen, discard"
        // ever since the original byte-mapping investigation. That
        // investigation never captured a hover-only sweep, so this was
        // never actually tested until now.
        //
        // The real distinguishing signal is X/Y both being exactly zero, a
        // genuine placeholder confirmed in a capture with no pen anywhere
        // near the tablet at all (only ExpressKeys and the dial were
        // exercised): every 0x02 frame there reported X=0, Y=0, never
        // anything else. A hovering pen's 0x02 frames never do — X/Y move
        // continuously and never happen to land on exactly (0, 0) mid-sweep
        // in the capture on hand. Filtering on "both zero" rather than on
        // packetClass alone lets real hover position through while still
        // suppressing the true no-pen-present case.
        //
        // Found live 2026-09-17, fourth round — the above guard was still
        // too narrow: live captures reproducing a "cursor teleports near
        // the tablet's edges/bezel" report (`bt-sample-01.txt`,
        // `bt-sample-02.txt`) show discriminator 0x02 frames where ONLY Y's
        // three bytes collapse to exactly zero while X keeps reporting a
        // real, live, moving value — the pen genuinely still in range, just
        // with Y degenerating independently of X. The old all-zero-only
        // check let these through as real points, producing a cursor that
        // snapped between the true position and a fixed "Y=0, real X"
        // ghost. A real hovering/in-range Y essentially never rests at
        // exactly zero continuously the way this degenerate state does, so
        // reject on Y-alone being zero too, not just X-and-Y together.
        // Discriminator 0x01 — also observed in these same captures as a
        // fixed, byte-for-byte identical phantom point recurring several
        // times (X=17244, Y=9752) — isn't part of the confirmed
        // 0x02/0x21/0x22/0x41/0x42 state set and is excluded outright rather
        // than trusted to the zero-Y heuristic, since a future phantom value
        // might not happen to zero out.
        let looksLikeDegenerateY =
            packetClass == 0x00 && report[6] == 0 && report[7] == 0 && report[8] == 0
        guard discriminator != 0x01, !looksLikeDegenerateY, !isTemplateFrame else {
            return results
        }

        // X's raw units are a different scale from spec.maxX on this
        // report — see `bleRawXCeiling`'s doc comment above. Scale the
        // measured true raw ceiling (65535, X's real 16-bit range) up to
        // spec.maxX so downstream code can treat this the same as every
        // other decoder's X, mirroring Y's own raw-ceiling scale below.
        let wireRawX = Int(UInt16(report[4]) | UInt16(report[5]) << 8)
        var rawX = wireRawX
        // X has no companion high byte (confirmed — see the doc comment
        // above), so a real stroke that crosses the raw 65535 boundary
        // while still physically on the tablet wraps to a small value with
        // no bit left to reconstruct the true position from. Detect the
        // wrap directly: a large negative jump in the raw WIRE value
        // (`wireRawX`, always the report's own literal bytes, never the
        // corrected value) while the previous wire value was already near
        // the ceiling means the pen is still at (or just past) the true
        // physical edge, not that it teleported to the opposite side — pin
        // the reported position at the ceiling instead of trusting the
        // wrapped-low reading. This is the decoder-level fix for the
        // reported "cursor wraps Pac-Man-style at the right edge" symptom;
        // without it, a genuine edge-crossing stroke still produces a
        // single-frame ~spec.maxX-sized jump even after the ceiling
        // correction above, since rescaling a wrapped value doesn't unwrap
        // it.
        //
        // Deliberately compares against `state.bleLastWireRawX` (the raw
        // wire value, updated unconditionally below) rather than feeding
        // the CORRECTED value back into its own detection — comparing
        // against a value already pinned at the ceiling would make every
        // subsequent wrapped-low report look like "another wrap from
        // near-ceiling" and pin forever, with no way to un-pin once the
        // pen genuinely returns to the mapped area.
        //
        // `blePastXWrap` makes this a small state machine rather than a
        // single-frame check: once a wrap is detected, EVERY subsequent
        // report stays pinned at the ceiling (regardless of how the
        // wrapped-low wire value continues to evolve — a real capture
        // shows it keeps climbing smoothly in wrapped-low space, e.g.
        // 10→24→38→...→2288, which would otherwise read as real motion
        // back toward the tablet's center) until the wire value itself
        // climbs back up near the ceiling again, which un-pins and resumes
        // trusting it directly.
        if state.blePastXWrap {
            if wireRawX > Int(Self.bleRawXCeiling) - 5000 {
                state.blePastXWrap = false
            } else {
                rawX = Int(Self.bleRawXCeiling)
            }
        } else if let lastWireRawX = state.bleLastWireRawX,
            lastWireRawX > Int(Self.bleRawXCeiling) - 5000, wireRawX < lastWireRawX - 30000
        {
            state.blePastXWrap = true
            rawX = Int(Self.bleRawXCeiling)
        }
        state.bleLastWireRawX = wireRawX
        let x = min(Int((Double(rawX) * Double(spec.maxX) / Self.bleRawXCeiling).rounded()), spec.maxX)
        // Y is a true 24-bit field: [6] low, [7] mid, [8] high. See the
        // doc comment above for the byte-mapping history — bytes [8..9]
        // were tried twice and were both wrong.
        let rawY = Int(report[6]) | (Int(report[7]) << 8) | (Int(report[8]) << 16)
        // Y's raw units are a different scale from X's on this report —
        // see the doc comment above. Scale the measured true raw ceiling
        // (624000, from one continuous full-height stroke) up to spec.maxY
        // so downstream code can treat this the same as every other
        // decoder's Y.
        let y = min(Int((Double(rawY) * Double(spec.maxY) / Self.bleRawYCeiling).rounded()), spec.maxY)
        let pressure = Int(report[10])

        state.prevInProximity = true
        state.lastX = x
        state.lastY = y

        // Tilt is not decoded here. Bytes [6..7], previously reported as
        // tiltX/tiltY, were found 2026-09-17 to actually be the low/mid
        // bytes of the real Y field (see the doc comment above) — the
        // original "sign flips between opposite directions" finding that
        // seemed to confirm them as tilt was a coincidence of the four
        // held-static tilt-pose captures each being performed at a
        // different, uncontrolled Y position on the tablet, not a real
        // tilt signal. Tilt's real bytes are unidentified; per priority
        // (coordinates, then barrel buttons, then pressure, then tilt),
        // this is deliberately left at 0.0 rather than guessed.
        results.append(
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: 0.0, tiltY: 0.0, rotation: 0.0,
                    penButton1: false, penButton2: false,
                    eraser: false, inProximity: true, hoverDistance: 0)))
        return results
    }
}
