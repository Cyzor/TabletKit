// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom ExpressKey Remote (EKR-100, PID 0x0331), a wireless
/// accessory with 17 keys and a Touch Ring with a center mode button, three
/// ring modes with LEDs, and a battery. The remote's firmware owns the mode
/// LEDs; the host only reads which mode is active.
///
/// Both reports are 32 bytes on an opaque vendor collection (page 0xFF0C),
/// so the layouts come from the kernel's `wacom_remote_irq` and
/// `wacom_remote_status_irq`.
///
/// Report 0x11 (remote event), after the report ID:
///   [3–5]  serial, 24-bit LE (not read)
///   [7]    battery: bits 0–6 percent, bit 7 charging
///   [9]    bit 0 = ring center (mode) button; bits 1–7 = keys 1–7
///   [10]   keys 8–15
///   [11]   bits 0–1 = keys 16–17; bits 6–7 = active ring mode (0–2), a
///          persistent state, emitted as `touchRingHardwareMode`
///   [12]   Touch Ring: bit 7 = touched, bits 0–6 = position + 1, so
///          0–71 after the kernel's `- 1`. Idle is `0x7F`, as for every
///          other ring.
///
/// Keys 1–17 come out as `buttons[0...16]`, the center button as
/// `touchRingButtonDown`; the center press is the one that changes the mode.
///
/// Report 0x10 (receiver pairing table), for diagnostics: five 6-byte slots,
/// slot `i` at `j = i * 6`, with that remote's 24-bit LE serial at
/// [j+4...6]. A slot is occupied iff its serial is nonzero; the kernel reads
/// nothing else. The table separates "paired but silent" from "not paired",
/// which look the same in 0x11 traffic, but it's the stored enrollment list
/// and says nothing about whether the link is live.
///
/// Output report 0x20 (unpair) isn't implemented; it's destructive and
/// nothing needs it.
package struct ExpressKeyRemoteDecoder: TabletReportDecoder {

    static let remoteReportID: UInt8 = 0x11
    static let deviceListReportID: UInt8 = 0x10

    /// From the kernel: `WACOM_MAX_REMOTES`, and its `j = i * 6`.
    static let maxRemotes = 5
    static let pairingSlotStride = 6

    /// Creates a decoder. ``DeviceDecoder`` keeps one per device, with its state.
    public init() {}

    /// Decodes one report. See ``TabletReportDecoder/decode(report:spec:state:deviceFamily:)``.
    public mutating func decode(
        report: HIDReport,
        spec: DigitizerSpec,
        state: inout State,
        deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        guard report.count >= 1 else { return [] }

        if report[0] == Self.deviceListReportID {
            return Self.decodePairingTable(report: report)
        }

        guard report.count >= 13, report[0] == Self.remoteReportID else { return [] }

        let batteryByte = report[7]
        let batteryPercent = Int(batteryByte & 0x7F)
        let charging = batteryByte & 0x80 != 0

        // Wire bit 0 is the ring's center button, which switches ring modes;
        // a capture shows it firing as byte 11's mode field changes. Bits
        // 1–17 are keys 1–17, emitted as buttons 0–16.
        var raw = [Bool](repeating: false, count: 18)
        for bit in 0..<8 { raw[bit] = report[9] & (1 << UInt8(bit)) != 0 }
        for bit in 0..<8 { raw[8 + bit] = report[10] & (1 << UInt8(bit)) != 0 }
        raw[16] = report[11] & 0x01 != 0
        raw[17] = report[11] & 0x02 != 0

        let ringByte = report[12]
        let ringActive = ringByte & 0x80 != 0
        let ringPosition = ringActive ? (ringByte & 0x7F) &- 1 : 0x7F
        let mode = Int((report[11] & 0xC0) >> 6)

        var aux = AuxButtons(
            buttons: Array(raw[1...]),
            touchRingActive: ringActive,
            touchRingButtonDown: raw[0],
            touchRingPosition: ringPosition)
        aux.touchRingHardwareMode = mode < 3 ? mode : nil
        var results: [DecodeResult] = [.aux(aux)]

        // Only emit battery when it actually changed — this report streams
        // continuously while the remote is in range; the other battery
        // decoders dedupe the same way.
        if state.lastBatteryByte != batteryByte {
            state.lastBatteryByte = batteryByte
            results.append(.battery(percent: batteryPercent, charging: charging))
        }

        return results
    }

    /// Emits every slot, occupied or not, so a reader can tell "slot 3 is
    /// empty" from "the frame was short" — slots the frame can't hold are
    /// omitted rather than guessed.
    static func decodePairingTable(
        report: HIDReport
    ) -> [DecodeResult] {
        var slots: [RemotePairingSlot] = []
        slots.reserveCapacity(maxRemotes)

        for index in 0..<maxRemotes {
            let base = index * pairingSlotStride
            // Highest byte this slot reads is base+6; need it within the frame.
            guard base + 6 < report.count else { break }

            let serial = UInt32(report.le24(at: base + 4))

            slots.append(RemotePairingSlot(
                index: index,
                serial: serial,
                connected: serial != 0))
        }

        return slots.isEmpty ? [] : [.remotePairing(slots)]
    }
}

extension ExpressKeyRemoteDecoder {
    /// What this decoder remembers between reports.
    package struct State: DecoderState {
        /// Last battery byte, so unchanged readings aren't sent again. 0xFF until one arrives.
        package var lastBatteryByte: UInt8 = 0xFF

        package init() {}
    }
}
