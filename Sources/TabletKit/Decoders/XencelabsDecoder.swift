// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Xencelabs Pen Tablet / Pen Display HID report format.
///
/// Used by: Pen Tablet Medium (VID 0x28BD, PID 0x5201), Pen Tablet Small
/// (PID 0x5204), and Pen Display (PID 0x520D). The pen-report bit layout
/// below is **confirmed** from a live HID report descriptor captured off a
/// real Pen Display 2026-07-01 (Report ID 7, usage page 0x0D). The original
/// byte-aligned layout ported from OpenTabletDriver was wrong for this
/// hardware — the descriptor packs six 1-bit flags before X begins, so X
/// starts at bit offset 6, not byte offset 2. Pen Tablet Medium/Small remain
/// unconfirmed but are assumed to share this bit-packed layout (same vendor
/// firmware family) until proven otherwise.
///
/// Requires a tablet-mode init first: output report `[0x02, 0xB0, 0x04]`
/// (`InitStep.outputReport`); without it the device stays in mouse-emulation
/// mode and these reports never arrive.
///
/// This device also streams a second, concurrent, high-frequency report
/// (ID 2, 32 bytes, vendor-defined usage page) whose layout is not yet
/// decoded. `decode` only handles Report ID 7 — anything else is ignored
/// rather than guessed at, since misreading report 2 as pen data previously
/// produced chaotic, unsteerable cursor motion.
///
/// Report 7 field layout (bit offsets counted from the first bit after the
/// report ID byte, LSB-first, matching HID bit-packing order):
///   bit 0  = tip switch     bit 1 = barrel button 1 (usage 0x44)
///   bit 2  = eraser active  bit 3 = usage 0x46 (tablet pick / barrel 2)
///   bit 4  = invert         bit 5 = in range
///   bits 6–21  = X (16-bit)         bits 22–37 = Y (16-bit)
///   bits 38–53 = pressure (16-bit)  bits 54–61 = tilt X (signed 8-bit)
///   bits 62–69 = tilt Y (signed 8-bit)
public struct XencelabsDecoder: TabletReportDecoder {

    /// The only report ID this decoder currently understands. Confirmed on
    /// Pen Display; assumed for Pen Tablet Medium/Small pending hardware
    /// validation.
    static let penReportID: UInt8 = 0x07

    public init() {}

    /// Read `bitCount` bits starting at `bitOffset` from `bytes`, LSB-first
    /// within each byte — matches HID report bit-packing. `bytes` should
    /// start at the first data byte *after* the report ID.
    private static func extractBits(_ bytes: UnsafePointer<UInt8>, length: CFIndex, bitOffset: Int, bitCount: Int) -> UInt32 {
        var result: UInt32 = 0
        for i in 0..<bitCount {
            let bitPos = bitOffset + i
            let byteIdx = bitPos / 8
            guard byteIdx < length else { break }
            let bit = (bytes[byteIdx] >> (bitPos % 8)) & 1
            result |= UInt32(bit) << i
        }
        return result
    }

    /// Tilt bytes are assumed to be degrees (±60°, the spec'd max for this pen
    /// family) rather than the ±127 sin-proportional encoding Wacom BLE uses.
    /// Unverified on hardware; if live tilt saturates early or never reaches
    /// full deflection, revisit this constant first.
    static let tiltScaleDegrees = 60.0

    public mutating func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        // Full report is 10 bytes (report ID + 9 data bytes covering all
        // fields through tilt Y); anything shorter is truncated and dropped.
        guard length >= 10, report[0] == Self.penReportID else { return [] }

        // Data bytes start after the report ID; bit offsets below are counted
        // from here, per the confirmed descriptor field order.
        let data = report + 1
        let dataLength = length - 1

        let barrel1 = Self.extractBits(data, length: dataLength, bitOffset: 1, bitCount: 1) != 0
        let isEraser = Self.extractBits(data, length: dataLength, bitOffset: 2, bitCount: 1) != 0
        let barrel2 = Self.extractBits(data, length: dataLength, bitOffset: 3, bitCount: 1) != 0
        let inRange = Self.extractBits(data, length: dataLength, bitOffset: 5, bitCount: 1) != 0

        // ── Out of range ──────────────────────────────────────────────────────
        if !inRange {
            guard state.prevInProximity else { return [] }
            state.prevInProximity = false
            let exitEraser = state.isEraser
            state.isEraser = false
            return [
                .pen(
                    TabletPoint(
                        x: state.lastX, y: state.lastY,
                        maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: false, penButton2: false,
                        eraser: exitEraser, inProximity: false, hoverDistance: 0))
            ]
        }

        var results: [DecodeResult] = []
        // toolEnter on rising edge or tip/eraser flip.  No serials on this
        // hardware; synthetic tool codes follow the GraphireDecoder convention
        // (0x080A eraser / 0x0802 pen) so per-tool settings keep working.
        if !state.prevInProximity || isEraser != state.isEraser {
            state.prevInProximity = true
            state.isEraser = isEraser
            results.append(
                .toolEnter(
                    ToolIdentity(
                        serial: 0,
                        toolCode: isEraser ? 0x080A : 0x0802,
                        isEraser: isEraser,
                        isMouse: false)))
        }

        let x = Int(Self.extractBits(data, length: dataLength, bitOffset: 6, bitCount: 16))
        let y = Int(Self.extractBits(data, length: dataLength, bitOffset: 22, bitCount: 16))
        let pressure = Int(Self.extractBits(data, length: dataLength, bitOffset: 38, bitCount: 16))
        state.lastX = x
        state.lastY = y

        let tiltXRaw = Int8(bitPattern: UInt8(Self.extractBits(data, length: dataLength, bitOffset: 54, bitCount: 8)))
        let tiltYRaw = Int8(bitPattern: UInt8(Self.extractBits(data, length: dataLength, bitOffset: 62, bitCount: 8)))
        let tiltX = Double(tiltXRaw) / Self.tiltScaleDegrees
        let tiltY = Double(tiltYRaw) / Self.tiltScaleDegrees

        results.append(
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: min(pressure, spec.maxPressure),
                    maxPressure: spec.maxPressure,
                    tiltX: max(-1.0, min(1.0, tiltX)),
                    tiltY: max(-1.0, min(1.0, tiltY)),
                    rotation: 0.0,
                    penButton1: barrel1,
                    penButton2: barrel2,
                    eraser: isEraser,
                    inProximity: true,
                    hoverDistance: 0)))
        return results
    }
}
