# Intuos Pro Gen 3 Reports

Read the 2025 Intuos Pro (PTK-470, PTK-670, PTK-870) over USB and Bluetooth, and handle the ways its reports differ from earlier Wacom tablets.

## Overview

``IntuosV3Decoder`` handles these tablets and the Movink 13, which shares their USB pen report. The Linux driver had no support for them when this decoder was written, so the layouts here come from captures of a PTK-870. Where something hasn't been seen on hardware, this article says so. Annotated excerpts from those captures back the [dial steps](https://github.com/Cyzor/tablet-driver/blob/main/Notes/Evidence/PTK-870-Dial-Steps.md), [edge behavior](https://github.com/Cyzor/tablet-driver/blob/main/Notes/Evidence/PTK-870-Edge-and-Groove.md), and [tilt](https://github.com/Cyzor/tablet-driver/blob/main/Notes/Evidence/PTK-870-Tilt.md).

The PTK-870's surface is 69,800 × 39,000 units at 200 units per millimeter. Pressure runs from 0 to 8,191, and tilt from −64° to 64°. Multi-byte values are little-endian, and byte offsets count the report ID as byte 0.

## Switch It On

Both USB and Bluetooth need feature report `[0x02, 0x02]` before they send pen data. Until then the tablet sends only an idle report, `0x06`.

Over USB, send it to the right interface. The tablet first enumerates a vendor interface that declares feature reports but rejects this one. The write fails with `0xE0005000` and the tablet stays idle. Send it to the pen interface instead: usage page `0x01`, usage `0x80`, and a declared feature report `0x02`.

## Read the USB Pen Report

USB pen data arrives on report `0x1E`:

| Bytes | Field |
| --- | --- |
| 2 | Status |
| 3–5 | X, 24 bits |
| 6–8 | Y, 24 bits |
| 9–10 | Pressure |
| 11–12, 13–14 | Tilt X and Y, signed 16-bit, in degrees |
| 15–16 | Rotation, signed, −900 to 899 for one full turn |
| 19 | Hover distance; 255 means at or past the edge of sensing |
| 20–23, 24–25 | Pen serial and tool code; both 0 out of proximity |

In the status byte, `0x80` means the pen is in proximity, `0x20` means the eraser end, and `0x02`, `0x04`, and `0x08` are side buttons 1 to 3.

The tablet mixes position-only frames in with full ones. These stub frames have a status of `0x80`, zero tilt and rotation, and a hover distance of 255. Keep the previous tilt and rotation through them rather than reading the zeros.

A rotation of exactly 0 means the tablet had no reading for that frame. Keep the previous angle. Pens without a rotation sensor send 0 almost all the time.

## Read the Dials and ExpressKeys

Over USB, report `0x11` carries the controls:

- Byte 1 holds the eight ExpressKeys, one bit each.
- Byte 3 holds the center key of each cluster: bit 0 left, bit 1 right.
- Bytes 4 and 5 hold the left and right dials as signed 7-bit step counts.

One full turn of a dial is 24 steps. The ridges on the dial are grip texture, not detents. The dials don't press; the center keys are ordinary keys.

## Read Bluetooth Reports

Over Bluetooth LE, everything arrives on report `0x1A`. The pen layout follows the earlier Intuos Pro Bluetooth frame, with both coordinates widened to 20 bits and packed:

```swift
let x = Int(r[4]) | Int(r[5]) << 8 | Int(r[6] & 0x0F) << 16
let y = Int(r[6] >> 4) | Int(r[7]) << 4 | Int(r[8]) << 12
```

Reading X as 16 bits seems to work until the pen reaches the rightmost 21 millimeters of a PTK-870, where it wraps and the cursor jumps to the far edge.

The other fields:

- Bytes 9–10 are pressure. Use both bytes; byte 10 alone reads every stroke at 1/256 of its force.
- Bytes 11 and 12 are tilt X and Y, signed, in degrees.
- Byte 13 and the low half of byte 14 are rotation, a signed 12-bit value on the same scale as USB. The high half of byte 14 is a frame counter, so mask it off.
- Byte 15 is hover distance: 20 with the tip down, 255 out of range.
- Byte 18 holds the ExpressKeys, bits 0–3 on the left and 4–7 on the right.
- Byte 19 holds dial steps: bit 2 marks a left-dial step, with bit 3 set for counterclockwise; bits 4 and 5 do the same for the right dial. Each flagged frame is exactly one step.

In the status byte at offset 3, `0x80` means proximity and `0x40` a close enough fix for tilt and pressure to be valid. `0x10` and `0x20` mean the eraser end is pressed or in range; treat either as the eraser. A status of `0x00` marks the pen leaving.

Byte 1 tells you what kind of frame it is. Its low four bits are a packet class, and its high four bits are a rolling counter, so compare only the low bits. Class 1 frames announce a pen's identity, with its serial in bytes 4–7 and its tool code in bytes 8–9, and carry no position. Decode one as a position and the cursor jumps to a fixed spot and clicks.

The tablet sends that announcement once, as the pen approaches, and it's easy to miss. If the pen was already in range when your app started, you may never see one.

Battery level arrives on report `0x1B` once a second. Byte 1 holds the percentage in bits 0–6, with bit 7 set while charging.

## Handle the Edges

These tablets keep reporting after the tip leaves the drawing area, over both USB and Bluetooth.

**In the groove.** A pen resting in the molded groove past an edge is reported about 850 units *inside* the edge, so no inset or clamp can catch it. The tablet does say it has lost the tip: the close-fix bit is almost always set along the real border and almost never in the groove. Combine that bit, or a hover distance of 255, with a band near the edge. Don't use either alone, because high hover in the middle of the tablet clears the bit and reads 255 too.

**Past the edge.** Once the tip goes past an edge, the position starts tracking the pen's barrel instead, and the cursor leaps inward. Real movement back onto the surface stays under about 250 units per frame, while these leaps are at least 2,600, so a continuity check separates them. The tablet often reports a brief exit in between; don't reset the check when it does.

## What Isn't Confirmed Yet

- Report `0x1F`, a 16-bit USB pen report, comes from OpenTabletDriver's sources. No capture contains it.
- Bluetooth side button 1 hasn't been pressed in a capture.
- On USB, ``IntuosV3Decoder`` reads status bit `0x40` as the tip switch, but the bit is also set on every hover frame that has real tilt. It may mean "in range", as it does in Wacom's later pen-display reports.

## See Also

- ``IntuosV3Decoder``
- ``TabletPoint``
- ``AuxButtons``
- <doc:DecodingPenReports>
