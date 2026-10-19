// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom `WACOM_27QHDT` multitouch report family, ported
/// from the kernel's `wacom_24hdt_irq()`. Despite the shared function, its
/// layout differs from `Wacom24HDTDecoder`'s.
///
/// The Cintiq 27QHD Touch (DTH-2700) doesn't use this: its touch interface
/// sends a standard HID Digitizer report that `PrecisionTouchDecoder`
/// handles. This decoder stays for any other device in the family that
/// sends report 0x05; none has been seen on hardware.
///
/// Report 0x05, 64 bytes, all ten contacts in one packet, so no state
/// carries between reports:
///   [0]        report ID 0x05
///   [1..60]    ten 6-byte contact records
///   [61..62]   unused
///   [63]       active-contact count
///
/// Contact record, offsets from the record's start:
///   [0]        status; bit 0 = contact active
///   [1]        contact/tracking ID
///   [2..3]     X, LE u16
///   [4..5]     Y, LE u16
///
/// No width or height fields; the kernel gates its 24HDT size block off for
/// this family.
package struct Wacom27QHDTDecoder: TabletReportDecoder {

    /// Creates a decoder. ``DeviceDecoder`` keeps one per device, with its state.
    public init() {}

    /// Decodes one report. See ``TabletReportDecoder/decode(report:spec:state:deviceFamily:)``.
    public func decode(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard report.count >= 64, report[0] == 0x05 else { return [] }
        return decodeMultitouchReport(report: report)
    }

    // MARK: - 0x05 multitouch report

    private static let recordSize = 6
    private static let recordsPerPacket = 10
    private static let recordsBase = 1
    private static let frameCountOffset = 63

    private func decodeMultitouchReport(
        report: HIDReport
    ) -> [DecodeResult] {
        let frameCount = min(Int(report[Self.frameCountOffset]), Self.recordsPerPacket)
        guard frameCount > 0 else { return [.touch([])] }

        var contacts: [TouchContact] = []
        for slot in 0 ..< frameCount {
            let base = Self.recordsBase + slot * Self.recordSize
            guard base + Self.recordSize <= report.count else { break }
            guard let contact = decodeContactRecord(report: report, base: base) else { continue }
            contacts.append(contact)
        }
        return [.touch(contacts)]
    }

    /// Decodes the contact record at `base`, or `nil` for an inactive slot;
    /// an omitted contact counts as released.
    private func decodeContactRecord(
        report: HIDReport,
        base: Int
    ) -> TouchContact? {
        let status = report[base]
        guard (status & 0x01) != 0 else { return nil }

        let id = Int(report[base + 1])
        let x = report.le16(at: base + 2)
        let y = report.le16(at: base + 4)
        return TouchContact(id: id, x: x, y: y, contactArea: nil, contactMinor: nil)
    }
}

extension Wacom27QHDTDecoder {
    /// What this decoder remembers between reports.
    package struct State: DecoderState {
        package init() {}
    }
}
