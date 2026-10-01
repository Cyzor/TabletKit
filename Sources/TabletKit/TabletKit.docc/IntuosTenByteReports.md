# Intuos 10-Byte Reports

Read the 10-byte pen report shared by Intuos 1 through 5, Intuos Pro gen 1, older Cintiqs, and the 2015–2018 consumer Intuos.

## Overview

``IntuosV1Decoder`` handles this format, ``CintiqV1Decoder`` handles it on the Cintiq 12WX through 27QHD, and ``Intuos3Decoder`` handles the Intuos3's variant. Layouts were confirmed on an Intuos5 L (PTH-850), Intuos Pro L (PTH-851), Cintiq 24HD (DTK-2400), and a first-generation Intuos 6×8 (GD-0608-U).

Unlike later Wacom formats, multi-byte values here are big-endian. Byte offsets count the report ID as byte 0.

## Tell the Packets Apart

The report ID is `0x02` or `0x10`, depending on the model. Byte 1 decides what kind of packet it is:

- `(status & 0xFC) == 0xC0`: a pen has entered and announces its serial and tool ID.
- `(status & 0xFE) == 0x20`: a pen is in range but the tablet has no position for it. Bytes 6–8 are zero.
- `(status & 0xFE) == 0x80`: the pen has left.
- Anything else is a data packet. Bits 1–4, read as `(status >> 1) & 0x0F`, give its type.

Types `0x00` to `0x03` are ordinary pen packets. Type `0x05` carries Art Pen rotation. Type `0x0A` is an airbrush's second packet, and `0x06` and `0x08` are mice.

## Read a Pen Packet

```swift
let x = ((Int(r[2]) << 8 | Int(r[3])) << 1) | (Int(r[9]) >> 1) & 1
let y = ((Int(r[4]) << 8 | Int(r[5])) << 1) | Int(r[9]) & 1
let pressure = Int(r[6]) << 3 | Int(r[7] & 0xC0) >> 5 | Int(r[1]) & 1
let tiltX = ((Int(r[7]) << 1) & 0x7E | Int(r[8]) >> 7) - 64
let tiltY = (Int(r[8]) & 0x7F) - 64
let hover = Int(r[9]) >> 2
```

Pressure is 11 bits. Tablets with 1,024 levels, such as the Intuos 1 and 2, use half of it. In a pen packet, status bits 1 and 2 are the side buttons.

The extra low bit doubles the coordinate resolution, so the range is twice the sensor's nominal count. The Linux driver discards that bit on Intuos 1 and 2 and halves its maximum to match. If you keep the bit, use doubled maximums; mixing the two conventions maps only a quarter of the tablet.

## Don't Mistake Rotation for a Pen Packet

An Art Pen sends a rotation packet after every pen packet, with status `0xEA` in contact or `0xAA` while hovering. Two things about it look like a pen packet but aren't:

- Status bit 1 is part of the packet type, not a side button.
- Bytes 6 and 7 hold the angle, not pressure.

Decode it as a pen packet and every other report presses a side button and jumps the pressure, which looks like a pen that doesn't work with the tablet. Read the angle instead:

```swift
let t = Int(r[6]) << 3 | (Int(r[7]) >> 5) & 7
let raw = r[7] & 0x20 != 0
    ? (t > 900 ? (t - 1) / 2 - 1350 : (t - 1) / 2 + 450)
    : 450 - t / 2
// raw spans -900...899 for one turn
```

Keep the angle and attach it to the next pen packet.

## Identify the Pen

The entry packet carries the pen's identity:

```swift
let serial = UInt32(r[3] & 0x0F) << 28 | UInt32(r[4]) << 20
    | UInt32(r[5]) << 12 | UInt32(r[6]) << 4 | UInt32(r[7]) >> 4
let toolID = Int(r[2]) << 4 | Int(r[3]) >> 4
    | Int(r[7] & 0x0F) << 16 | Int(r[8] & 0xF0) << 8
```

Both ends of a pen share its serial and differ in bit 3 of the tool ID, the eraser bit. The full tool ID is wider than 16 bits: the Art Pen that came after the Intuos4, for example, reports `0x10804`. ``ToolIdentity`` folds it into 16 bits, so compare codes within one convention.

The tablet announces the pen only when it comes into range. If your app starts with a pen already in range, you won't learn which pen it is until it leaves and returns.

## Switch It On

Until the tablet receives feature report `[0x02, 0x02]`, it acts as a mouse. On the PTH-850, finger touch arrives on a second USB interface as a 64-byte container.

## See Also

- ``IntuosV1Decoder``
- ``CintiqV1Decoder``
- ``Intuos3Decoder``
- ``ToolIdentity``
- <doc:DecodingPenReports>
