// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Per-finger field group within one multitouch input report.
///
/// Every field is optional except `x`/`y` — the HID Digitizer usage set makes
/// almost everything else discretionary, and real descriptors exercise that
/// freedom (the DTH-2420's report `0x88` variant carries a Tip Switch but no
/// Contact Identifier, for instance).
public struct PrecisionTouchSlot: Equatable {
    /// Digitizer Tip Switch (`0x0D`/`0x42`) — finger present. Absent on some
    /// single-contact reports, where `PrecisionTouchDecoder` falls back to the
    /// report's Contact Count.
    public var tipSwitch: DescriptorField?
    /// Digitizer Contact Identifier (`0x0D`/`0x51`) — the firmware's tracking
    /// id for this finger, stable across frames. When absent the decoder uses
    /// the slot index, which is stable for the same reason.
    public var contactID: DescriptorField?
    /// Generic Desktop X (`0x01`/`0x30`).
    public var x: DescriptorField
    /// Generic Desktop Y (`0x01`/`0x31`).
    public var y: DescriptorField
    /// Digitizer Width (`0x0D`/`0x48`) — contact-major axis, when reported.
    public var width: DescriptorField?
    /// Digitizer Height (`0x0D`/`0x49`) — contact-minor axis, when reported.
    public var height: DescriptorField?
}

/// A HID Precision-Touchpad-style multitouch input report, described entirely
/// by the device's own report descriptor.
///
/// This is the touch counterpart to `GenericDigitizerFrame`: vendor-neutral,
/// no IOKit, and derived rather than hardcoded. Where the pen path can read
/// IOKit element *values*, touch cannot — a multitouch report repeats the same
/// usages once per finger, and IOKit's element list gives no way to tell which
/// repetition a value came from. That is precisely the gap
/// `HIDReportDescriptorParser` exists to fill, so this type is built from
/// parsed bit offsets and the decoder consumes raw report bytes. Anyone
/// tempted to "simplify" this back onto element callbacks should read that
/// sentence twice.
///
/// Known limitation, deliberate: only single-report frames are supported. Some
/// devices declare fewer physical slots than their maximum contact count and
/// split one frame across consecutive reports, correlated by Scan Time. No
/// descriptor or capture available to this project exercises that path, so it
/// is not implemented rather than guessed at — `scanTime` is exposed so a
/// future reassembly layer has the field it would need.
public struct PrecisionTouchLayout: Equatable {

    /// HID usages this layout recognizes, as `(page << 16) | usage`.
    public enum Usage {
        /// Generic Desktop X.
        public static let x: UInt32 = 0x0001_0030
        /// Generic Desktop Y.
        public static let y: UInt32 = 0x0001_0031
        /// Digitizer Tip Switch.
        public static let tipSwitch: UInt32 = 0x000D_0042
        /// Digitizer Contact Identifier.
        public static let contactID: UInt32 = 0x000D_0051
        /// Digitizer Width (contact major).
        public static let width: UInt32 = 0x000D_0048
        /// Digitizer Height (contact minor).
        public static let height: UInt32 = 0x000D_0049
        /// Digitizer Contact Count — how many slots of this frame are live.
        public static let contactCount: UInt32 = 0x000D_0054
        /// Digitizer Scan Time (100 µs units).
        public static let scanTime: UInt32 = 0x000D_0056

        /// Digitizer Touch Screen application collection.
        public static let touchScreenCollection: UInt32 = 0x000D_0004
        /// Digitizer Touch Pad application collection.
        public static let touchPadCollection: UInt32 = 0x000D_0005
    }

    /// Report ID this layout decodes.
    public let reportID: UInt8
    /// Payload size in bytes, *excluding* the leading report-ID byte.
    public let payloadBytes: Int
    /// Finger slots in report order.
    public let slots: [PrecisionTouchSlot]
    /// Digitizer Contact Count, when the report declares one.
    public let contactCount: DescriptorField?
    /// Digitizer Scan Time, when the report declares one.
    public let scanTime: DescriptorField?

    /// Declared logical maximum of the X axis, in device touch units.
    ///
    /// Preferred over a registry `touchMaxX` where both exist: this comes from
    /// the device describing itself, which is strictly better provenance than
    /// a transcribed table value.
    public let logicalMaxX: Int
    /// Declared logical maximum of the Y axis, in device touch units.
    public let logicalMaxY: Int

