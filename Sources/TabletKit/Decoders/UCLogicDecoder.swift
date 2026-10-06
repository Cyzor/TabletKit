// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the pen reports of UC-Logic tablets: Huion, Gaomon, XP-Pen,
/// UGEE, and Parblo.
///
/// Two protocols share this decoder, and their pen reports arrive on
/// different report IDs, so one decoder reads both without being told
/// which it has:
///
/// | Field | Huion v2, report `0x08` | UGEE v2, report `0x02` |
/// |---|---|---|
/// | X | bytes 2–3, third byte at 8 | bytes 2–3, third byte at 10 on wide tablets |
/// | Y | bytes 4–5, third byte at 9 | bytes 4–5 |
/// | Pressure | bytes 6–7 | bytes 6–7, 13 bits |
/// | Tilt X, Y | bytes 10, 11, Y reversed | bytes 8, 9 |
/// | In range | never reported | byte 1, bit 5 |
///
/// In byte 1 of both, bit 0 is the tip and bits 1 and 2 are the barrel
/// buttons. UGEE v2 tablets also use bit 3 for a third button and bit 6 for
/// the eraser; a Xencelabs capture showed both, and the kernel ignores them.
/// Values with bit 4 set are the tablet's own buttons and battery, not pen
/// data. Tilt is a signed byte in degrees, −60 to 60. Layouts are from
/// the Linux kernel's `hid-uclogic` driver.
///
/// Huion v2 tablets never say the pen left; they stop sending. After a Huion
/// report, ``silenceTimeout`` becomes 100 ms, the same as the kernel uses,
/// and ``decodeSilence(spec:state:deviceFamily:)``
/// reports the pen leaving.
///
/// These pens send no serial or tool code, so every pen is announced as
/// ``WacomToolCatalog``'s shared code `0xE902`.
///
/// The tablet's own buttons arrive as a bitmap, lowest bit first: in bytes
/// 4–5 of a Huion report whose byte 1 is `0xE0`, and in bytes 2–3 of a UGEE
/// report whose byte 1 is `0xF0`. They're reported as ``AuxButtons``, as
/// many as ``DigitizerSpec/buttonCount`` says, or all 16 if it's zero. Dials
/// and touch strips are ignored for now.
///
/// The UGEE v2 pen path is tested on a Xencelabs Pen Display 24. The Huion v2
/// paths are tested against recordings of Huion tablets, but not yet on
/// hardware under macOS.
public struct UCLogicDecoder: TabletReportDecoder {

    static let huionPenReportID: UInt8 = 0x08
    static let ugeePenReportID: UInt8 = 0x02

    static let barrel1Bit: UInt8 = 0x02
    static let barrel2Bit: UInt8 = 0x04
    static let barrel3Bit: UInt8 = 0x08
    static let ugeeAuxBit: UInt8 = 0x10
    static let ugeeInRangeBit: UInt8 = 0x20
    static let ugeeEraserBit: UInt8 = 0x40
    static let huionButtonsStatus: UInt8 = 0xE0
    static let ugeeButtonsStatus: UInt8 = 0xF0

    /// Tool code for every UC-Logic pen. See ``ToolIdentity/toolCode``.
    static let toolCode: UInt16 = 0xE902
    /// Tool code for a UC-Logic pen's eraser end.
    static let eraserToolCode: UInt16 = 0xE90A

    /// Degrees at full tilt, which the wire reports one per count.
    static let tiltMaxDegrees = 60.0

    /// The protocol of the last pen report, which decides the timeout.
    public private(set) var tabletProtocol: UCLogicProtocol?

    /// Creates a decoder. Pass the protocol if the switch-on answer already
    /// told you; otherwise the first pen report decides.
    public init(protocol tabletProtocol: UCLogicProtocol? = nil) {
        self.tabletProtocol = tabletProtocol
    }

    /// 100 ms for Huion v2 tablets, which never report the pen leaving.
    public var silenceTimeout: TimeInterval? {
        tabletProtocol == .huionV2 ? 0.1 : nil
    }

    /// Decodes one report. See ``TabletReportDecoder/decode(report:spec:state:deviceFamily:)``.
    public mutating func decode(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        switch report.reportID {
        case Self.huionPenReportID where report.count >= 12:
            return decodeHuion(report, spec: spec, state: &state)
        case Self.ugeePenReportID where report.count >= 10:
            return decodeUGEE(report, spec: spec, state: &state)
        default:
            return []
        }
    }

    /// Reports the pen leaving, if it hadn't already.
    public mutating func decodeSilence(
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        penLeft(spec: spec, state: &state)
    }

