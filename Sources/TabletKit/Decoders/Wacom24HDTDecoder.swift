// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom `WACOM_24HDT` multitouch report family, ported from
/// the kernel's `wacom_24hdt_irq()`.
///
/// Used by the touch interface of these pen displays, separate from the pen's:
///   - Cintiq 13HD Touch (DTH-1300): pen `0x0333`, touch `0x0335`
///   - Cintiq 24HD Touch (DTH-2400): pen `0x00F8`, touch `0x00F6`
///   - Cintiq 22HD Touch: pen `0x005B`, touch `0x005E`
///   - Cintiq 22 (DTH-2242): pen `0x0059`, touch `0x005D`
///
/// No capture exists from any of them. The Cintiq 27QHD Touch shares the
/// kernel function but not this layout; see `Wacom27QHDTDecoder`.
///
/// Report 0x01, 62 bytes:
///   [0]        report ID 0x01
///   [1..56]    four 14-byte contact records
///   [57..60]   reserved
///   [61]       active-contact count for the whole frame, not this packet
///
/// Contact record, offsets from the record's start:
///   [0]        status; bit 0 = contact active
///   [1]        contact/tracking ID
///   [2..3]     touch X, LE u16
///   [4..5]     contact-center X, LE u16 (unused)
///   [6..7]     touch Y, LE u16
///   [8..9]     contact-center Y, LE u16 (unused)
///   [10..11]   contact width, LE u16
///   [12..13]   contact height, LE u16
///
/// A frame of more than four contacts spans packets. A nonzero byte 61
/// starts a frame; contacts collect in `State` until that many arrive, then
/// go out as one `.touch(_)`.
package struct Wacom24HDTDecoder: TabletReportDecoder {

    /// Creates a decoder. ``DeviceDecoder`` keeps one per device, with its state.
    public init() {}

    /// Decodes one report. See ``TabletReportDecoder/decode(report:spec:state:deviceFamily:)``.
    public func decode(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard report.count >= 62, report[0] == 0x01 else { return [] }
        return decodeMultitouchReport(report: report, state: &state)
    }

    // MARK: - 0x01 multitouch report

    private static let recordSize = 14
    private static let recordsPerPacket = 4
    private static let recordsBase = 1
    private static let frameCountOffset = 61
    /// The hardware's 10-finger ceiling. A larger count is a corrupt byte;
    /// clamping keeps it from growing state without bound.
    private static let maxPlausibleContacts = 10

    private func decodeMultitouchReport(
        report: HIDReport,
        state: inout State
    ) -> [DecodeResult] {
        let frameCount = min(Int(report[Self.frameCountOffset]), Self.maxPlausibleContacts)

        // The count is the frame's total, not a delta, so a nonzero value
        // restarts collection; a dropped packet can't wedge it.
        if frameCount > 0 {
            state.wacom24HDTPendingContacts = []
            state.wacom24HDTRemainingContacts = frameCount
        }

        guard state.wacom24HDTRemainingContacts > 0 else {
            // Every finger lifted. Emit an empty frame, not nothing: nothing
            // downstream times contacts out, so the last ones would stay down.
            return [.touch([])]
        }

        let recordsThisPacket = min(Self.recordsPerPacket, state.wacom24HDTRemainingContacts)
        for slot in 0 ..< recordsThisPacket {
            let base = Self.recordsBase + slot * Self.recordSize
            guard base + Self.recordSize <= report.count else { break }
            guard let contact = decodeContactRecord(report: report, base: base) else { continue }
            state.wacom24HDTPendingContacts.append(contact)
        }
        state.wacom24HDTRemainingContacts -= recordsThisPacket

        guard state.wacom24HDTRemainingContacts <= 0 else {
            // Frame still incomplete; wait for the next packet.
            return []
        }

        let completed = state.wacom24HDTPendingContacts
        state.wacom24HDTPendingContacts = []
        state.wacom24HDTRemainingContacts = 0
        return [.touch(completed)]
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
        let y = report.le16(at: base + 6)
        let width = report.le16(at: base + 10)
        let height = report.le16(at: base + 12)

        // The kernel reports min(width, height) for both axes.
        let major = min(width, height)
        return TouchContact(id: id, x: x, y: y, contactArea: major, contactMinor: major)
    }
}

extension Wacom24HDTDecoder {
    /// What this decoder remembers between reports.
    package struct State: DecoderState {
        /// Contacts collected toward the current frame.
        package var wacom24HDTPendingContacts: [TouchContact] = []
        /// Contacts still expected before the frame is complete.
        package var wacom24HDTRemainingContacts: Int = 0

        package init() {}
    }
}
