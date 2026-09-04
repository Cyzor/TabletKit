# ``TabletKit``

A HID decoder layer for drawing tablets on macOS: raw USB and Bluetooth report
bytes in, structured pen/button/touch events out.

## Overview

TabletKit has no AppKit or event-injection plumbing, and its only system
dependency is IOKit HID, isolated in `HID/HIDDeviceSupport.swift`. The core loop:

1. Look up the device in the registry to get its spec (``WacomDeviceRegistry``
   or ``VendorDeviceRegistry``).
2. Build a ``DigitizerSpec`` from the spec's coordinate and pressure ranges.
3. Allocate a ``DecoderState`` for this device instance.
4. On each HID report callback, hand the bytes to the matching
   ``TabletReportDecoder`` and act on the returned ``DecodeResult`` array.

See the [README](https://github.com/Cyzor/TabletKit#usage) for a full worked
example against a real device (Wacom Intuos Pro M, PTH-660, USB).

TabletKit is an independent, community-built project. It is not affiliated
with, endorsed by, or sponsored by Wacom Co., Ltd. or any other device
vendor. Product names are used only to describe hardware compatibility.

## Topics

### Essentials

- ``DecodeResult``
- ``DecoderState``
- ``TabletReportDecoder``
- ``TabletPoint``
- ``ToolIdentity``
- ``AuxButtons``
- ``TouchContact``
- ``DigitizerSpec``
- ``WirelessStatus``
- ``DeviceInstanceKey``

### Device data

- ``WacomDeviceRegistry``
- ``VendorDeviceRegistry``
- ``VendorDeviceProfile``
- ``BrandHeuristic``
- ``WacomToolCatalog``
- ``WacomToolSpec``
- ``DeviceFamily``

### Decoders

- ``IntuosV1Decoder``
- ``IntuosV2Decoder``
- ``IntuosV3Decoder``
- ``Intuos3Decoder``
- ``BambooDecoder``
- ``CintiqV1Decoder``
- ``GraphireDecoder``
- ``DTUDecoder``
- ``DTUSDecoder``
- ``GenericPenDecoder``
- ``PrecisionTouchDecoder``
- ``XencelabsDecoder``

### HID mechanics

- ``queryHIDDigitizerSpec(_:)``
- ``hidIntProperty(_:_:)``
- ``hidReportDescriptorHex(_:)``
- ``sendWacomInputModeInit(_:tag:)``
- ``HIDThread``
- ``HIDReportDescriptorParser``
- ``DigitizerUsage``
- ``DigitizerInterfaceKind``
- ``classifyDigitizerInterface(_:)``
- ``GenericDigitizerFrame``

### Output protocols

- ``XencelabsOutputProtocol``

### Live device control

- ``TabletDevice``

### Signal conditioning

- ``CursorSmoother``
- ``PanSmoother``
- ``PressureSmoother``
