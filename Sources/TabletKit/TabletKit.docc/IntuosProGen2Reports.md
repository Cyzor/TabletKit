# Intuos Pro Gen 2 Reports

Read the Intuos Pro gen 2 (PTH-460, PTH-660, PTH-860), the 2018 Intuos (CTL-4100, CTL-6100), and the many pen displays that share their report, over USB and Bluetooth.

## Overview

``IntuosV2Decoder`` handles this format. It started with the Intuos Pro gen 2 and spread to the Cintiq 16, 22, and 24, the Cintiq Pro, Wacom One pen displays, and MobileStudio Pro. Most layouts here were confirmed on a PTH-660 and PTH-860; where something comes only from the Linux driver, this article says so.

Multi-byte values are little-endian, and byte offsets count the report ID as byte 0.

## Read the USB Pen Report

Pen data arrives on report `0x10`, 192 bytes long:

| Bytes | Field |
| --- | --- |
| 1 | Status |
| 2–4, 5–7 | X and Y, 24 bits each |
| 8–9 | Pressure, 13 bits: byte 8 plus the low five bits of byte 9 |
| 10, 11 | Tilt X and Y, signed, in degrees (±64) |
| 12–13 | Rotation, signed, 1,800 counts per turn (Art Pen only) |
| 16 | Hover distance, 0 in contact up to 63 |
| 17–20, 21–22 | Pen serial and tool code |

In the status byte, `0x01` is the tip, `0x02` and `0x04` the side buttons, `0x20` means in range, and `0x40` means proximity. The eraser end sets `0x10` while it's in range and `0x08` when it touches. Treat either as the eraser; reading only `0x08` makes every eraser stroke start as the pen.

Leaving range, the status steps from `0x60` to `0x40` to `0x00`. Only `0x00` is a real exit. Frames at `0x40` are weak: tool code, tilt, and rotation read as zero, so keep the previous values. An Art Pen produces runs of them while still on the surface.

## Recognize the Pen

The Art Pen reports tool code `0x0804`. Some Art Pens report `0x1108`, which has bit 3 set, so the usual "bit 3 means eraser" rule misfires on it. Check for Art Pen codes before applying that rule, and prefer the status bits above for the eraser.

The KC-100 cordless mouse reports a tool code whose low four bits are `6`. Its buttons never appear in report `0x10`; they arrive on the tablet's separate mouse interface as report `0x01`. Its wheel is an 8-bit counter in byte 16, so take the difference from the previous report.

## Read the ExpressKeys and Touch

Report `0x11` carries the controls on the PTH-x60:

- Byte 1 holds the keys, one bit each.
- Byte 3 is nonzero while the touch ring's center button is pressed.
- Byte 4 is the ring position, 0 to 71, or `0x7F` with no finger on it.

Finger touch arrives on report `0x21`. Byte 1 is the contact count, followed by five 8-byte slots: contact ID, a status byte (`0x01` down, `0x00` on lift), 16-bit X and Y, then width and height.

## Read Bluetooth Reports

These tablets pair over Bluetooth Classic as "BT IntuosPro". The "LE IntuosPro" identity serves Wacom's paper-notes mode and doesn't act as a tablet.

Report `0x80` packs up to seven 14-byte pen frames, oldest first, starting at byte 1. It comes in two lengths: 99 bytes holds pen frames only; 361 bytes adds touch, the pad, and battery. Either tablet can send either.

Each frame starts with a flags byte: `0x80` valid, `0x40` proximity, `0x20` in range, `0x10` eraser in range, `0x08` eraser touching, `0x04` and `0x02` the side buttons, `0x01` the tip. Then come X, Y, and pressure as 16-bit values, tilt X and Y as signed bytes, rotation at bytes 9–10, and hover distance at byte 13. Rotation here has 3,600 counts per turn, twice the USB resolution.

The 361-byte form adds:

- Bytes 99–106: the pen serial, and bytes 107–108 its tool ID.
- Bytes 109–280: four touch frames, each ending in a 16-bit device clock that ticks every 0.225 ms.
- Byte 282: ExpressKeys, set for one report per press.
- Byte 284: battery, with bit 7 for charging and bits 0–6 the percentage.
- Byte 285: the touch ring, with bit 7 for contact and bits 0–6 the position.

The 2018 Intuos over Bluetooth uses report `0x81` instead: four 8-byte pen frames with no tilt, the serial at byte 33, the tool ID at byte 41, ExpressKeys in byte 44, and battery in byte 45.

## Read the Pen Displays' Alternate Report

Some pen displays, such as the Cintiq Pro 22, send pen data on report `0x1E` instead. Byte 1 is a constant `0x01`, byte 2 holds the status, X and Y are 24-bit values at bytes 3 and 6, pressure is a plain 16-bit value at bytes 9–10, and tilt X and Y are signed 16-bit values at bytes 11 and 13, in degrees up to ±90. Hover distance is byte 19.

## See Also

- ``IntuosV2Decoder``
- ``TabletPoint``
- ``AuxButtons``
- ``TouchContact``
- <doc:DecodingPenReports>
- <doc:IntuosProGen3Reports>
