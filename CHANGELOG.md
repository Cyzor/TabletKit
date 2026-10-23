# TabletKit Changelog

This changelog covers the `TabletKit` Swift package (the decoder layer defined in `Package.swift`).
The MockTab app sets its own version in its Xcode project and maintains separate release notes in `release-notes/`.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and will adopt [Semantic Versioning](https://semver.org/spec/v2.0.0.html) after 1.0. Before 1.0, minor versions may break source compatibility.

## [Unreleased]

## [0.6.0] — 2026-10-24

A new decoding API, a session layer that runs tablets end to end, Huion,
Gaomon, XP-Pen, UGEE, and Parblo pens, and many more controls on older Wacom
tablets. Most code written against 0.5.0 needs changes; see Changed.

### Changed

- **Source-breaking:** `DeviceDecoder` is the one way to decode. Create it
  with `TabletSpec.makeDecoder()` or `DeviceDecoder(spec:)`, pass each report
  to `events(_:)`, and handle the returned `TabletEvent` values: `.pen`,
  `.tool`, `.pad`, `.touch`, `.dial`, and `.device`. It replaces
  `TabletReportDecoder`, `DecodeResult`, `AuxButtons`, `DecoderState`, and the
  per-format decoders, which are no longer public.
- **Source-breaking:** reports arrive as `HIDReport` instead of a pointer and
  length. Wrap the IOKit buffer with `HIDReport(pointer:count:)`, or a
  `[UInt8]` with `HIDReport.withReport(_:_:)`. Byte offsets are unchanged.
- **Source-breaking:** renamed `WacomDeviceSpec` to `TabletSpec`,
  `ReportParser` to `ReportFormat`, `WacomToolCatalog` to `ToolCatalog`,
  `WacomToolSpec` to `ToolSpec`, and `WacomToolType` to `ToolKind`. The old
  names are gone.
- **Source-breaking:** `ReportFormat` and `DeviceFamily` gain `.ucLogic`.
- **Source-breaking:** `TabletDevice` keeps `open`, `close`, and `reawaken`;
  its LED, label, display, Quick Keys, and wireless kit settings moved to
  `TabletControls`. `decodeBLEPadReport` returns a `PadState`.

### Added

- `TabletSession`, which finds tablets as they connect, switches them on,
  groups each tablet's USB and Bluetooth connections, and hands reports to
  your `TabletInputSink`. `TabletSessionDelegate` reports what it finds, and
  `HIDInterface` separates the device logic from IOKit.
- `DeviceDecoder.silenceTimeout` and `eventsForSilence()`, for tablets that
  stop sending instead of reporting the pen leaving.
- Huion, Gaomon, XP-Pen, UGEE, and Parblo pens, in the Huion v2 and UGEE v2
  layouts. `UCLogicTabletInfo` sizes these tablets from what they report and
  makes their decoder, and `TabletBrand` says which brands a device may be.
  Dials and touch strips aren't decoded yet.
- `TabletQuirks`, for the ways a model departs from opening and reading
  reports, and `TabletFeature` with `FeatureEvidence`, for how well each
  feature is shown to work on a model.
- `PositionDeadBand`, which holds a resting pen's position still.
- `TabletSpec.hasTouchStrips`, `VendorDeviceRegistry.drivableSpec(forVendorID:productID:)`,
  and `LabelControl.setKeyDisplayBrightness(_:)` for Intuos4 key displays.

### Fixed

- Graphire, Volito, and early Bamboo tablets switch out of mouse mode at
  connect and whenever they fall back. Contact follows the tablet's own bit,
  so a light touch no longer drags, and their mouse buttons and wheels read
  correctly.
- Cintiq 12WX, 20WSX, 21UX, 21UX2, and 22HD read all their ExpressKeys and touch
  strips, the 21UX2's strips get mode lights, and barrel buttons on older
  Cintiqs release at once.
- Intuos Pro gen 2: the Intuos4 Grip Pen's barrel buttons and full pressure
  range, over USB and Bluetooth; ring positions without the touch bit; hover
  distance no longer read as a mouse wheel.
- Intuos4 key displays return after sleep, labels wrap instead of clipping,
  and the pen is announced once at the edge of range. The Intuos4 S no longer
  claims key displays.
- Intuos5, Intuos Pro gen 1, and Bamboo Pen & Touch fingers no longer stick or
  vanish.
- Intuos5 touch S and Intuos Pro S have six ExpressKeys.
- Tablets switched on with `[0x02, 0x02]` get `[0x02, 0x01]` when the
  connection closes, except Intuos Pro gen 3 and Movink.
- The Xencelabs 3 Button Pen and Thin Pen are told apart
  (`0xE812`/`0xE81A` for the Thin Pen).
- `DescriptorField.unit` and `unitExponent` held each other's values.

## [0.5.0] — 2026-10-01

Art Pen rotation on older Intuos tablets, a hovering eraser on newer ones, and
documentation for the core API.

### Changed

- **Source-breaking:** `DecodeResult` gains `.remotePairing`, and
  `DeviceFamily` gains `.intuos1And2`.
- Tool names follow libwacom and the Linux driver: `0x0842` is the Pro Pen 2,
  `0x0832` the Stroke Pen, `0x0852` the Intuos2 Grip Pen, and `0x0862` the
  Intuos Pen.
- ExpressKey Remote: the ring's center button is `touchRingButtonDown`, and
  keys 1–17 are `buttons[0...16]`.
- Registry ranges and pressure checked against vendor model properties.

### Added

- `WacomDeviceSpec.digitizerSpec`, `touchCompanionPID`,
  `touchCompanionInitSteps`, and `defaultPressureThreshold`.
- `WacomDeviceRegistry.vendorIDs` and `touchCompanionPIDs`.
- `RemotePairingSlot`, `AuxButtons.touchRingHardwareMode`, and
  `ModifierMath.physicalCacheIsCurrent`, `physicalCacheAgrees`, and
  `moveEventFlags`.
- Cintiq 24 and 24 Touch, Wacom One 14 Touch, Wacom One M in Android mode, the
  2025 Intuos Pro gen 3 USB revisions, and the Intuos 1/2 Grip Pen.
- DocC documentation for the core API, report-format guides, and the
  `pen-surface` sample.

### Fixed

- Art Pen rotation on Intuos4, Intuos5, and Intuos Pro gen 1.
- The eraser reads while hovering on Intuos Pro gen 2, gen 3 over Bluetooth,
  and Cintiq Pro.
- Tilt scale on several models, and `hasTilt` for every device.
- Intuos 1/2 no longer draws while hovering. The Cintiq 27QHD Touch no longer
  reports phantom contacts, and older Cintiqs no longer report a phantom pen.

## [0.4.0] — 2026-09-20

Intuos Pro gen 3 over Bluetooth, descriptor-driven pen and touch decoders, and
broad registry corrections.

### Changed

- **Source-breaking:** device families are the `DeviceFamily` enum instead of
  strings, throughout the API.
- **Source-breaking:** `ReportParser` gains `.pl` and `.expressKeyRemote`.
- **Source-breaking:** `DigitizerSpec` and `WacomDeviceSpec` gain
  `bezelButtonCount`, and `TouchContact.init` gains `contactMinor`.
- **Source-breaking:** `XencelabsControl` is now `XencelabsOutputProtocol`.
- `CursorSmoother` and `PressureSmoother` take the real time between samples.

### Added

- Intuos Pro gen 3 over Bluetooth: pen, dials, and battery.
- `GenericPenDecoder` and `PrecisionTouchDecoder`, which read a device's own
  report descriptor, plus `classifyDigitizerInterface`,
  `DescriptorLayout.modeSwitchFeatureReportID()`, and
  `hidReportDescriptorHex(_:)`.
- `DeviceInstanceKey`, `WacomToolCatalog.hasRotation(toolCode:)`,
  `XencelabsDecoder.tiltMaxDegrees`, and `DecoderState.btTouchFrameStamps`.
- Touch on the Bamboo CTH-460 and CTH-461.
- `registry.json`, a generated snapshot of the registry.

### Removed

- The `swift-docc-plugin` dependency. TabletKit has no dependencies.

### Fixed

- Intuos Pro gen 3 and Cintiq Pro alternate pen reports: proximity, pressure,
  hover, eraser, and tilt.
- Touch on Cintiq Pro pen displays, and touch and ring on the Intuos Pro M
  (PTH-651).
- A hovering stylus no longer ends proximity on Intuos5 touch models.
- Fingers lift on the Cintiq 22HD, 24HD, and 13HD touch sensors.
- Intuos 1/2 mapped only the top-left quarter of the tablet. Active areas and
  parsers corrected on many other models.

## [0.3.0] — 2026-07-22

Xencelabs hardware, a generic digitizer decoder, and new smoothing filters.

### Added

- Xencelabs Pen Display 16 and Quick Keys: display controls, bezel buttons,
  screen orientation, dial colors, battery, and the wireless dongle.
- `GenericDigitizerFrame`, for standard HID digitizers without a dedicated
  decoder.
- `PressureSmoother`. `CursorSmoother` now uses a 1€ filter.
- Bamboo Pen CTL-460, Intuos Art touch and keys, and MobileStudio Pro
  recognition.
- The `tablet-decode` sample.

### Changed

- Sources are organized into topic folders. No API change.

### Fixed

- Intuos5 ExpressKeys and ring button, and Xencelabs cursor position.

## [0.2.0] — 2026-06-10

The first non-Wacom decoder and a registry sweep against the Linux driver.

### Added

- `XencelabsDecoder` and `ReportParser.xencelabs`.
- `VendorDeviceRegistry.drivableProfile(forVendorID:productID:)`.
- About 36 registry rows from the Linux driver's device table.

### Changed

- Registry lookups are indexed by product ID, and several product identities
  are corrected: `0x0352` is the Cintiq Pro 32, `0x0003` the Cintiq Partner,
  and `0x009A` an ISDv4 digitizer.

### Removed

- **Source-breaking:** `typealias WacomDecoder`. Use `TabletReportDecoder`.

## [0.1.0] — 2026-05-28

The first public API, separated from the MockTab app.

### Added

- `TabletReportDecoder` and its value types: `DecodeResult`, `TabletPoint`,
  `ToolIdentity`, `AuxButtons`, `TouchContact`, `WirelessStatus`,
  `DigitizerSpec`, and `DecoderState`.
- `WacomDeviceRegistry`, with physical dimensions and ordered `initSteps`.
- `VendorDeviceProfile` and `VendorDeviceRegistry`, which recognize Huion,
  Xencelabs, and XP-Pen tablets.

### Notes

- The MockTab app is GPL-3.0-or-later; this package uses MPL-2.0. See
  `README.md` for why.