    private mutating func decodeHuion(
        _ report: HIDReport, spec: DigitizerSpec, state: inout DecoderState
    ) -> [DecodeResult] {
        let status = report[1]
        if status == Self.huionButtonsStatus {
            return [Self.buttons(report[4], report[5], spec: spec)]
        }
        // Pen reports have the top bit set; 0xE0 and up are the tablet's own
        // buttons and dials.
        guard status & 0x80 != 0, status < 0xE0 else { return [] }
        tabletProtocol = .huionV2

        let x = Int(report[2]) | Int(report[3]) << 8 | Int(report[8]) << 16
        let y = Int(report[4]) | Int(report[5]) << 8 | Int(report[9]) << 16
        let pressure = Int(report[6]) | Int(report[7]) << 8
        // Huion's tilt Y points the other way. The kernel reverses it too.
        let tiltX = Int(Int8(bitPattern: report[10]))
        let tiltY = -Int(Int8(bitPattern: report[11]))
        return penInRange(
            status: status, x: x, y: y, pressure: pressure,
            tiltX: tiltX, tiltY: tiltY, spec: spec, state: &state)
    }

    private mutating func decodeUGEE(
        _ report: HIDReport, spec: DigitizerSpec, state: inout DecoderState
    ) -> [DecodeResult] {
        let status = report[1]
        if status == Self.ugeeButtonsStatus {
            return [Self.buttons(report[2], report[3], spec: spec)]
        }
        // Bit 4 marks the tablet's buttons (F0) and battery (F2). Xencelabs
        // tablets also echo commands back as B0 to BF.
        guard status & Self.ugeeAuxBit == 0, status & 0xF0 != 0xB0 else { return [] }
        tabletProtocol = .ugeeV2

        guard status & Self.ugeeInRangeBit != 0 else {
            return penLeft(spec: spec, state: &state)
        }
        var x = Int(report[2]) | Int(report[3]) << 8
        // Tablets wider than 16 bits, such as 24-inch pen displays, put X's
        // third byte at 10. Hardware-confirmed on a Xencelabs Pen Display 24.
        if spec.maxX > 0xFFFF, report.count > 10 {
            x |= Int(report[10]) << 16
        }
        let y = Int(report[4]) | Int(report[5]) << 8
        let pressure = (Int(report[6]) | Int(report[7]) << 8) & 0x1FFF
        let tiltX = Int(Int8(bitPattern: report[8]))
        let tiltY = Int(Int8(bitPattern: report[9]))
        return penInRange(
            status: status, x: x, y: y, pressure: pressure,
            tiltX: tiltX, tiltY: tiltY, eraser: status & Self.ugeeEraserBit != 0,
            spec: spec, state: &state)
    }

    private func penInRange(
        status: UInt8, x: Int, y: Int, pressure: Int, tiltX: Int, tiltY: Int,
        eraser: Bool = false, spec: DigitizerSpec, state: inout DecoderState
    ) -> [DecodeResult] {
        var results: [DecodeResult] = []
        // Announce the tool on entering range, and when the pen flips over.
        if !state.prevInProximity || eraser != state.isEraser {
            state.prevInProximity = true
            state.isEraser = eraser
            results.append(
                .toolEnter(
                    ToolIdentity(
                        serial: 0, toolCode: eraser ? Self.eraserToolCode : Self.toolCode,
                        isEraser: eraser, isMouse: false)))
        }
        state.lastX = min(x, spec.maxX)
        state.lastY = min(y, spec.maxY)
        results.append(
            .pen(
                TabletPoint(
                    x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: min(pressure, spec.maxPressure), maxPressure: spec.maxPressure,
                    tiltX: Self.tiltFraction(tiltX), tiltY: Self.tiltFraction(tiltY),
                    rotation: 0.0,
                    penButton1: status & Self.barrel1Bit != 0,
                    penButton2: status & Self.barrel2Bit != 0,
                    eraser: eraser, inProximity: true, hoverDistance: 0,
                    penButton3: status & Self.barrel3Bit != 0)))
        return results
    }

    private func penLeft(spec: DigitizerSpec, state: inout DecoderState) -> [DecodeResult] {
        guard state.prevInProximity else { return [] }
        state.prevInProximity = false
        let wasEraser = state.isEraser
        state.isEraser = false
        return [
            .pen(
                TabletPoint(
                    x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: 0, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: false, penButton2: false,
                    eraser: wasEraser, inProximity: false, hoverDistance: 0))
        ]
    }

    /// Unpacks a two-byte button bitmap, lowest bit first.
    private static func buttons(_ low: UInt8, _ high: UInt8, spec: DigitizerSpec) -> DecodeResult {
        let bits = Int(low) | Int(high) << 8
        let count = spec.buttonCount > 0 ? min(spec.buttonCount, 16) : 16
        return .aux(AuxButtons(buttons: (0..<count).map { bits & (1 << $0) != 0 }))
    }

    private static func tiltFraction(_ degrees: Int) -> Double {
        max(-1.0, min(1.0, Double(degrees) / tiltMaxDegrees))
    }
}
