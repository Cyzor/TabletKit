// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

/// Fields of the 10-byte Intuos pen packet (kernel `wacom_intuos_general`),
/// which `IntuosV1Decoder`, `Intuos3Decoder`, and `CintiqV1Decoder` share.
/// Each decoder keeps its own proximity and state rules; these only read
/// the bytes.
enum IntuosPenPacket {

    /// Serial and tool code from a tool-change packet (status bits 7:2 == 0xC0).
    static func toolChange(_ report: HIDReport) -> (serial: UInt32, toolCode: UInt16) {
        let serial: UInt32 =
            UInt32(report[3] & 0x0F) << 28
            | UInt32(report[4]) << 20
            | UInt32(report[5]) << 12
            | UInt32(report[6]) << 4
            | UInt32(report[7]) >> 4
        let toolCode: UInt16 =
            UInt16(report[2]) << 4
            | UInt16(report[3]) >> 4
            | UInt16(report[7] & 0x0F) << 12
            | UInt16(report[8] & 0xF0) << 4
        return (serial, toolCode)
    }

    /// Position: 16-bit big-endian, extended by one low bit from byte 9.
    static func position(_ report: HIDReport) -> (x: Int, y: Int) {
        let x: Int = (report.be16(at: 2) << 1) | ((Int(report[9]) >> 1) & 1)
        let y: Int = (report.be16(at: 4) << 1) | (Int(report[9]) & 1)
        return (x, y)
    }

    /// Tilt: 7 bits per axis biased by 64, scaled so ±63 reads as ±1.
    static func tilt(_ report: HIDReport) -> (x: Double, y: Double) {
        let x: Int = (((Int(report[7]) << 1) & 0x7E) | (Int(report[8]) >> 7)) - 64
        let y: Int = (Int(report[8]) & 0x7F) - 64
        return (Double(x) / 63.0, Double(y) / 63.0)
    }

    /// Pressure: 11 bits from bytes 6 and 7, with status bit 0 as the lowest
    /// bit when `statusBit` is set. On 10-bit hardware (`maxPressure` ≤ 1023)
    /// the 11-bit form reads twice too high, so this halves it.
    static func pressure(_ report: HIDReport, maxPressure: Int, statusBit: Bool) -> Int {
        let low = statusBit ? Int(report[1]) & 1 : 0
        let raw = (Int(report[6]) << 3) | ((Int(report[7]) & 0xC0) >> 5) | low
        return maxPressure <= 1023 ? raw >> 1 : raw
    }

    /// A mouse packet as a point: subtype 0x06 (KC-100 cordless mouse,
    /// Intuos3 cursor) or 0x08 (2D cursor, 4D mouse). Nil for any other
    /// subtype.
    static func mousePoint(
        _ report: HIDReport, subtype: UInt8, x: Int, y: Int, spec: DigitizerSpec
    ) -> TabletPoint? {
        let primary: Bool, secondary: Bool, middle: Bool, wheelDelta: Int
        switch subtype {
        case 0x06:
            let buttons = report[6]
            let wheel = report[7]
            primary = (buttons & 0x01) != 0
            secondary = (buttons & 0x04) != 0
            middle = (buttons & 0x02) != 0
            wheelDelta = Int((wheel & 0x80) >> 7) - Int((wheel & 0x40) >> 6)
        case 0x08:
            let buttons = report[8]
            primary = (buttons & 0x04) != 0
            secondary = (buttons & 0x10) != 0
            middle = (buttons & 0x08) != 0
            wheelDelta = Int(buttons & 0x01) - Int((buttons & 0x02) >> 1)
        default:
            return nil
        }
        return TabletPoint(
            x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
            pressure: 0, maxPressure: spec.maxPressure,
            tiltX: 0, tiltY: 0, rotation: 0.0,
            penButton1: primary, penButton2: secondary,
            eraser: false, inProximity: true, hoverDistance: 0,
            mouseMiddleButton: middle, mouseWheelDelta: wheelDelta)
    }
}
