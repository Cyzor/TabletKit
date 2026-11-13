// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 TabletKit contributors
// SPDX-License-Identifier: MPL-2.0

import Foundation

// MARK: - Report protocol family

/// Which HID report decoder handles this device family.
///
/// Used by `WacomDeviceRegistry` to route devices to the correct decoder.
public enum ReportFormat: String, Sendable {
    /// Graphire / early consumer line — Report ID 0x02
    /// (kernel `WACOM_REPORT_PENABLED`), 8 bytes.
    /// Covers PenPartner, Graphire 2–4, Volito, Bamboo One (CTF-430).
    /// No tool-change packets; eraser/pen/mouse detected via the tool field
    /// in status byte d[1] bits 5–6. Decoded by `GraphireDecoder`.
    case graphire

    /// IntuosV1 — Report ID 0x02/0x10, 10 bytes, BE16 coordinates.
    /// Covers Intuos 1–2, Intuos4 (PTK-xxx), Intuos5 (PTH-xxx first gen),
    /// and Cintiq pen-displays. Despite the similar byte layout, Intuos3
    /// (PTZ-xxx) is routed through the separate `.intuos3` case below —
    /// its status-byte proximity bit is incompatible (see `Intuos3Decoder`).
    /// Tool-change packets: status `(& 0xFC) == 0xC0`.
    /// 10–12 bit pressure depending on generation.
    case intuosV1

    /// IntuosV2 — Report ID 0x10, 192 bytes, LE24 coordinates, 13-bit pressure.
    /// Covers Intuos Pro second-generation (PTH-460/660/860) and newer.
    /// Also used over BLE HOGP (Report ID 0x01 pen, 0x03 pad).
    case intuosV2

    /// IntuosV3 — pen on Report ID 0x1E (24-bit XY) over USB and 0x1A over
    /// Bluetooth LE, with 0x11 aux carrying 8 keys, 2 cluster-center keys,
    /// and two dials. Covers the PTK-470/670/870 Intuos Pro and the Movink
    /// 13 (OTD's `IntuosV3ReportParser`). See `IntuosV3Decoder`.
    case intuosV3

    /// DTUS — small entry-level Cintiq / DTU pen displays. Pen report at
    /// ID 0x11 (7 bytes, BE16 coordinates, 10-bit pressure split across
    /// status byte and pressure byte); pad report at ID 0x15 (4 buttons in
    /// the low nibble of one byte). No tilt, no rotation, no hover. Covers
    /// DTK-1651 (0x0343), DTU-1031 (0x00FB), DTU-1031X (0x032F), DTU-1141
    /// (0x0336). Not yet validated on hardware.
    case dtus

    /// DTU — Wacom DTU pen-display family using the WACOM_REPORT_PENABLED
    /// (0x02) report format parsed by `wacom_dtu_irq`. Single pen report,
    /// 8 bytes: LE16 X/Y, 9-bit pressure, eraser inferred from tool-type
    /// bits. No pad buttons, no tilt. Covers DTU-1631 (0x00F0), DTU-2231
    /// (0x00CE), and Cintiq Partner (0x0003). Not yet validated on hardware.
    case dtu

    /// Bamboo — pen on Report ID 0x02, LE16 coordinates, with touch and pad
    /// in the BPT3 container. Covers Bamboo Pen & Touch, Craft, Comic, and
    /// Fun (CTL/CTH-xxx), and the INTUOSHT models. See `BambooDecoder`.
    case bamboo

    /// Intuos3 (PTZ-xxx, 2003–2006) — the 10-byte IntuosV1 payload, but
    /// frames with bit 6 clear still carry data. Aux reports use IDs
    /// 0x03/0x0C, not 0x11. Two-stage feature init (see
    /// `TabletSpec.initSteps`). See `Intuos3Decoder`.
    case intuos3

    /// CintiqV1 — Wacom Cintiq pen-display family using the IntuosV1 10-byte pen
    /// report layout (same as PTH-851) plus a 0x0C aux report for touch rings and
    /// express keys, and a 0x01 tip-switch report.
    /// Decoded by `CintiqV1Decoder` which handles the WACOM_24HD typeNibble dispatch,
    /// ABS_Z Art Pen rotation, barrel-button debounce, dual-ring 0x0C layout,
    /// tip-switch synthetic pressure, and incompatible-tool suppression.
    case cintiqV1

    /// Xencelabs Pen Tablet (VID 0x28BD) — 10-byte pen report dispatched on
    /// byte-1 flags, XP-Pen-shaped aux report.  The only non-Wacom parser;
    /// specs come from `VendorDeviceRegistry`, not this registry. Requires
    /// the `[0x02, 0xB0, 0x04]` output-report init. Decoded by
    /// `XencelabsDecoder`.
    case xencelabs

    /// Huion, Gaomon, XP-Pen, UGEE, and Parblo tablets, whose ranges come from
    /// the tablet when it's switched on (see `UCLogicTabletInfo`). Decoded by
    /// `UCLogicDecoder`.
    case ucLogic

    /// ExpressKey Remote (EKR-100, PID 0x0331) — standalone wireless
    /// button/ring accessory, no digitizer. Report ID 0x11, 32 bytes, opaque
    /// vendor collection (usage page 0xFF0C, no field-level HID descriptor).
    /// Decoded by `ExpressKeyRemoteDecoder`, from the kernel's
    /// `wacom_remote_irq`.
    case expressKeyRemote

    /// PL — Wacom's "PL" report family (`WACOM_REPORT_PENABLED`, Report ID
    /// 0x02, 8 bytes). Covers the PL-400 through PL-800 LCD pen displays
    /// (1998–2005), the direct ancestors of the Cintiq line — PL-550/PL-800
    /// are literally the Cintiq 15X/18SX under their internal model
    /// numbers. Ported from the kernel's `wacom_pl_irq()`; decoded by
    /// `WacomPLDecoder`. OpenTabletDriver has tested the PL-800 on hardware;
    /// the other seven PIDs are untested.
    case pl

    /// A tablet the registry doesn't know, read from its own report
    /// descriptor by `DescriptorPenDecoder`: any standard HID pen
    /// digitizer. Pen only; no buttons, rings, or touch.
    case descriptor
}

extension ReportFormat {
    func decoder() -> any TabletReportDecoder {
        switch self {
        case .graphire: return GraphireDecoder()
        case .intuosV1: return IntuosV1Decoder()
        case .intuosV2: return IntuosV2Decoder()
        case .intuosV3: return IntuosV3Decoder()
        case .dtus: return DTUSDecoder()
        case .dtu: return DTUDecoder()
        case .bamboo: return BambooDecoder()
        case .intuos3: return Intuos3Decoder()
        case .cintiqV1: return CintiqV1Decoder()
        case .xencelabs: return XencelabsDecoder()
        case .ucLogic: return UCLogicDecoder()
        case .expressKeyRemote: return ExpressKeyRemoteDecoder()
        case .pl: return WacomPLDecoder()
        case .descriptor: return DescriptorPenDecoder()
        }
    }

    /// Whether this format's decoder handles reports with this ID, including
    /// ones it reads and deliberately ignores. A report that decodes to no
    /// events is then either known with nothing to say, or unknown.
    ///
    /// `nil` for formats that don't list their IDs yet.
    public func reads(reportID: UInt8) -> Bool? {
        switch self {
        case .intuosV2: IntuosV2Decoder.reportIDs.contains(reportID)
        default: nil
        }
    }
}
