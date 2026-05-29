# TabletKit

Pure-logic HID decoders, device registry, and supporting value types for
Wacom (and vendor-neutral) drawing tablets on macOS. Extracted from the
[MockTab](../mocktab-app) app so the decoder layer can be tested in
isolation and consumed by other apps without GPL contamination.

License: **MPL-2.0** — see [`LICENSES/MPL-2.0.txt`](LICENSES/MPL-2.0.txt).

## Usage

```swift
.package(url: "https://github.com/<you>/mocktab-kit.git", from: "0.1.0")
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
