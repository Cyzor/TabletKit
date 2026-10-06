# Building a Minimal Driver

Move the cursor, click, and pass pressure and tilt to apps with about 300 lines of Swift.

## Overview

TabletKit decodes tablet reports but doesn't act on them. Getting from decoded pen data to a working cursor takes four more steps: find the tablet, switch it on, decode each report as it arrives, and post events to macOS.

The `pen-surface` sample does all four. It maps the whole tablet to the main display, clicks with the tip, and maps the two side buttons to right and middle click. It has no settings, handles USB tablets only, and skips ExpressKeys and touch. Its release build is about 1 MB.

Run it from the TabletKit folder:

```
swift run pen-surface
```

Quit MockTab or Wacom's driver first, or two drivers will move the cursor. The terminal needs Input Monitoring permission to read the tablet and Accessibility permission to move the cursor. Both are under System Settings › Privacy & Security.

## Find the Tablet

`IOHIDManager` reports each device that matches a filter. For Wacom tablets, ask for everything with Wacom's vendor ID:

```swift
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x056A] as CFDictionary)
```

A tablet usually shows up as several devices, called interfaces: one for the pen, one for the buttons, sometimes one for touch. The matching callback runs once for each. The sample looks up each interface's product ID in ``WacomDeviceRegistry``. Interfaces with the same product ID belong to the same tablet and share one decoder. Each tablet gets its own, so several can be connected at once.

The sample also matches Huion, XP-Pen, and other tablets built on UC-Logic chips. Those size themselves instead of using the registry; see <doc:SupportingTabletsThatDescribeThemselves>.

The registry entry, a ``WacomDeviceSpec``, gives the tablet's coordinate range, pressure levels, button count, and report format. The report format creates the decoder:

```swift
var decoder = spec.parser.makeDecoder()
```

## Switch It On

Most Wacom tablets start in a reduced mode. The pen moves the cursor, but pressure, tilt, or a side button may be missing. A short command from the computer switches the tablet to full reports.

Each registry entry lists that command in `initSteps`: usually one or two feature reports, sometimes with a pause between them. The sample sends them to the first interface that declares those reports. Sending them elsewhere fails, and the tablet stays in reduced mode.

Intuos Pro tablets (PTH-x60) also need ``sendWacomInputModeInit(_:tag:)`` over USB. Without it they send touch but no pen.

To see what switch-on does, run the sample with `--init none` and compare. The status line shows which features each tablet has reported so far.

## Decode Each Report

Register a callback for input reports on each interface. Every call hands over one report's bytes:

```swift
let results = decoder.decode(
    report: HIDReport(pointer: report, count: length), spec: digitizerSpec,
    state: &decoderState, deviceFamily: spec.family)
```

Keep one ``DecoderState`` per tablet and pass it back every time. Decoders use it to remember things between reports, such as which pen is in range.

Decoders are value types, so keep the copy that `decode` changed. The results come back as a list, because one report can hold several things. The sample only needs two: `.pen` for movement and `.toolEnter` for a pen coming into range.

The sample handles reports on the main run loop, which is fine for a demo. A real driver should use ``HIDThread`` instead, so a busy interface never delays the pen.

## Post Events

A ``TabletPoint`` holds raw tablet coordinates. Scale them to the screen:

```swift
let x = screen.minX + screen.width * Double(p.x) / Double(p.maxX)
let y = screen.minY + screen.height * Double(p.y) / Double(p.maxY)
```

Treat the tip as down when `normalizedPressure` is above about 0.004. Below that is sensor noise, not contact. Then post a mouse event for each change: down, up, dragged, or moved.

Drawing apps look for pressure and tilt in the event's tablet fields. Set the subtype before those fields, because they share storage that depends on it:

```swift
event.setIntegerValueField(.mouseEventSubtype,
    value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
event.setDoubleValueField(.tabletEventPointPressure, value: p.normalizedPressure)
event.setDoubleValueField(.mouseEventPressure, value: p.normalizedPressure)
event.setDoubleValueField(.tabletEventTiltX, value: p.tiltX)
event.setDoubleValueField(.tabletEventTiltY, value: -p.tiltY)
```

Apps differ in which pressure field they read, so set both. Tilt Y is negated because macOS measures it in the opposite direction from TabletKit. See <doc:DecodingPenReports> for why.

## What a Full Driver Adds

MockTab is built the same way, with more around it. It handles several tablets at once, Bluetooth, ExpressKeys, rings and dials, touch, smoothing, a settings window, and a long list of per-model quirks. None of that changes the four steps above.

## See Also

- <doc:DecodingPenReports>
- ``WacomDeviceRegistry``
- ``TabletReportDecoder``
- ``HIDThread``
