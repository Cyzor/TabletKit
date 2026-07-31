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
public struct GenericPenLayout: Equatable {

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
    /// from that one, never a report double-counted as both.
    public static func derive(from layout: DescriptorLayout) -> [GenericPenLayout] {
        layout.reports
            .filter { $0.direction == .input }
            .sorted { $0.reportID < $1.reportID }
            .compactMap { derive(from: $0) }
    }

    /// Derives a layout from a single report, or `nil` when it is not a pen
    /// digitizer report.
    public static func derive(from report: DescriptorReport) -> GenericPenLayout? {
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
            default: continue
            }
        }

        guard let x, let y else { return nil }

        return GenericPenLayout(
            reportID: report.reportID,
            payloadBytes: (report.totalBits + 7) / 8,
            x: x, y: y,
            tipSwitch: tipSwitch, inRange: inRange,
            barrelSwitch: barrelSwitch, secondaryBarrel: secondaryBarrel,
            eraserSwitch: eraserSwitch, invert: invert,
            tipPressure: tipPressure, tiltX: tiltX, tiltY: tiltY, twist: twist,
            hoverDistance: hoverDistance,
            logicalMaxX: x.logicalMax, logicalMaxY: y.logicalMax,
            logicalMaxPressure: tipPressure?.logicalMax ?? 0)
    }
}

/// Decodes a HID pen digitizer report against a descriptor-derived
/// `GenericPenLayout`.
///
/// Emits `TabletPoint` directly — the same type every hand-written family
/// decoder in `WacomFallbackDevice` builds — rather than routing through
/// `DecodeResult`, since the fallback driver calls `onTablet(TabletPoint)`
/// per report and has no use for a result array here.
public struct GenericPenDecoder {

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
        guard report.count > layout.payloadBytes,
              report[0] == layout.reportID
        else { return nil }

        let payload = Array(report.dropFirst())

        let x = extractField(layout.x, from: payload)
        let y = extractField(layout.y, from: payload)

        let pressure = layout.tipPressure.map { extractField($0, from: payload) } ?? 0

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
