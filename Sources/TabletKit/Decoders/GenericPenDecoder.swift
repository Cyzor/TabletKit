// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A pen digitizer input report, described entirely by the device's own
/// report descriptor rather than by a per-family byte-offset table.
///
/// This is the pen counterpart to `PrecisionTouchLayout`: where that type
/// exists because a multitouch report repeats the same usages once per
/// finger and needs bit offsets rather than element values, this one exists
/// because the fallback path for an *unrecognized* Wacom device currently
/// guesses which byte-offset family applies from `maxInputReportSize` alone
/// — a proxy that fails on modern hardware, whose ~26-byte pen report is
/// closer in size to the decades-older Intuos1 format than to the Intuos2
/// family it actually needs.
///
/// A modern Wacom pen report does not need that guess. It declares itself
/// field by field, on Wacom's vendor page (`0xFF0D`) but under the *standard*
/// Digitizer usage numbers `DigitizerUsage` recognizes — confirmed against a
/// real Cintiq Pro 24 (DTH-2420) descriptor, where every field this type
/// reads matched the device's own declared bit offsets exactly.
public struct GenericPenLayout: Equatable, Sendable {

    /// Report ID this layout decodes.
    public let reportID: UInt8
    /// Payload size in bytes, excluding the leading report-ID byte.
    public let payloadBytes: Int

    public let x: DescriptorField
    public let y: DescriptorField

    public let tipSwitch: DescriptorField?
    public let inRange: DescriptorField?
    public let barrelSwitch: DescriptorField?
    public let secondaryBarrel: DescriptorField?
    public let eraserSwitch: DescriptorField?
    public let invert: DescriptorField?
    public let tipPressure: DescriptorField?
    public let tiltX: DescriptorField?
    public let tiltY: DescriptorField?
    public let twist: DescriptorField?
    public let hoverDistance: DescriptorField?
    /// The pen's serial number, when the pen reports one.
    public let transducerSerial: DescriptorField?
    /// Wacom's tool code, on a Wacom vendor page.
    public let toolType: DescriptorField?

    /// Declared logical maximum of the X axis, in device units.
    public let logicalMaxX: Int
    /// Declared logical maximum of the Y axis, in device units.
    public let logicalMaxY: Int
    /// Declared logical maximum of tip pressure, or 0 if the report declares
    /// no pressure field.
    public let logicalMaxPressure: Int

    /// Derives every pen input report the descriptor declares, in report-ID
    /// order.
    ///
    /// A report qualifies when it declares absolute X and Y outside any Touch
    /// Screen or Touch Pad collection — the same negative gate
    /// `PrecisionTouchLayout` uses in the other direction, so a hybrid pen +
    /// touch interface yields a pen layout from this type and a touch layout
    /// from that one, never a report double-counted as both. An absolute
    /// Mouse with no tip, range, or pressure doesn't qualify either.
    public static func derive(from layout: DescriptorLayout) -> [GenericPenLayout] {
        layout.reports
            .filter { $0.direction == .input }
            .sorted { $0.reportID < $1.reportID }
            .compactMap { derive(from: $0) }
    }

