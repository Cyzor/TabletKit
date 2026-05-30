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

## Contributing

PR review runs in batches, usually a few weeks per cycle. New device
profiles, decoder additions, bug fixes with capture-log fixtures, and
metadata corrections all land well here. UI and app-level issues belong
on the [MockTab repo](https://github.com/Cyzor/tablet-driver) instead.
See [`CONTRIBUTING.md`](CONTRIBUTING.md) for scope and submission
format. Fork freely if waiting doesn't suit — MPL-2.0 exists for that.
