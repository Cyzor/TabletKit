# ``TabletKit``

TabletKit reads raw USB and Bluetooth reports from drawing tablets on macOS and turns them into structured pen, button, and touch events.

## Overview

TabletKit does not depend on AppKit or inject system input. Only its `HID` and `Session` folders use IOKit.

The basic flow:

1. Find the device in `WacomDeviceRegistry` or `VendorDeviceRegistry`.
2. Create a ``DeviceDecoder`` for it with `spec.makeDecoder()`.
3. When the device sends a HID report, pass its bytes to the decoder.
4. Handle the returned ``TabletEvent`` values.

The decoder picks the right report format for the tablet. Most Wacom tablets also need their `initSteps` sent before they report pressure and tilt. <doc:BuildingAMinimalDriver> covers both with a working sample.

To leave the device work to TabletKit, start a ``TabletSession``. It finds tablets as they connect, switches them on, groups a tablet's USB and Bluetooth connections, and hands each report to the ``TabletInputSink`` you provide. <doc:RunningATabletSession> shows how.

TabletKit is an independent community project. Wacom Co., Ltd. and other device vendors do not sponsor, endorse, or affiliate with it. Product names identify compatible hardware only.

## Topics

### Guides

- <doc:WhenToUse>
- <doc:DecodingPenReports>
- <doc:BuildingAMinimalDriver>
- <doc:RunningATabletSession>
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
- ``RingState``
- ``StripState``
- ``TouchFrame``
- ``DeviceEvent``
- ``HIDReport``
- ``TabletPoint``
- ``ToolIdentity``
- ``TouchContact``
- ``DigitizerSpec``
- ``WirelessStatus``
- ``DeviceInstanceKey``
- ``RemotePairingSlot``

### Device data

- ``WacomDeviceRegistry``
- ``VendorDeviceRegistry``
- ``VendorDeviceProfile``
- ``TabletBrand``
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
- ``TabletQuirks``
- ``DescribedTouchRanges``

### Support evidence

- ``TabletFeature``
- ``FeatureEvidence``
- ``EvidenceLevel``
- ``EvidenceSource``
- ``SupportScope``

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

### Sessions

- ``TabletSession``
- ``TabletSessionDelegate``
- ``TabletInputSink``
- ``ConnectedTablet``
- ``TabletTransport``
- ``TabletFailure``
- ``UnclaimedKind``
- ``ConnectStep``
- ``HIDInterface``
- ``IOKitHIDInterface``
- ``HIDReportKind``
- ``HIDUsagePair``
- ``IdleReportWatcher``
- ``DongleBatteryWatcher``
- ``DonglePairingWatcher``
- ``ToolAnnouncementGrace``

### Live device control

- ``TabletDevice``
- ``TabletControls``
- ``RingLEDControl``
- ``LabelControl``
- ``DisplayPanelControl``
- ``QuickKeysControl``
- ``WirelessKitControl``
- ``LEDColor``

### Signal conditioning

- ``CursorSmoother``
- ``PanSmoother``
- ``PressureSmoother``
- ``PositionDeadBand``

### Input state

- ``ModifierMath``
- ``LiveButtonState``