    /// Derives a layout from a single report, or `nil` when it is not a pen
    /// digitizer report.
    public static func derive(from report: DescriptorReport) -> GenericPenLayout? {
        // A finger has a tip switch and X/Y too. Wacom declares its fingers
        // on a vendor page, outside any Touch Screen collection.
        guard !report.fields.contains(where: isTouch) else { return nil }

        var x: DescriptorField?
        var y: DescriptorField?
        var tipSwitch: DescriptorField?
        var inRange: DescriptorField?
        var barrelSwitch: DescriptorField?
        var secondaryBarrel: DescriptorField?
        var eraserSwitch: DescriptorField?
        var invert: DescriptorField?
        var tipPressure: DescriptorField?
        var tiltX: DescriptorField?
        var tiltY: DescriptorField?
        var twist: DescriptorField?
        var hoverDistance: DescriptorField?
        var transducerSerial: DescriptorField?
        var toolType: DescriptorField?

        for field in report.fields where !field.isConstant && field.isVariable {
            // Relative X/Y never belongs to a pen — see
            // `classifyDigitizerInterface`, which excludes it for the
            // matching reason on the routing side. A pen's position is
            // always absolute.
            if field.isRelative { continue }

            let isTouchCollection =
                field.collectionPath.contains(PrecisionTouchLayout.Usage.touchScreenCollection)
                || field.collectionPath.contains(PrecisionTouchLayout.Usage.touchPadCollection)
            if isTouchCollection { continue }

            // X/Y accept either the standard Generic Desktop usage or Wacom's
            // vendor-page position usage — the DTH-2420 declares the latter.
            let isStandardX = field.usagePage == 0x01 && field.usage == 0x30
            let isStandardY = field.usagePage == 0x01 && field.usage == 0x31
            let isVendorX = field.usage == DigitizerUsage.vendorX
                && DigitizerUsage.isDecodable(usagePage: field.usagePage, usage: field.usage)
            let isVendorY = field.usage == DigitizerUsage.vendorY
                && DigitizerUsage.isDecodable(usagePage: field.usagePage, usage: field.usage)

            if isStandardX || isVendorX { if x == nil { x = field }; continue }
            if isStandardY || isVendorY { if y == nil { y = field }; continue }

            guard DigitizerUsage.isDecodable(usagePage: field.usagePage, usage: field.usage) else {
                continue
            }

            switch field.usage {
            case DigitizerUsage.tipSwitch: if tipSwitch == nil { tipSwitch = field }
            case DigitizerUsage.inRange: if inRange == nil { inRange = field }
            case DigitizerUsage.barrelSwitch: if barrelSwitch == nil { barrelSwitch = field }
            case DigitizerUsage.secondaryBarrel: if secondaryBarrel == nil { secondaryBarrel = field }
            case DigitizerUsage.eraserSwitch: if eraserSwitch == nil { eraserSwitch = field }
            case DigitizerUsage.invert: if invert == nil { invert = field }
            case DigitizerUsage.tipPressure: if tipPressure == nil { tipPressure = field }
            case DigitizerUsage.tiltX: if tiltX == nil { tiltX = field }
            case DigitizerUsage.tiltY: if tiltY == nil { tiltY = field }
            case DigitizerUsage.twist: if twist == nil { twist = field }
            case DigitizerUsage.vendorHoverDistance: if hoverDistance == nil { hoverDistance = field }
            case DigitizerUsage.transducerSerial: if transducerSerial == nil { transducerSerial = field }
            case DigitizerUsage.transducerToolType where field.usagePage >= 0xFF00:
                if toolType == nil { toolType = field }
            default: continue
            }
        }

        // A malformed descriptor can declare a zero or negative maximum, and
        // mapping a position against it divides by zero.
        guard let x, let y, x.logicalMax > 0, y.logicalMax > 0 else { return nil }
        // Laptop panels declare an absolute Mouse alongside the pen. With no
        // tip, range, or pressure it would read as a pen always in range.
        let isMouse = x.collectionPath.contains(Self.mouseCollection)
        if isMouse, tipSwitch == nil, inRange == nil, tipPressure == nil { return nil }

        return GenericPenLayout(
            reportID: report.reportID,
            payloadBytes: (report.totalBits + 7) / 8,
            x: x, y: y,
            tipSwitch: tipSwitch, inRange: inRange,
            barrelSwitch: barrelSwitch, secondaryBarrel: secondaryBarrel,
            eraserSwitch: eraserSwitch, invert: invert,
            tipPressure: tipPressure, tiltX: tiltX, tiltY: tiltY, twist: twist,
            hoverDistance: hoverDistance,
            transducerSerial: transducerSerial, toolType: toolType,
            logicalMaxX: x.logicalMax, logicalMaxY: y.logicalMax,
            logicalMaxPressure: tipPressure?.logicalMax ?? 0)
    }
}

extension GenericPenLayout {
    /// Generic Desktop Mouse.
    static let mouseCollection: UInt32 = 0x0001_0002

    /// The pen report at native resolution. Recent Wacom models declare a
    /// HID-mode pen report first, often normalized to 32767 or at half
    /// resolution, so this takes the full pen with the most counts per
    /// millimeter, or the widest when a report gives no physical size.
    static func native(in pens: [GenericPenLayout]) -> GenericPenLayout? {
        let full = pens.filter { $0.tipPressure != nil }
        let candidates = full.isEmpty ? pens : full
        let perMillimeter = candidates.map { countsPerMillimeter($0.x) }
        let keys = perMillimeter.contains(nil)
            ? candidates.map { Double($0.logicalMaxX) } : perMillimeter.map { $0 ?? 0 }
        // Ties keep the lowest report ID.
        return zip(candidates, keys).max { $0.1 < $1.1 }?.0
    }

    /// An axis's resolution, when it declares a physical length in
    /// centimeters or inches.
    private static func countsPerMillimeter(_ axis: DescriptorField) -> Double? {
        let millimetersPerUnit: Double
        switch axis.unit & 0xFF {
        case 0x11: millimetersPerUnit = 10
        case 0x13: millimetersPerUnit = 25.4
        default: return nil
        }
        let physical = Double(axis.physicalMax - axis.physicalMin)
            * pow(10, Double(axis.unitExponent)) * millimetersPerUnit
        guard physical > 0 else { return nil }
        return Double(axis.logicalMax - axis.logicalMin) / physical
    }

    /// Whether a field sits in a Finger collection, on the Digitizer page or
    /// a vendor page. Contact usages don't count: Wacom declares Contact
    /// Count inside its Stylus collections.
    static func isTouch(_ field: DescriptorField) -> Bool {
        field.collectionPath.contains { ($0 >> 16 == 0x0D || $0 >> 16 >= 0xFF00) && $0 & 0xFFFF == 0x22 }
    }
}

/// Decodes a HID pen digitizer report against a descriptor-derived
/// `GenericPenLayout`.
///
/// `decode(report:)` returns the point alone. `events(report:state:)` also
/// announces the tool, which takes state between reports.
public struct GenericPenDecoder: Sendable {

    public let layout: GenericPenLayout

    public init(layout: GenericPenLayout) {
        self.layout = layout
    }

