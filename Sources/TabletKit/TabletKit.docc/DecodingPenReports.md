# Decoding Pen Reports

Turn raw HID input-report bytes into `TabletPoint` values while avoiding coordinate, scale, and tilt-sign mistakes.

## Overview

A `TabletReportDecoder` accepts the bytes from one HID input report and returns zero or more `DecodeResult` values. For pen movement, handle the `.penTabletPoint` case:

```swift
let results = decoder.decode(
    report: reportBytes,
    length: reportLength,
    spec: spec,
    state: state,
    deviceFamily: family
)

for result in results {
    if case let .penTabletPoint(point) = result {
        canvas.draw(at: point)
    }
}
```

One HID report can produce several results, such as a tool-enter event and a pen position. Always iterate over the array rather than assuming that each call returns one event.

## Coordinates Stay Raw

`TabletPoint.x` and `TabletPoint.y` use the tablet’s own coordinate system, not a normalized range from 0 to 1. Devices commonly report coordinate values in the tens of thousands.

Each point includes `maxX` and `maxY`, which give the device’s coordinate limits. Normalize coordinates at the boundary where your app maps them to a screen, canvas, or active area:

```swift
let normalizedX = Double(point.x) / Double(point.maxX)
```

TabletKit does not normalize coordinates because different uses need different mappings. Screen placement, active-area cropping, and aspect-ratio correction each apply the division differently.

Pressure works similarly. `pressure` and `maxPressure` retain the device’s raw values, while `normalizedPressure` provides a standard value from 0.0 to 1.0:

```swift
brush.setPressure(point.normalizedPressure)
```

## Tilt Uses a Unit Vector

`tiltX` and `tiltY` range from -1.0 to 1.0. They follow the HID Digitizer Tilt convention, which also matches W3C Pointer Events: positive X means the pen leans right, and positive Y means it leans toward the user.

macOS uses the opposite Y direction for `NSEvent.tilt.y`: positive means the pen leans away from the user. If you create a `CGEvent` or pass tilt to an AppKit-related API, negate Y once at that boundary—never in TabletKit and never more than once. MockTab applies this conversion in `resolveEffectivePose`.

Do not try to infer tilt direction by reading `NSEvent.tilt` from a live pen while multiple drivers or tablets are active. That approach produced inconsistent signs across sessions. Instead, check tilt in an application whose brush preview visibly shows pen angle. A flat calligraphy brush in Rebelle provided the confirmation used here.

## Rotation and Buttons

`rotation` represents pen-barrel twist, such as an Art Pen’s rotation. It ranges from 0.0 to 360.0 degrees and has meaning only when the connected tool supports rotation. Check `DecodeResult.toolCompatibility` for a warning when it does not.

Button state appears on the same `TabletPoint`, not as a separate event. `penButton1` and `penButton2` represent the two side buttons that most pens provide; `penButton3` through `penButton5` support pens with additional buttons.

`eraser` becomes `true` when the eraser tip contacts the tablet. It does not represent a button, so check it before treating contact as drawing input.

## See Also

- ``TabletReportDecoder``
- ``TabletPoint``
- ``DecodeResult``
- ``DigitizerSpec``
