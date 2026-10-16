// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The ``ReportFormat/descriptor`` decoder: pen reports read from the
/// tablet's own report descriptor, one ``GenericPenDecoder`` per report ID.
///
/// It starts empty. `TabletInput` adds each interface's pen reports as the
/// interface arrives, since the registry's decoder factory never sees a
/// descriptor.
package struct DescriptorPenDecoder: TabletReportDecoder {
    private var pens: [UInt8: GenericPenDecoder] = [:]

    package init() {}

    /// Adds the pen reports `descriptor` declares. A report ID already
    /// known keeps its first layout. Returns whether anything was added.
    @discardableResult
    package mutating func add(descriptor: [UInt8]) -> Bool {
        guard !descriptor.isEmpty, let layout = try? HIDReportDescriptorParser.parse(descriptor) else { return false }
        var added = false
        for pen in GenericPenLayout.derive(from: layout) where pens[pen.reportID] == nil {
            pens[pen.reportID] = GenericPenDecoder(layout: pen)
            added = true
        }
        return added
    }

    /// Whether any pen report is known.
    package var isEmpty: Bool { pens.isEmpty }

    package func decode(
        report: HIDReport, spec: DigitizerSpec, state: inout State, deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        // A descriptor without report IDs has one report, which starts with data.
        guard report.count > 0, let pen = pens[0] ?? pens[report.reportID] else { return [] }
        let events = pen.events(report: report, state: &state.tool)
        state.prevInProximity = state.tool.current != nil
        return events.compactMap { event in
            switch event {
            case .tool(let tool): .toolEnter(tool.identity)
            case .pen(let point): .pen(point)
            default: nil
            }
        }
    }

    package struct State: DecoderState {
        package var prevInProximity = false
        var tool = GenericPenDecoder.ToolState()

        package init() {}
    }
}
