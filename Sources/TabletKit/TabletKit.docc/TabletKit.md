# ``TabletKit``

TabletKit reads raw USB and Bluetooth reports from drawing tablets on macOS and turns them into structured pen, button, and touch events.

## Overview

TabletKit does not depend on AppKit or inject system input. It uses IOKit HID only in `HID/HIDDeviceSupport.swift`.

The basic flow:

1. Find the device in `WacomDeviceRegistry` or `VendorDeviceRegistry`.
2. Create a ``DeviceDecoder`` for it with `spec.makeDecoder()`.
3. When the device sends a HID report, pass its bytes to the decoder.
4. Handle the returned ``TabletEvent`` values.

The decoder picks the right report format for the tablet. Most Wacom tablets also need their `initSteps` sent before they report pressure and tilt. <doc:BuildingAMinimalDriver> covers both with a working sample.

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

- ``DeviceDecoder``
- ``TabletEvent``
- ``ToolEvent``
- ``PadState``
- ``TouchFrame``
- ``DeviceEvent``
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
- ``ToolCatalog``
- ``ToolSpec``
- ``DeviceFamily``
- ``TabletSpec``
- ``ReportFormat``
- ``InitStep``
- ``ConfidenceTier``
- ``ToolKind``
- ``ToolCapabilities``

### Decoders

- ``GenericPenDecoder``
- ``PrecisionTouchDecoder``
- ``UCLogicTabletInfo``
- ``UCLogicProtocol``
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
