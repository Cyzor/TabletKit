// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom `WACOM_24HDT` multitouch report family.
///
/// Used by the touch sensor half of four pen displays — a separate USB
/// interface from the paired pen device in every case:
///   - Cintiq 13HD Touch (DTH-1300): pen `0x0333`, touch `0x0335`
///   - Cintiq 24HD Touch (DTH-2400): pen `0x00F8`, touch `0x00F6`
///   - Cintiq 22HD Touch (DTH-2200-ish, "Cintiq 22HDT"): pen `0x005B`, touch `0x005E`
///   - Cintiq 22 / DTH2242: pen `0x0059`, touch `0x005D`
///
/// Confirmed 2026-09-08 by reading the kernel's `wacom_features_0x5E`/
/// `wacom_features_0x5D` table entries directly: both are plain
/// `.type = WACOM_24HDT` with no `WACOM_27QHDT` branch taken, i.e. the exact
/// same wire format this decoder already implements — no new decode logic
/// needed for either. **Not the same story for the Cintiq 27QHD Touch
/// (`0x032C`, pairs with pen `0x032B`)** — the kernel dispatches it through
/// this same `wacom_24hdt_irq()` function, but takes an explicit
/// `WACOM_27QHDT` branch inside it that changes the layout materially: 10
/// contact records per packet instead of 4, a different per-record byte
/// size (`WACOM_BYTES_PER_QHDTHID_PACKET`, not the 14-byte record below),
/// the contact count read from a different report offset, and a shifted Y
/// field within each record. That is a distinct decoder (or a real
/// extension of this one), not a registry-only wiring job — do not route
/// `0x032C` here without porting that branch first.
///
/// Ported from the Linux kernel's `wacom_24hdt_irq()` (`wacom_wac.c`) and an
/// OpenTabletDriver macOS diagnostic capture of the DTH-1300's touch
/// interface descriptor. **Entirely unverified against a real capture from
/// any of the four devices above** — see
/// `Notes/Scratch/wacom-24hdt-touch-design-2026-09-08.md` for the full
/// design rationale, open questions, and why this ships `.experimental`
/// rather than gated behind a hardware test. No registry row currently
/// routes to this decoder; wiring one in is a separate step, and per that
/// design doc's advisor review, adding one must carry its own "no capture
/// exists, unconfirmed" comment at the registry call site — this file's
/// own disclaimer isn't sufficient warning on its own.
///
/// Report 0x01, 62 bytes:
///   [0]        report ID 0x01
///   [1..14]    contact record 0
///   [15..28]   contact record 1
///   [29..42]   contact record 2
///   [43..56]   contact record 3
///   [57..60]   reserved — unused even by the kernel decoder
///   [61]       active-contact count for the WHOLE FRAME, not this packet
///
/// Contact record (14 bytes), offsets relative to the record's own start:
///   [0]        status; bit 0 = contact active
///   [1]        contact/tracking ID
///   [2..3]     touch X, LE u16
///   [4..5]     contact-center X, LE u16 (unused here — see below)
///   [6..7]     touch Y, LE u16
///   [8..9]     contact-center Y, LE u16 (unused here — see below)
///   [10..11]   contact width, LE u16
///   [12..13]   contact height, LE u16
///
/// Byte 61 describes the total contact count across a whole gesture update,
/// which can span more than one 4-contact packet. A nonzero byte 61 starts a
/// new frame; this decoder accumulates contacts in
/// `DecoderState.wacom24HDTPendingContacts` until that many have arrived,
/// then emits one `.touch(_)` result. A packet whose count is satisfied by
/// its own four records (≤4 fingers) completes and emits immediately.
///
/// Contact-center X/Y are parsed by the kernel to compute finger orientation
/// (`widthMajor` factors in the touch-position-vs-center distance) but are
/// not surfaced by `TouchContact`, which only carries `contactArea`/
/// `contactMinor`. Deliberately not threaded further until there is a real
/// consumer (palm rejection, orientation-aware gestures) and a capture to
/// verify the derivation against — adding fields to `TouchContact`
/// speculatively would be scope creep past what this pass needs.
public struct Wacom24HDTDecoder: TabletReportDecoder {

    public init() {}

    public func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard length >= 62, report[0] == 0x01 else { return [] }
        return decodeMultitouchReport(report: report, length: length, state: &state)
    }

    // MARK: - 0x01 multitouch report

    private static let recordSize = 14
    private static let recordsPerPacket = 4
    private static let recordsBase = 1
    private static let frameCountOffset = 61
    /// Highest plausible contact count for this hardware family (kernel
    /// documents a 10-finger ceiling). A byte-61 value above this on real
    /// hardware means the byte is garbage, not a legitimate huge frame —
    /// clamping keeps a corrupt report from accumulating unbounded state
    /// across many packets before the next reset.
    private static let maxPlausibleContacts = 10

    private func decodeMultitouchReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        state: inout DecoderState
    ) -> [DecodeResult] {
        let frameCount = min(Int(report[Self.frameCountOffset]), Self.maxPlausibleContacts)

        // A nonzero count starts a new frame. Per the kernel, this is not a
        // "how many more are coming" delta — it is the frame's total, so a
        // fresh nonzero value always resets any accumulation in progress
        // rather than adding to it. Guards against a truncated prior frame
        // (e.g. a dropped packet) wedging the accumulator permanently.
        if frameCount > 0 {
            state.wacom24HDTPendingContacts = []
            state.wacom24HDTRemainingContacts = frameCount
        }

        guard state.wacom24HDTRemainingContacts > 0 else {
            // Every finger lifted. Emit an empty frame, not nothing: the
            // kernel syncs a frame on every packet including this one, and
            // nothing downstream times contacts out, so returning `[]` left
            // the last contacts latched until the next touch.
            // `Wacom27QHDTDecoder` always did this; the 24HDT path was brought
            // in line 2026-09-10. (0x02/0x03 never reach here — `decode(...)`
            // gates on report[0] == 0x01.)
            return [.touch([])]
        }

        let recordsThisPacket = min(Self.recordsPerPacket, state.wacom24HDTRemainingContacts)
        for slot in 0 ..< recordsThisPacket {
            let base = Self.recordsBase + slot * Self.recordSize
            guard base + Self.recordSize <= length else { break }
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

    /// Decodes one 14-byte contact record starting at `base` within `report`.
    /// Returns `nil` for an inactive slot (status bit 0 clear) — per the
    /// kernel, an inactive record should release its tracking ID rather than
    /// silently vanish, so callers that need release semantics must diff
    /// against the previous frame's contact IDs themselves; this decoder
    /// only reports what is currently active, matching how `IntuosV2Decoder`
    /// /`BPT3ContainerDecoder`'s touch paths already work.
    private func decodeContactRecord(
        report: UnsafePointer<UInt8>,
        base: Int
    ) -> TouchContact? {
        let status = report[base]
        guard (status & 0x01) != 0 else { return nil }

        let id = Int(report[base + 1])
        let x = Int(report[base + 2]) | (Int(report[base + 3]) << 8)
        let y = Int(report[base + 6]) | (Int(report[base + 7]) << 8)
        let width = Int(report[base + 10]) | (Int(report[base + 11]) << 8)
        let height = Int(report[base + 12]) | (Int(report[base + 13]) << 8)

        // Kernel derives touchMajor/touchMinor as min(width, height) rather
        // than surfacing the two axes separately.
        let major = min(width, height)
        return TouchContact(id: id, x: x, y: y, contactArea: major, contactMinor: major)
    }
}