    /// Derives every multitouch input report the descriptor declares, in
    /// report-ID order.
    ///
    /// A report qualifies when its fields sit inside a Digitizer Touch Screen
    /// or Touch Pad application collection *and* it yields at least one slot
    /// carrying both X and Y. The collection gate is what keeps ordinary pen
    /// digitizer reports — which also carry Generic Desktop X/Y and a Tip
    /// Switch — from being mistaken for touch.
    ///
    /// Returns multiple layouts when a device declares several (the DTH-2420
    /// declares a 10-finger report `0x81` and a single-contact `0x88`). Callers
    /// pick; the richest is normally the one with the most slots.
    public static func derive(from layout: DescriptorLayout) -> [PrecisionTouchLayout] {
        layout.reports
            .filter { $0.direction == .input }
            .sorted { $0.reportID < $1.reportID }
            .compactMap { derive(from: $0) }
    }

    /// Derives a layout from a single report, or `nil` when it is not a
    /// multitouch report.
    public static func derive(from report: DescriptorReport) -> PrecisionTouchLayout? {
        // Ordered by bit offset because that — not the collection path — is
        // what separates finger 0 from finger 1. Every finger collection in a
        // real descriptor carries an identical path (`Touch Screen` → `Finger`),
        // so the path can tell us *whether* this is touch but never *which*
        // finger; only report order can.
        let fields = report.fields
            .filter { !$0.isConstant && $0.isVariable }
            .sorted { $0.bitOffset < $1.bitOffset }

        var slots: [PrecisionTouchSlot] = []
        var contactCount: DescriptorField?
        var scanTime: DescriptorField?
        var sawTouchCollection = false

        // Partial slot under construction. A new slot starts whenever a usage
        // repeats, which is what a fresh finger collection looks like in the
        // flattened field list.
        var tipSwitch: DescriptorField?
        var contactID: DescriptorField?
        var x: DescriptorField?
        var y: DescriptorField?
        var width: DescriptorField?
        var height: DescriptorField?

        func flush() {
            if let x, let y {
                slots.append(PrecisionTouchSlot(
                    tipSwitch: tipSwitch, contactID: contactID,
                    x: x, y: y, width: width, height: height))
            }
            tipSwitch = nil; contactID = nil; x = nil; y = nil
            width = nil; height = nil
        }

        for field in fields {
            if field.collectionPath.contains(Usage.touchScreenCollection)
                || field.collectionPath.contains(Usage.touchPadCollection) {
                sawTouchCollection = true
            }

            switch field.extendedUsage {
            // Per-frame trailer fields. Taken once — a well-formed report
            // declares each at most once, and a malformed one gets the first.
            case Usage.contactCount:
                if contactCount == nil { contactCount = field }
            case Usage.scanTime:
                if scanTime == nil { scanTime = field }

            case Usage.x:
                if x != nil { flush() }
                x = field
            case Usage.y:
                if y != nil { flush() }
                y = field
            case Usage.tipSwitch:
                if tipSwitch != nil { flush() }
                tipSwitch = field
            case Usage.contactID:
                if contactID != nil { flush() }
                contactID = field
            case Usage.width:
                if width != nil { flush() }
                width = field
            case Usage.height:
                if height != nil { flush() }
                height = field

            // Anything else (Confidence, Azimuth, Tip Pressure, vendor fields)
            // is left alone: unrecognized usages must not split a slot, or a
            // device that interleaves an extra field per finger would produce
            // twice as many half-formed slots.
            default:
                continue
            }
        }
        flush()

        guard sawTouchCollection, !slots.isEmpty else { return nil }

        // Fail closed on a malformed multi-slot report. Tip Switch is mandatory
        // in the HID Precision Touchpad spec; without it, and without a Contact
        // Count to fall back on, the decoder has no way to tell a live finger
        // from an empty slot and would emit a phantom contact per slot on every
        // frame. A single-slot report is exempt — it can legitimately mean
        // "one contact, position only".
        if slots.count > 1 && contactCount == nil
            && slots.contains(where: { $0.tipSwitch == nil }) {
            return nil
        }

        // Axis maxima come from the first slot; all slots describe the same
        // physical sensor, so they agree by construction.
        return PrecisionTouchLayout(
            reportID: report.reportID,
            payloadBytes: (report.totalBits + 7) / 8,
            slots: slots,
            contactCount: contactCount,
            scanTime: scanTime,
            logicalMaxX: slots[0].x.logicalMax,
            logicalMaxY: slots[0].y.logicalMax)
    }
}

