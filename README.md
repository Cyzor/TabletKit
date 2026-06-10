# TabletKit

**TabletKit** is a Human Interface Device (HID) decoder layer for Wacom (and potentially other) drawing tablets on macOS. It turns raw USB and Bluetooth report bytes into structured pen, aux-button, and touch events an app can act on — without AppKit, IOKit, or event-injection plumbing.

Serves as the decoder for [**MockTab**](https://mocktab.org), an open-source macOS driver for older Wacom tablets ([source](https://github.com/Cyzor/tablet-driver)).

License: **MPL-2.0** — see [`LICENSES/MPL-2.0.txt`](LICENSES/MPL-2.0.txt).

## Usage

```swift
.package(url: "https://github.com/Cyzor/TabletKit.git", from: "0.1.0")
```

…then `import TabletKit` and consult the public surface described in
[`CHANGELOG.md`](CHANGELOG.md): `TabletReportDecoder`, `DecodeResult`,
`TabletPoint`, `WacomDeviceRegistry`, `VendorDeviceRegistry`, and friends.

## Tests

```
swift test
```

runs the package's 259-test suite. No Xcode project is required.

## Versioning

Follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and will
adopt [SemVer](https://semver.org/spec/v2.0.0.html) after 1.0. Before 1.0,
minor versions may break source compatibility.

## Acknowledgments

TabletKit's protocol knowledge and device data draw from several open-source projects:

- **[OpenTabletDriver](https://github.com/OpenTabletDriver/OpenTabletDriver)** — the non-Wacom registry entries come from OTD's per-vendor JSON configurations, the most comprehensive public database of tablet PIDs and dimensions across vendors.
- **[libwacom](https://github.com/linuxwacom/libwacom)** — libwacom's tablet files are the authoritative source for Wacom physical dimensions; they cross-check and correct entries where the kernel's constants are inaccurate.
- **[input-wacom](https://github.com/linuxwacom/input-wacom) / Linux kernel HID subsystem** — the kernel driver is the canonical reference for Wacom report formats and protocol constants; several decoder field mappings follow kernel source directly.
- **[wacom-hid-descriptors](https://github.com/linuxwacom/wacom-hid-descriptors)** — the linuxwacom HID descriptor corpus informed decoder development across multiple tablet families.

## Contributing

Device profiles, decoder additions, bug fixes with capture-log fixtures, and metadata corrections all fit here; UI and app-level issues belong on the [MockTab repo](https://github.com/Cyzor/tablet-driver). See [`Contributing.md`](Contributing.md) for scope and submission format. Fork freely if waiting doesn't suit, which the MPL-2.0 arrangement supports.
