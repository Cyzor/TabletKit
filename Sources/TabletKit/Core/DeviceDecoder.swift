// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decodes the reports of one connected device: its report format, its
/// ranges and family, and everything it remembers between reports.
///
/// ```swift
/// var decoder = spec.makeDecoder()
/// let results = decoder.decode(HIDReport(pointer: buffer, count: length))
/// ```
///
/// Keep one per device, or one per interface that sends its own reports, and
/// call it from a single thread.
public struct DeviceDecoder: Sendable {
    private var decoder: any TabletReportDecoder
    private var state = DecoderState()
    var padShape = PadShape(rings: 0, strips: 0)
    private var toolInRange: ToolIdentity?

    /// The ranges reports are read against. Settable for a wireless receiver
    /// that learns which tablet it's paired to.
    public var digitizer: DigitizerSpec
    public let family: DeviceFamily

    public init(spec: TabletSpec) {
        self.init(format: spec.format, digitizer: spec.digitizerSpec, family: spec.family)
        padShape = PadShape(spec: spec)
    }

    public init(format: ReportFormat, digitizer: DigitizerSpec, family: DeviceFamily) {
        self.init(format.decoder(), digitizer: digitizer, family: family)
    }

    /// Wraps a decoder that isn't chosen by format, such as a fixed-layout
    /// touch sensor's.
    package init(_ decoder: any TabletReportDecoder, digitizer: DigitizerSpec, family: DeviceFamily) {
        self.decoder = decoder
        self.digitizer = digitizer
        self.family = family
    }

    package mutating func decode(_ report: HIDReport) -> [DecodeResult] {
        decoder.decode(report: report, spec: digitizer, state: &state, deviceFamily: family)
    }

    /// How long without a report means the pen has left, or `nil` if the
    /// tablet says so itself. After this long, call ``eventsForSilence()``.
    public var silenceTimeout: TimeInterval? { decoder.silenceTimeout }

    package mutating func decodeSilence() -> [DecodeResult] {
        decoder.decodeSilence(spec: digitizer, state: &state, deviceFamily: family)
    }

    /// Decodes one report into events. Adds a tool leave when the pen goes
    /// out of range.
    public mutating func events(_ report: HIDReport) -> [TabletEvent] {
        events(from: decode(report))
    }

    /// What a stretch of silence as long as ``silenceTimeout`` means, such as
    /// the pen leaving.
    public mutating func eventsForSilence() -> [TabletEvent] {
        events(from: decodeSilence())
    }

    private mutating func events(from results: [DecodeResult]) -> [TabletEvent] {
        var events: [TabletEvent] = []
        events.reserveCapacity(results.count + 1)
        let stamps = state.btTouchFrameStamps
        var touchIndex = 0
        for result in results {
            switch result {
            case .none:
                break
            case .pen(let point):
                events.append(.pen(point))
                if !point.inProximity, let tool = toolInRange {
                    toolInRange = nil
                    events.append(.tool(ToolEvent(identity: tool, phase: .leave)))
                }
            case .toolEnter(let identity):
                toolInRange = identity
                events.append(.tool(ToolEvent(identity: identity, phase: .enter)))
            case .aux(let aux):
                events.append(.pad(PadState(aux, shape: padShape)))
            case .wheel(let index, let delta):
                events.append(.dial(index: index, delta: delta))
            case .touch(let contacts):
                let time = touchIndex < stamps.count ? stamps[touchIndex] : nil
                touchIndex += 1
                events.append(.touch(TouchFrame(contacts: contacts, deviceTime: time)))
            case .wireless(let status):
                events.append(.device(.wireless(status)))
            case .battery(let percent, let charging):
                events.append(.device(.battery(percent: percent, charging: charging)))
            case .remotePairing(let slots):
                events.append(.device(.remotePairing(slots)))
            case .toolCompatibility(let note):
                events.append(.device(.toolSupport(note: note)))
            case .mouseButton(let bits):
                events.append(.device(.mouseButtons(bits)))
            }
        }
        return events
    }

    /// Forgets the current pen and touches, as when a wireless link drops or
    /// comes back.
    public mutating func reset() {
        state = DecoderState()
        toolInRange = nil
    }

    /// Whether the last report had the pen in range.
    public var penInRange: Bool { state.prevInProximity }

    /// The device's own clock for each touch frame in the last report, when
    /// it sends one (Bluetooth batches only), in the order the frames were
    /// decoded.
    package var touchFrameStamps: [UInt16] { state.btTouchFrameStamps }
}

extension TabletSpec {
    /// A decoder for one device of this model.
    public func makeDecoder() -> DeviceDecoder { DeviceDecoder(spec: self) }
}

extension DeviceDecoder {
    /// Touch sensors whose finger reports use a fixed vendor layout rather
    /// than one their descriptor describes, by the sensor's own product ID.
    private static let fixedLayoutTouchProductIDs: Set<Int> = [
        0x0335,  // Cintiq 13HD Touch (DTH-1300)
        0x00F6,  // Cintiq 24HD Touch (DTH-2400)
        0x005E,  // Cintiq 22HD Touch
        0x005D,  // Cintiq 22 Touch (DTH-2242)
    ]

    /// A decoder for a touch sensor with a fixed vendor layout, and the
    /// report ID its finger frames arrive on, or `nil` when `productID`
    /// isn't one. Read every other touch sensor from its descriptor.
    ///
    /// The layout comes from the Linux kernel and isn't checked on hardware.
    public static func fixedLayoutTouch(
        productID: Int, digitizer: DigitizerSpec, family: DeviceFamily
    ) -> (reportID: UInt8, decoder: DeviceDecoder)? {
        guard fixedLayoutTouchProductIDs.contains(productID) else { return nil }
        return (0x01, DeviceDecoder(Wacom24HDTDecoder(), digitizer: digitizer, family: family))
    }
}
