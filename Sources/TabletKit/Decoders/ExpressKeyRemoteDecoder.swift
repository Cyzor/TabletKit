// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom ExpressKey Remote (EKR-100, VID 0x056A PID 0x0331)
/// — a standalone wireless button/ring accessory, no digitizer of its own.
/// Closest Wacom equivalent to the Xencelabs Quick Keys puck: 17 programmable
/// keys plus a Touch Ring with its own center mode button (18 controls
/// total), 3 selectable ring modes with onboard LEDs, battery status. No
/// host-controllable LED — the remote's own firmware owns which of the 3
/// modes is lit; the host only ever reads which one is active, same as
/// libwacom documents.
///
/// Both input reports are 32 bytes on an opaque vendor collection (usage
/// page 0xFF0C) — the descriptor declares no field layout, so everything
/// below comes from Linux's `wacom_remote_irq` (`drivers/hid/wacom_wac.c`,
/// mainline, checked 2026-09-19). No independent hardware of this project's
/// own has caught a live button press yet, so the kernel source is the most
/// trustworthy reference on hand.
///
/// Report 0x11 (remote event), relevant bytes after the report ID:
///   [3–5]  serial number, 24-bit LE (`data[3] | data[4]<<8 | data[5]<<16`)
///   [7]    battery: bits 0–6 percent (0–100), bit 7 charging
///   [9]    buttons 0–7 (bit N = key N+1)
///   [10]   buttons 8–15
///   [11]   bits 0–1 = buttons 16–17, two ordinary numbered buttons (kernel
///          `BTN_BASE`/`BTN_BASE2`) — not a dedicated ring-center button as
///          once assumed; a capture isolating one button press shows byte 9
///          bit 0 going high instead. All 18 buttons decode the same way.
///          bits 6–7 = active Touch Ring mode (0–2), a persistent state
///          field, not a per-event flag — `(byte & 0xC0) >> 6`, matching the
///          kernel's own "which mode select (LED light) is currently on".
///   [12]   Touch Ring: bit 7 = touched, bits 0–6 = position + 1 when
///          touched. Kernel does `(data[12] & 0x7f) - 1` since the wire is
///          1-indexed, giving 0–71 (72 positions, 5° resolution). Idle
///          sentinel is `0x7F`, matching every other ring decoder in this
///          codebase and what `InputInjector+AuxInput.swift` expects.
///
/// Report 0x10 (receiver/pairing status — up to 5 paired remotes' serials)
/// and output report 0x20 (pairing removal) are not decoded here: MockTab
/// has no concept of multiple simultaneously paired accessories on one
/// connection today, and building that is a separate, larger task than this
/// decoder. The 0x11 frame's own embedded serial (bytes 3–5) and active
/// ring mode (byte 11 bits 6–7) aren't surfaced either — nothing downstream
/// consumes per-remote identity or a read-only mode indicator yet; add them
/// when a caller actually needs to.
public struct ExpressKeyRemoteDecoder: TabletReportDecoder {

    static let remoteReportID: UInt8 = 0x11

    public init() {}

    public mutating func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard length >= 13, report[0] == Self.remoteReportID else { return [] }

        let batteryByte = report[7]
        let batteryPercent = Int(batteryByte & 0x7F)
        let charging = batteryByte & 0x80 != 0

        var buttons = [Bool](repeating: false, count: 18)
        for bit in 0..<8 { buttons[bit] = report[9] & (1 << UInt8(bit)) != 0 }
        for bit in 0..<8 { buttons[8 + bit] = report[10] & (1 << UInt8(bit)) != 0 }
        buttons[16] = report[11] & 0x01 != 0
        buttons[17] = report[11] & 0x02 != 0

        let ringByte = report[12]
        let ringActive = ringByte & 0x80 != 0
        let ringPosition = ringActive ? (ringByte & 0x7F) &- 1 : 0x7F

        var results: [DecodeResult] = [
            .aux(AuxButtons(
                buttons: buttons,
                touchRingActive: ringActive,
                touchRingPosition: ringPosition))
        ]

        // Only emit battery when it actually changed — this report streams
        // continuously while the remote is in range, and every other
        // decoder's battery path (see DecoderState.lastBatteryByte) dedupes
        // the same way to avoid flooding the host with redundant updates.
        if state.lastBatteryByte != batteryByte {
            state.lastBatteryByte = batteryByte
            results.append(.battery(percent: batteryPercent, charging: charging))
        }

        return results
    }
}
