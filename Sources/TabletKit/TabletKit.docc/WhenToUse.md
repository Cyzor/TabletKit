# When to Use TabletKit

TabletKit is for applications that need to understand drawing-tablet input. It is not a complete tablet driver.

## Overview

TabletKit reads raw HID reports from drawing tablets and turns them into structured pen, button, and touch events. It does not communicate with AppKit, move the system cursor, inject input, or manage a driver’s lifecycle. Your app handles those jobs.

TabletKit produces `TabletPoint`, `TouchContact`, and other `DecodeResult` values from the bytes that a tablet sends. MockTab is one example of an app that uses TabletKit.

Use TabletKit when you need a reliable way to interpret tablet reports. Do not use it by itself when you need a finished driver.

## Situations Where TabletKit Works

**Building a macOS tablet driver or related tool.** IOKit gives your app raw report bytes. TabletKit turns those bytes into events that your app can use, so you do not need to reverse-engineer each device family’s report format yourself.

**Using a Wacom or Xencelabs device in the registry.** `WacomDeviceRegistry` and `VendorDeviceRegistry` cover roughly 190 product IDs across Wacom’s Bamboo, Intuos, Cintiq, DTU, and DTH lines, plus Xencelabs pen and Quick Keys devices. When the registry includes a device, TabletKit knows its report format and, in most cases, has hardware verification.

**Inspecting a device’s HID reports.** The `HID/` layer includes a report-descriptor parser and capture tools. Use them to identify a device’s controls, report fields, and value ranges before writing a decoder.

**Using TabletKit outside an AppKit app.** TabletKit does not depend on AppKit, and only `HIDDeviceSupport.swift` uses IOKit. The decoder can therefore run anywhere Swift code can provide raw report bytes, including test tools and command-line utilities. A non-Mac platform could also use it with its own HID transport.

## Situations Where Something Else Works Better

**You need tablet input to control the OS.** TabletKit creates structured events, but it does not post `CGEvent`s or use the Accessibility API. To move the system cursor or control other apps, use TabletKit with a driver layer or use an existing driver such as MockTab or Wacom’s driver.

**You use a device from another vendor.** TabletKit’s registry and device-specific decoders support Wacom and Xencelabs report formats. `GenericPenDecoder` can often read a standard USB HID digitizer from its HID descriptor, but it cannot provide vendor-specific features—such as rings, dials, OLED displays, or wireless dongles—for other hardware.

**You use an unlisted Wacom or Xencelabs device.** TabletKit can use the HID descriptor to discover an unknown device and provide partial, best-effort decoding. This usually confirms basic operation, but it does not match the precision of a decoder written and verified for that device. See the unknown-device discovery guide for its practical limits.

**You need Windows or Linux integration now.** The registry and decoders work at the report-format level and do not inherently depend on macOS. However, TabletKit currently tests its integration through macOS IOKit HID. It does not manage Windows HID, Linux `hidraw`, or `evdev` integration.

## Checklist

Is the device Wacom or Xencelabs? → Check the registry. If it lists the device, TabletKit probably supports it.

Do you need decoded events, or do you need the cursor to move? → Use TabletKit for decoded events. Use TabletKit with a driver layer, or use MockTab, for cursor movement.

Is the device from another vendor? → TabletKit may provide basic pen decoding, but do not expect vendor-specific controls.

Otherwise → Use TabletKit.

## See Also

- <doc:DecodingPenReports>
- ``WacomDeviceRegistry``
- ``VendorDeviceRegistry``
- ``GenericPenDecoder``

This revision keeps the original scope and technical claims while placing the practical decision first, using active verbs, and reserving HID terminology for places where it identifies a concrete interface or feature. [sqlite](https://sqlite.org/whentouse.html)