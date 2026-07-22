// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

// MARK: - BLE HOGP Report Decoders

/// Decode a BLE HOGP pen report (Report ID 0x01, 23 bytes) common to all
/// Intuos Pro models (PTH-451/651/851, PTH-660/860) when connected via
/// Bluetooth Low Energy.
///
/// Layout (from Wacom-Wireless-Specification-Notes.md §4.5):
/// [0] 0x01 Report ID
/// [1] bits 0–3 = tool index; bit 4 = tip switch; bit 5 = barrel 1;
///     bit 6 = barrel 2; bit 7 = proximity
/// [2–3] X (LE uint16)
/// [4–5] Y (LE uint16)
/// [6–7] Pressure (LE uint16, 0–8191)
/// [8] Distance (uint8, 0–63)
/// [9] Tilt X (signed int8, −127..+127 = sin(angle))
/// [10] Tilt Y (signed int8)
/// [11–14] Tool serial (LE uint32)
/// [15–16] Tool ID (LE uint16)
/// [17–22] Reserved
///
/// Tilt encoding differs from USB: proportional to sin(angle), divide by 127
/// to get −1..+1 — same normalization we use for IntuosV2 USB.
public func decodeBLEPenReport(
    report: UnsafePointer<UInt8>,
    length: CFIndex,
    spec: DigitizerSpec,
    lastX: inout Int,
    lastY: inout Int
) -> BLEPenResult? {
    guard length >= 11 else { return nil }

    let flags = report[1]
    _ = (flags & 0x10) != 0  // tip switch — implicit in pressure > 0
    let barrel1 = (flags & 0x20) != 0
    let barrel2 = (flags & 0x40) != 0
    let inProximity = (flags & 0x80) != 0

    let x = Int(UInt16(report[2]) | UInt16(report[3]) << 8)
    let y = Int(UInt16(report[4]) | UInt16(report[5]) << 8)
    let pressure = Int(UInt16(report[6]) | (UInt16(report[7] & 0x1F) << 8))
    let distance = Int(report[8])
    let tiltX = Double(Int8(bitPattern: report[9])) / 127.0
    let tiltY = Double(Int8(bitPattern: report[10])) / 127.0

    let serial: UInt32 =
        length >= 15
        ? UInt32(report[11]) | UInt32(report[12]) << 8
            | UInt32(report[13]) << 16 | UInt32(report[14]) << 24
        : 0
    let toolCode: UInt16 =
        length >= 17
        ? UInt16(report[15]) | UInt16(report[16]) << 8
        : 0

    let isEraser = (toolCode & 0x0008) != 0
    let isMouse = (toolCode & 0x000F) == 0x0006

    if inProximity {
        lastX = x
        lastY = y
    }

    let point = TabletPoint(
        x: inProximity ? x : lastX,
        y: inProximity ? y : lastY,
        maxX: spec.maxX, maxY: spec.maxY,
        pressure: inProximity ? pressure : 0,
        maxPressure: spec.maxPressure,
        tiltX: tiltX, tiltY: tiltY, rotation: 0.0,
        penButton1: barrel1,
        penButton2: barrel2,
        eraser: isEraser,
        inProximity: inProximity,
        hoverDistance: distance)

    return BLEPenResult(point: point, serial: serial, toolCode: toolCode, isMouse: isMouse)
}

// MARK: - Intuos5 pad report (Report ID 0x03)

/// Decode the Intuos5-family pad/ring report (Report ID 0x03, 10 bytes).
/// Shared by USB, the ACK-40401 wireless dongle, and BLE — all three send
/// the identical layout on this device family.
///
/// Layout confirmed by two independent HID captures against a real PTH-850
/// (Intuos5 L), one direct USB and one relayed through the ACK-40401 dongle:
/// pressing express keys one at a time toggled exactly one bit at a time in
/// byte[4] (mirrored in byte[5]); byte[1] stayed constant at 0x80 the whole
/// session (not a keys field, contrary to the previous assumption); byte[3]
/// only ever took values 0/1, consistent with the ring center button.
/// [0] 0x03 Report ID
/// [1] Constant 0x80 — role unknown
/// [2] bit 7 = ring active; bits 0–6 = ring position (0–71)
/// [3] Ring center button (0 = up, 1 = down) — inferred, not isolated in capture
/// [4] Keys 1–8 bitmask
/// [5] Mirrors byte[4]
/// [6–9] Reserved
public func decodeBLEPadReport(
    report: UnsafePointer<UInt8>,
    length: CFIndex
) -> AuxButtons? {
    guard length >= 5 else { return nil }
    let keys = report[4]
    let ringByte = report[2]
    let ringActive = (ringByte & 0x80) != 0
    let ringPos = ringByte & 0x7F
    let ringButtonDown = report[3] != 0

    return AuxButtons(
        buttons: (0..<8).map { (keys & (1 << $0)) != 0 },
        touchRingActive: ringActive,
        touchRingButtonDown: ringButtonDown,
        touchRingPosition: ringActive ? ringPos : 0x7F)
}

// MARK: - Wireless status decoding (bit-0 protocol)

/// Decode wireless status for V1/Intuos3 dongles (ACK-4040 / basic protocol).
/// Protocol: report[1] bit 0 = connection state (1 = active, 0 = lost).
public func decodeWirelessReport(report: UnsafePointer<UInt8>, length: CFIndex) -> [DecodeResult] {
    guard length >= 2 else { return [] }
    if (report[1] & 0x01) != 0 { return [.wireless(.active)] }
    return [.wireless(.lost)]
}
