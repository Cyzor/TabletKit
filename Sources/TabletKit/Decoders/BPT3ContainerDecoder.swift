// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the 64-byte BPT3 container (Report ID 0x02) — kernel
/// `wacom_bpt3_touch()`.
///
/// This container is **shared across two device generations that use different
/// pen formats**, which is why it lives here rather than inside either pen
/// decoder:
///
/// | | INTUOSHT (2013) | INTUOSHT2 (2015) |
/// |---|---|---|
/// | models | CTH-480/680, CTL-480/680 | CTH-490/690, CTL-490/690 |
/// | pen report | ID 0x02, 10 bytes, LE16 (`BambooDecoder.decodeBPT`) | ID 0x10, 10 bytes, BE16 (`IntuosV1Decoder`) |
/// | this container | ID 0x02, 64 bytes — identical | ID 0x02, 64 bytes — identical |
///
/// On INTUOSHT the pen report and this container share ID 0x02, so callers
/// dispatch on length (10 vs 64), not report ID alone.
///
/// Layout: [0]=0x02, [1] bits 2:0 = message count, then up to 7 fixed
/// 8-byte messages starting at offset 2:
/// ```
/// msg[0] 2–17   finger slot key        msg[0] 0x80   pad buttons
/// Touch msg: [1] bit7 = contact down
///            X = msg[2]<<4 | msg[4]>>4    (12-bit, 0–4095)
///            Y = msg[3]<<4 | msg[4]&0x0F  (12-bit, 0–4095)
///            [5] = width, [6] = height
/// Pad msg:   [1] bits 0x01/0x02/0x04/0x08 = express keys
///            (physical key ordering unverified — captures show the four
///            bits firing but not which physical key is which)
/// ```
///
/// Containers carry only changed contacts, so the caller keeps the slots
/// across reports and the full active set goes out each time.
///
/// Pen/touch arbitration isn't done here: a decoder-level gate killed touch
/// whenever a pen hovered weakly nearby. Every contact goes out and the
/// app decides.
///
/// Touch is gated on `spec.hasFingerTouch` and the pad on
/// `spec.buttonCount > 0`, separately: the pen-only CTL-480/680 have four
/// express keys but no touch sensor.
enum BPT3ContainerDecoder {

    /// Length of the container report. Callers dispatch on this.
    static let reportLength: CFIndex = 64

    /// Slot keys are wire message IDs, 2...17 — the mask's bit 0 is slot 2.
    private static func slotIsDown(_ slot: Int, in mask: UInt16) -> Bool {
        let bit = slot - 2
        guard (0..<16).contains(bit) else { return false }
        return (mask >> UInt16(bit)) & 1 == 1
    }

    static func decode(
        report: HIDReport,
        spec: DigitizerSpec,
        slots: inout [Int: TouchContact]
    ) -> [DecodeResult] {
        var results: [DecodeResult] = []
        var touchChanged = false

        // Liftoff bitmap: message ID 0x81 means bytes [3..4] are a 16-bit
        // mask of the slots still down, not a contact list. Without it a
        // contact's end can go unheard and stay latched for the session.
        // Matches OpenTabletDriver's `WacomTouchReport`.
        if report[2] == 0x81 {
            guard spec.hasFingerTouch else { return [] }
            let mask = UInt16(report.le16(at: 3))
            // Collect first — can't remove while iterating.
            let ended = slots.keys.filter { !slotIsDown($0, in: mask) }
            for slot in ended {
                slots.removeValue(forKey: slot)
                touchChanged = true
            }
            guard touchChanged else { return [] }
            return [.touch(slots.values.sorted { $0.id < $1.id })]
        }

        let messageCount = min(Int(report[1] & 0x07), 7)

        for i in 0..<messageCount {
            let base = 2 + i * 8
            let msgID = Int(report[base])
            if (2...17).contains(msgID) {
                guard spec.hasFingerTouch else { continue }
                let down = (report[base + 1] & 0x80) != 0
                if down {
                    let x = (Int(report[base + 2]) << 4) | (Int(report[base + 4]) >> 4)
                    let y = (Int(report[base + 3]) << 4) | (Int(report[base + 4]) & 0x0F)
                    // Width/height arrive as raw bytes; pass the larger one so
                    // contactArea stays on the same scale as IntuosV2's major byte.
                    let area = Int(max(report[base + 5], report[base + 6]))
                    slots[msgID] = TouchContact(
                        id: msgID, x: x, y: y, contactArea: area)
                } else {
                    slots.removeValue(forKey: msgID)
                }
                touchChanged = true
            } else if msgID == 0x80 && spec.buttonCount > 0 {
                let padByte = report[base + 1]
                results.append(
                    .aux(
                        AuxButtons(buttons: [
                            (padByte & 0x01) != 0,
                            (padByte & 0x02) != 0,
                            (padByte & 0x04) != 0,
                            (padByte & 0x08) != 0,
                        ])))
            }
        }

        if touchChanged {
            results.append(.touch(slots.values.sorted { $0.id < $1.id }))
        }
        return results
    }
}
