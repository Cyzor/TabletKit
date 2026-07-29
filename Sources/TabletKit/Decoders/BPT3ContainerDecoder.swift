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
/// Confirmed identical across both generations 2026-07-29: our own CTH-690
/// (0x033E) discovery capture and INTUOSHT captures of 0x0302/0x0323 show the
/// same message IDs and the same four-bit pad bitmap in the low nibble.
///
/// Note the report-ID collision *within* INTUOSHT: pen and container both use
/// ID 0x02 and are told apart only by length (10 vs 64). Callers must dispatch
/// on length, not report ID alone.
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
/// Containers carry only *changed* contacts, so slot state persists in
/// `DecoderState` across reports and the full active set is re-emitted
/// each time. Touch is suppressed while the pen is in proximity (kernel
/// touch-arbitration behavior); pen entry releases all active contacts.
///
/// Touch decoding is gated on `spec.hasFingerTouch` and pad decoding on
/// `spec.buttonCount > 0`, independently — the pen-only CTL-480/680 have four
/// express keys but no touch sensor, and would lose their pad if entry to this
/// decoder were gated on touch capability.
enum BPT3ContainerDecoder {

    /// Length of the container report. Callers dispatch on this.
    static let reportLength: CFIndex = 64

    static func decode(
        report: UnsafePointer<UInt8>,
        spec: DigitizerSpec,
        state: inout DecoderState
    ) -> [DecodeResult] {
        let messageCount = min(Int(report[1] & 0x07), 7)
        var results: [DecodeResult] = []
        var touchChanged = false

        for i in 0..<messageCount {
            let base = 2 + i * 8
            let msgID = Int(report[base])
            if (2...17).contains(msgID) {
                guard spec.hasFingerTouch else { continue }
                let down = (report[base + 1] & 0x80) != 0 && !state.prevInProximity
                if down {
                    let x = (Int(report[base + 2]) << 4) | (Int(report[base + 4]) >> 4)
                    let y = (Int(report[base + 3]) << 4) | (Int(report[base + 4]) & 0x0F)
                    // Width/height arrive as raw bytes; pass the larger one so
                    // contactArea stays on the same scale as IntuosV2's major byte.
                    let area = Int(max(report[base + 5], report[base + 6]))
                    state.bpt3TouchSlots[msgID] = TouchContact(
                        id: msgID, x: x, y: y, contactArea: area)
                } else {
                    state.bpt3TouchSlots.removeValue(forKey: msgID)
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

        // Pen proximity releases every tracked contact, even in containers
        // that carry no touch messages of their own.
        if state.prevInProximity && !state.bpt3TouchSlots.isEmpty {
            state.bpt3TouchSlots.removeAll()
            touchChanged = true
        }

        if touchChanged {
            results.append(.touch(state.bpt3TouchSlots.values.sorted { $0.id < $1.id }))
        }
        return results
    }
}
