# ``TabletKit``

TabletKit reads raw USB and Bluetooth reports from drawing tablets on macOS and turns them into structured pen, button, and touch events.

## Overview

TabletKit does not depend on AppKit or inject system input. It uses IOKit HID only in `HID/HIDDeviceSupport.swift`.

The basic flow:

1. Find the device in `WacomDeviceRegistry` or `VendorDeviceRegistry`.
2. Create a `DigitizerSpec` from the device’s coordinate and pressure ranges.
3. Create a `DecoderState` for that device.
4. When the device sends a HID report, pass its bytes to the matching `TabletReportDecoder`.
5. Handle the returned `DecodeResult` values.

See the [README](https://github.com/Cyzor/TabletKit#usage) for a complete example using a Wacom Intuos Pro M (`PTH-660`) over USB.

TabletKit is an independent community project. Wacom Co., Ltd. and other device vendors do not sponsor, endorse, or affiliate with it. Product names identify compatible hardware only.

## Topics

### Guides

- <doc:WhenToUse>
- <doc:DecodingPenReports>
- <doc:BuildingAMinimalDriver>
- <doc:SupportingTabletsThatDescribeThemselves>

### Report formats

- <doc:IntuosProGen3Reports>
- <doc:IntuosProGen2Reports>
- <doc:IntuosTenByteReports>

### Essentials

- ``DecodeResult``
- ``DecoderState``
- ``TabletReportDecoder``
- ``HIDReport``
- ``TabletPoint``
- ``ToolIdentity``
- ``AuxButtons``
- ``TouchContact``
- ``DigitizerSpec``
- ``WirelessStatus``
- ``DeviceInstanceKey``
- ``RemotePairingSlot``

### Device data

- ``WacomDeviceRegistry``
- ``VendorDeviceRegistry``
- ``VendorDeviceProfile``
- ``BrandHeuristic``
- ``WacomToolCatalog``
- ``WacomToolSpec``
- ``DeviceFamily``
- ``WacomDeviceSpec``
- ``ReportParser``
- ``InitStep``
- ``ConfidenceTier``
- ``WacomToolType``
- ``ToolCapabilities``

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
- ``UCLogicDecoder``
- ``UCLogicTabletInfo``
- ``UCLogicProtocol``
- ``ExpressKeyRemoteDecoder``
- ``WacomPLDecoder``
- ``Wacom24HDTDecoder``
- ``Wacom27QHDTDecoder``
- ``BLEPenResult``

### HID mechanics

- ``queryHIDDigitizerSpec(_:)``
- ``hidIntProperty(_:_:)``
- ``hidReportDescriptorHex(_:)``
- ``sendWacomInputModeInit(_:tag:)``
- ``HIDThread``
- ``LatencyProbe``
- ``HIDReportDescriptorParser``
- ``DigitizerUsage``
- ``DigitizerInterfaceKind``
- ``classifyDigitizerInterface(_:)``
- ``GenericDigitizerFrame``
- ``DescriptorLayout``
- ``DescriptorReport``
- ``DescriptorField``
- ``HIDReportDirection``
- ``HIDReportDescriptorParserError``
- ``GenericPenLayout``
- ``PrecisionTouchLayout``
- ``PrecisionTouchFrame``
- ``PrecisionTouchSlot``

### Output protocols

- ``XencelabsOutputProtocol``
- ``WacomOutputProtocol``
- ``IntuosOLEDImageEncoder``

### Live device control

- ``TabletDevice``

### Signal conditioning

- ``CursorSmoother``
- ``PanSmoother``
- ``PressureSmoother``

### Input state

- ``ModifierMath``
- ``LiveButtonState``
