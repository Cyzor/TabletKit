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

    /// The ranges reports are read against. Settable for a wireless receiver
    /// that learns which tablet it's paired to.
    public var digitizer: DigitizerSpec
    public let family: DeviceFamily

    public init(spec: TabletSpec) {
        self.init(format: spec.format, digitizer: spec.digitizerSpec, family: spec.family)
    }

    public init(format: ReportFormat, digitizer: DigitizerSpec, family: DeviceFamily) {
        self.init(format.decoder(), digitizer: digitizer, family: family)
    }

    /// Wraps a decoder that isn't chosen by format, such as a fixed-layout
    /// touch sensor's.
    public init(_ decoder: any TabletReportDecoder, digitizer: DigitizerSpec, family: DeviceFamily) {
        self.decoder = decoder
        self.digitizer = digitizer
        self.family = family
    }

    public mutating func decode(_ report: HIDReport) -> [DecodeResult] {
        decoder.decode(report: report, spec: digitizer, state: &state, deviceFamily: family)
    }

    /// How long without a report means the pen has left, or `nil` if the
    /// tablet says so itself. After this long, call ``decodeSilence()``.
    public var silenceTimeout: TimeInterval? { decoder.silenceTimeout }

    public mutating func decodeSilence() -> [DecodeResult] {
        decoder.decodeSilence(spec: digitizer, state: &state, deviceFamily: family)
    }

    /// Forgets the current pen and touches, as when a wireless link drops or
    /// comes back.
    public mutating func reset() {
        state = DecoderState()
    }

    /// Whether the last report had the pen in range.
    public var penInRange: Bool { state.prevInProximity }

    /// The device's own clock for each touch frame in the last report, when
    /// it sends one (Bluetooth batches only), in the order the frames were
    /// decoded.
    public var touchFrameStamps: [UInt16] { state.btTouchFrameStamps }
}

extension TabletSpec {
    /// A decoder for one device of this model.
    public func makeDecoder() -> DeviceDecoder { DeviceDecoder(spec: self) }
}
