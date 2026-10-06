# Supporting Tablets That Describe Themselves

Size a Huion, Gaomon, XP-Pen, or UGEE tablet from its own answer, with no registry entry.

## Overview

TabletKit identifies Wacom tablets by product ID: it looks the ID up in ``WacomDeviceRegistry`` and gets the coordinate range, pressure levels, and report format. Most other brands build their tablets on chips from UC-Logic, and those tablets can tell you their size instead. You ask once when the tablet connects, and the answer is all a decoder needs.

The steps are the same as in <doc:BuildingAMinimalDriver>, with one difference. Switching the tablet on and finding out what it is happen together:

1. Find the tablet.
2. Switch it on and read its answer.
3. Build a spec from the answer.
4. Decode each report, and keep time for tablets that go quiet.

The `pen-surface` sample does all four, alongside its Wacom support.

UC-Logic support in TabletKit is new. The UGEE v2 path works on a Xencelabs Pen Display 24, with both of its pens. The Huion v2 path decodes public recordings of real Huion tablets correctly, but no Huion tablet has been tried under macOS yet.

## Find the Tablet

UC-Logic tablets don't share a vendor ID. Huion and Gaomon use `0x256C`, XP-Pen, UGEE, and Parblo use `0x28BD`, and many older and smaller brands use UC-Logic's own `0x5543`. Match on all three, and treat each match as a candidate until it answers.

Xencelabs also uses `0x28BD`. Its tablets speak UGEE v2, but TabletKit has a dedicated decoder for them, ``XencelabsDecoder``, that also handles their buttons and dials. Check ``VendorDeviceRegistry`` first, and fall back to this article's path only for tablets it doesn't list.

## Switch It On and Read the Answer

The two protocols switch on differently, and keep their answer in different string descriptors:

| | Huion v2 | UGEE v2 |
|---|---|---|
| Brands | Huion, Gaomon | XP-Pen, UGEE, Parblo |
| Switch on | Read string descriptor 200 | Send output report `02 B0 04` |
| Answer | String descriptor 200 | String descriptor 100 |

The vendor ID tells you which to try: Huion v2 for `0x256C`, UGEE v2 for `0x28BD`, and either for `0x5543`. Don't send one protocol's switch-on to the other's tablets.

For a Huion tablet, reading the answer is the switch. For a UGEE tablet, send the output report to the interface that declares report `0x02`, then read descriptor 100. Pad the report with zeros to the interface's declared output size. The firmware ignores a three-byte write, even when the write itself succeeds:

```swift
let size = hidIntProperty(device, kIOHIDMaxOutputReportSizeKey)
let command: [UInt8] = [0x02, 0xB0, 0x04] + Array(repeating: 0, count: max(size - 3, 0))
IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x02, command, command.count)
```

String descriptors come from the USB device, not the HID interface, so read them with a standard `GET_DESCRIPTOR` control request through IOKit's USB device interface. You don't need to open the device for this, so it works while your own HID connection is open. Ask for US English (`0x0409`) and up to 255 bytes, and keep the whole reply, including its two-byte header.

## Build a Spec

Pass the reply to ``UCLogicTabletInfo``. It returns `nil` if the reply isn't a self-description, which is how you tell which protocol the tablet speaks:

```swift
let info = UCLogicTabletInfo(huionDescriptor200: reply200)
    ?? UCLogicTabletInfo(ugeeDescriptor100: reply100)
```

Some Huion tablets answer every string descriptor they don't know with their product name. ``UCLogicTabletInfo`` recognizes a text-only reply and rejects it.

The result holds the coordinate range, pressure levels, resolution, and the number of buttons on the tablet. ``UCLogicTabletInfo/digitizerSpec`` turns it into the ``DigitizerSpec`` a decoder takes, the same type a registry entry produces. Resolution gives the active area in millimeters, if you want to show it.

## Decode Each Report

Create one ``UCLogicDecoder`` per tablet, and tell it which protocol answered:

```swift
var decoder = UCLogicDecoder(protocol: info.tabletProtocol)
var state = DecoderState()
let spec = info.digitizerSpec
```

Then decode each input report as it arrives, as with any other decoder:

```swift
let results = decoder.decode(
    report: report, spec: spec, state: &state, deviceFamily: .ucLogic)
```

These pens don't identify themselves, so the decoder announces every pen with the same tool code, `0xE902`, and every eraser with `0xE90A`. ``WacomToolCatalog`` names them "Pen" and "Pen (Eraser)". TabletKit, not a manufacturer, assigns tool codes from `0xE000` through `0xEFFF`; see ``ToolIdentity/toolCode``.

## Keep Time for Quiet Tablets

A Huion tablet never says the pen has left. It just stops sending. Decoders never read the clock, so you watch for the silence.

After each report, check ``TabletReportDecoder/silenceTimeout``. If it isn't `nil`, start a timer for that long, and restart it on every report. When it fires, ask the decoder what the silence means:

```swift
if let timeout = decoder.silenceTimeout {
    silenceTimer.restart(after: timeout) {
        let results = decoder.decodeSilence(
            spec: spec, state: &state, deviceFamily: .ucLogic)
        handle(results)
    }
}
```

For a Huion tablet the timeout is 100 ms, and the result is a pen sample with `inProximity` set to `false`. Other decoders return `nil` for the timeout, so the same code is safe for every tablet.

## What's Not Covered Yet

The decoder reads pen reports and the tablet's buttons, which arrive as ``AuxButtons``. It ignores dials, rings, and touch strips, and doesn't support older UC-Logic protocols that don't describe themselves. Some XP-Pen tablets switch on with `02 B0 02` instead of `02 B0 04`; that variant is untested. If you have one of these tablets, a recording of its reports would help. See the Extending Support guide in the repository.

## See Also

- <doc:BuildingAMinimalDriver>
- ``UCLogicTabletInfo``
- ``UCLogicDecoder``
- ``TabletReportDecoder/silenceTimeout``
