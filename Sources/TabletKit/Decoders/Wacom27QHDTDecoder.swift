// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom `WACOM_27QHDT` multitouch report family.
///
/// Used by the touch sensor half of the Cintiq 27QHD Touch (DTH-2700): pen
/// at `0x032B`, touch at `0x032C`. A structurally different protocol from
/// the similarly-named `Wacom24HDTDecoder`/`WACOM_24HDT` despite both being
/// dispatched through the kernel's single `wacom_24hdt_irq()` function —
/// `WACOM_27QHDT` is an explicit branch inside that function with its own
/// contact-count offset, packet capacity, and record size. Do not treat the
/// two protocols as interchangeable; see `Wacom24HDTDecoder`'s own doc
/// comment for why `0x032C` must not be routed there.
///
/// Byte layout below re-verified directly against `drivers/hid/wacom_wac.c`
/// (torvalds/linux, function `wacom_24hdt_irq`, `WACOM_27QHDT` branch)
/// 2026-09-08 — not taken on trust from the third-party research that
/// prompted this decoder, since an adjacent claim from a related pass (the
/// 27QHD's onboard bezel-key report) needed a real correction the same day.
/// This byte layout, unlike that one, checked out exactly as described.
/// **Still entirely unverified against a real capture from the device
/// itself** — see `Notes/Scratch/wacom-24hdt-touch-design-2026-09-08.md` for
/// the shared design rationale and confidence-tier reasoning (same
/// `.experimental` tier, same "do not wire without a call-site warning"
/// requirement once a registry row is added).
///
/// Report 0x05, 64 bytes (simpler than WACOM_24HDT — fits all ten contacts
/// in one packet, no multi-frame reassembly needed):
///   [0]        report ID 0x05
///   [1..6]     contact record 0
///   [7..12]    contact record 1
///   ...
///   [55..60]   contact record 9
///   [61..62]   unused, even by the kernel
///   [63]       active-contact count
///
/// Contact record (6 bytes), offsets relative to the record's own start:
///   [0]        status; bit 0 = contact active
///   [1]        contact/tracking ID
///   [2..3]     X, LE u16
///   [4..5]     Y, LE u16
///
/// No width/height/contact-center fields — the kernel's own 24HDT-only block
/// that reads those (and derives touchMajor/Minor/orientation from them) is
/// explicitly gated off for `WACOM_27QHDT`. The kernel's local `y_offset`
/// variable (2 for 24HDT, 0 here) exists only to skip 24HDT's extra
/// contact-center-X field before reading Y; 27QHDT's 6-byte record has no
/// such field, so Y sits immediately after X with no offset needed — that
/// is reflected directly in this decoder's fixed byte offsets below, not
/// modeled as a separate parameter.
///
/// Byte 63 is the frame's total active-contact count, same semantic as
/// WACOM_24HDT's byte 61 — but because up to 10 contacts (the hardware's
/// full ceiling) fit in one 64-byte packet, a legitimate frame never needs
/// more than one packet, unlike WACOM_24HDT's 4-per-packet cap. No
/// cross-packet accumulator state is needed in `DecoderState` for this
/// decoder.
///
/// The report ID itself (0x05) is not something the kernel's decode
/// function inspects — dispatch happens by device-family type, fixed at
/// probe time, not by report ID. 0x05 is simply what this interface emits
/// in its full vendor touch mode; `decode(...)` below still gates on it
/// defensively, matching every other decoder in this package's convention
/// of checking `report[0]` before trusting a byte layout.
public struct Wacom27QHDTDecoder: TabletReportDecoder {

    public init() {}

    public func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard length >= 64, report[0] == 0x05 else { return [] }
        return decodeMultitouchReport(report: report, length: length)
    }

    // MARK: - 0x05 multitouch report

    private static let recordSize = 6
    private static let recordsPerPacket = 10
    private static let recordsBase = 1
    private static let frameCountOffset = 63

    private func decodeMultitouchReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex
    ) -> [DecodeResult] {
        let frameCount = min(Int(report[Self.frameCountOffset]), Self.recordsPerPacket)
        guard frameCount > 0 else { return [.touch([])] }

        var contacts: [TouchContact] = []
        for slot in 0 ..< frameCount {
            let base = Self.recordsBase + slot * Self.recordSize
            guard base + Self.recordSize <= length else { break }
            guard let contact = decodeContactRecord(report: report, base: base) else { continue }
            contacts.append(contact)
        }
        return [.touch(contacts)]
    }

    /// Decodes one 6-byte contact record starting at `base` within `report`.
    /// Returns `nil` for an inactive slot (status bit 0 clear) — same
    /// release-by-omission convention as `Wacom24HDTDecoder`.
    private func decodeContactRecord(
        report: UnsafePointer<UInt8>,
        base: Int
    ) -> TouchContact? {
        let status = report[base]
        guard (status & 0x01) != 0 else { return nil }

        let id = Int(report[base + 1])
        let x = Int(report[base + 2]) | (Int(report[base + 3]) << 8)
        let y = Int(report[base + 4]) | (Int(report[base + 5]) << 8)

        // No width/height on this wire format — see the type doc comment.
        return TouchContact(id: id, x: x, y: y, contactArea: nil, contactMinor: nil)
    }
}