/// One decoded multitouch frame.
public struct PrecisionTouchFrame: Equatable {
    /// Contacts currently down, in report-slot order. Empty means "all fingers
    /// lifted" — the same signal `DecodeResult.touch([])` carries.
    ///
    /// Lifting fingers are excluded: HID reports a finger's final position with
    /// Tip Switch already clear, and passing those on would leave a phantom
    /// contact one frame past the lift.
    public let contacts: [TouchContact]

    /// The report's own Contact Count, when it declares one. Advisory: the
    /// decoder trusts Tip Switch, not this.
    public let reportedContactCount: Int?

    /// Digitizer Scan Time in 100 µs units, when declared. Not used for
    /// anything yet; carried so frame-reassembly or latency work has it.
    public let scanTime: Int?

    /// True when `reportedContactCount` disagrees with the number of contacts
    /// whose Tip Switch is set. Diagnostic only — a mismatch is not a reason to
    /// drop or truncate a frame, and callers that log it should rate-limit.
    public var contactCountMismatch: Bool {
        guard let reportedContactCount else { return false }
        return reportedContactCount != contacts.count
    }
}

/// Decodes HID Precision-Touchpad-style multitouch reports against a
/// descriptor-derived `PrecisionTouchLayout`.
///
/// Coordinates come out in raw device touch units, bounded by the layout's
/// `logicalMaxX`/`logicalMaxY` — the same space `InputInjector.injectTouch`
/// expects, so no scaling happens here.
///
/// Deliberately more conservative than the sample implementations this was
/// checked against: every declared slot is examined and filtered on Tip
/// Switch, rather than reading the first *n* slots named by Contact Count and
/// stopping at a sentinel byte. Packing live contacts contiguously at the
/// front is firmware behavior, not something HID guarantees, and a device that
/// reports finger 3 while fingers 0–2 are up would lose the contact entirely
/// under the contiguous assumption.
public struct PrecisionTouchDecoder {

    public let layout: PrecisionTouchLayout

    public init(layout: PrecisionTouchLayout) {
        self.layout = layout
    }

    /// Decodes one raw input report.
    ///
    /// - Parameter report: Full report bytes *including* the leading report-ID
    ///   byte at index 0, exactly as IOKit's input-report callback delivers it.
    /// - Returns: The frame, or `nil` when the report is not this layout's
    ///   report ID or is too short to hold the declared payload.
    public func decode(report: [UInt8]) -> PrecisionTouchFrame? {
        guard report.count > layout.payloadBytes,
              report[0] == layout.reportID
        else { return nil }

        // `DescriptorField.bitOffset` is relative to the first byte after the
        // report ID, so the ID byte is dropped before any extraction.
        let payload = Array(report.dropFirst())

        let reported = layout.contactCount.map { extractField($0, from: payload) }
        let scanTime = layout.scanTime.map { extractField($0, from: payload) }

        var contacts: [TouchContact] = []
        contacts.reserveCapacity(layout.slots.count)

        for (index, slot) in layout.slots.enumerated() {
            // Tip Switch is authoritative when present. Without one, fall back
            // to Contact Count covering this slot — the only reading available
            // on a report that declares neither (e.g. a single-contact variant
            // that relies on position alone).
            let down: Bool
            if let tip = slot.tipSwitch {
                down = extractField(tip, from: payload) != 0
            } else if let reported {
                down = index < reported
            } else {
                down = true
            }
            guard down else { continue }

            // Contact Identifier's declared logical maximum is not trustworthy
            // — the DTH-2420 declares `[0..1]` on an 8-bit field — so the raw
            // extracted value is used as an opaque tracking id, never as a
            // bounded index.
            let id = slot.contactID.map { extractField($0, from: payload) } ?? index

            // Contact area: report the major axis where the device gives one.
            // `TouchContact.contactArea` is a single scalar, and width is the
            // conventional major axis in the Digitizer usage set.
            let area = slot.width.map { extractField($0, from: payload) }

            contacts.append(TouchContact(
                id: id,
                x: extractField(slot.x, from: payload),
                y: extractField(slot.y, from: payload),
                contactArea: area))
        }

        return PrecisionTouchFrame(
            contacts: contacts,
            reportedContactCount: reported,
            scanTime: scanTime)
    }
}