    /// Decodes one raw input report.
    ///
    /// - Parameter report: Full report bytes *including* the leading
    ///   report-ID byte at index 0.
    /// - Returns: `nil` when the report is not this layout's report ID or is
    ///   too short to hold the declared payload.
    public func decode(report: [UInt8]) -> TabletPoint? {
        HIDReport.withReport(report) { decode(report: $0) }
    }

    /// Decodes one raw input report, borrowed for the duration of the call.
    ///
    /// A layout with report ID 0 comes from a descriptor that declares no
    /// report IDs, so its reports start with data.
    public func decode(report: HIDReport) -> TabletPoint? {
        let idBytes = layout.reportID == 0 ? 0 : 1
        guard report.count >= layout.payloadBytes + idBytes,
              idBytes == 0 || report.reportID == layout.reportID
        else { return nil }

        let payload = Array(UnsafeBufferPointer(start: report.pointer + idBytes, count: report.count - idBytes))

        let x = extractField(layout.x, from: payload)
        let y = extractField(layout.y, from: payload)

        // A pen with no pressure field presses at full scale while its tip
        // is down, so taps still click.
        let tipDown = layout.tipSwitch.map { extractField($0, from: payload) != 0 } ?? false
        let pressure = layout.tipPressure.map { extractField($0, from: payload) } ?? (tipDown ? 1 : 0)

        // Tilt is a signed field whose logical range is the degree bound;
        // TabletPoint wants -1.0...1.0, so normalize by the field's own
        // declared magnitude rather than a hardcoded ±64.
        func normalizedTilt(_ field: DescriptorField?) -> Double {
            guard let field else { return 0 }
            let raw = extractField(field, from: payload)
            let bound = Swift.max(abs(field.logicalMin), abs(field.logicalMax))
            guard bound > 0 else { return 0 }
            return Swift.max(-1, Swift.min(1, Double(raw) / Double(bound)))
        }

        // In Range is the proximity signal when declared; a report with no
        // such field but a live X/Y is presumed in proximity, matching how
        // the hand-written family decoders treat a report that arrived at
        // all as evidence the pen is present.
        let inProximity = layout.inRange.map { extractField($0, from: payload) != 0 } ?? true

        let isEraser =
            (layout.invert.map { extractField($0, from: payload) != 0 } ?? false)
            || (layout.eraserSwitch.map { extractField($0, from: payload) != 0 } ?? false)

        return TabletPoint(
            x: x, y: y,
            maxX: layout.logicalMaxX, maxY: layout.logicalMaxY,
            pressure: pressure, maxPressure: Swift.max(layout.logicalMaxPressure, 1),
            tiltX: normalizedTilt(layout.tiltX),
            tiltY: normalizedTilt(layout.tiltY),
            rotation: layout.twist.map { Double(extractField($0, from: payload)) } ?? 0,
            penButton1: layout.barrelSwitch.map { extractField($0, from: payload) != 0 } ?? false,
            penButton2: layout.secondaryBarrel.map { extractField($0, from: payload) != 0 } ?? false,
            eraser: isEraser,
            inProximity: inProximity,
            hoverDistance: layout.hoverDistance.map { extractField($0, from: payload) } ?? 0)
    }
}

extension GenericPenDecoder {
    /// What the decoder remembers between reports, to announce tools.
    package struct ToolState: Sendable {
        /// The tool last announced, or nil while no pen is in range.
        package var current: ToolIdentity?

        package init() {}
    }

    /// Tool code for a pen that doesn't identify itself, shared with
    /// UC-Logic pens. See ``ToolIdentity/toolCode``.
    static let toolCode: UInt16 = 0xE902
    static let eraserToolCode: UInt16 = 0xE90A

    /// Decodes one report into events: a tool enter when a pen comes into
    /// range, flips over, or is swapped, then the point.
    package func events(report: HIDReport, state: inout ToolState) -> [TabletEvent] {
        guard let point = decode(report: report) else { return [] }
        guard point.inProximity else {
            state.current = nil
            return [.pen(point)]
        }
        let identity = toolIdentity(report: report, isEraser: point.eraser)
        guard identity != state.current else { return [.pen(point)] }
        state.current = identity
        return [.tool(ToolEvent(identity: identity, phase: .enter)), .pen(point)]
    }

    /// The pen in range, from its own serial and tool code where the
    /// descriptor declares them.
    private func toolIdentity(report: HIDReport, isEraser: Bool) -> ToolIdentity {
        let idBytes = layout.reportID == 0 ? 0 : 1
        let payload = Array(UnsafeBufferPointer(start: report.pointer + idBytes, count: report.count - idBytes))
        let serial = layout.transducerSerial.map { UInt32(truncatingIfNeeded: extractField($0, from: payload)) } ?? 0
        let reported = layout.toolType.map { UInt16(truncatingIfNeeded: extractField($0, from: payload)) } ?? 0
        let code = reported != 0 ? reported : (isEraser ? Self.eraserToolCode : Self.toolCode)
        return ToolIdentity(serial: serial, toolCode: code, isEraser: isEraser, isMouse: false)
    }
}
