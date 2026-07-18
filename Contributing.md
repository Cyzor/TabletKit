# Contributing to TabletKit

TabletKit is part of a hardware driver project called [MockTab](https://github.com/Cyzor/tablet-driver) to support older drawing tablets on macOS.

TabletKit ships under MPL-2.0.

## Contribution Process

- **New device profiles** in `WacomDeviceRegistry` or `VendorDeviceRegistry`. Recognition-only entries help; decoded entries help more.
- **New decoders** for tablet families MockTab doesn't yet handle, conforming to `TabletReportDecoder`.
- **Decoder bug fixes** with a capture-log fixture that demonstrates the bug.
- **Test fixtures** that improve coverage of existing decoders — especially edge cases like wireless drop, tool swap, and out-of-range.
- **Dimension or metadata corrections** for existing registry entries, with a citable source (libwacom data, Wacom spec sheet, direct measurement).

App-level bugs, UI issues, and installation problems belong on the [MockTab repo](https://github.com/Cyzor/tablet-driver) — see its [`Contributing.md`](https://github.com/Cyzor/tablet-driver/blob/main/Contributing.md).

## Data sources, in order of confidence

Decoder work is only as good as the data behind it. Three tiers, strongest first:

1. **Raw IOKit traffic via dtrace, with SIP off.** The reference script is [`tools/wacom_capture.d`](https://github.com/Cyzor/tablet-driver/blob/main/tools/wacom_capture.d) in the MockTab repo. Captures the bytes that crossed the USB boundary before any decoding interpreted them, a valuable data source for protocols, initialization, and device properties. Requires disabling Apple's System Integrity Protection (SIP) for optimal analysis.
2. **Upstream cross-reference.** The Linux kernel's `input-wacom` driver, `libwacom` metadata, and OpenTabletDriver vendor configs together cover most of the field. Strong for protocol shape and device metadata, weaker for Mac-specific quirks.  Cite the source and commit when importing.
3. **In-app capture via *Info → Collect Device Data…*.** Runs in userspace with no special permissions, parses the HID descriptor the OS exposes, and records input reports as the OS delivers them. Sufficient for variants of already-known families, but not for novel protocols or for anything that depends on output reports the OS filters.

Tier 1 or 2 evidence should accompany `.verified` and `.crossReferenced` entries. Tier 3 alone supports `.experimental`.

See [`Extending-Support.md`](Extending-Support.md) for a walkthrough of what a capture actually contains and how to turn one into a registry entry and decoder. The steps below assume that context.

## How to submit a decoder or device entry

1. **Capture the device.** In MockTab, visit the *Info* pane and press the *Collect Device Data…* button. The result is a JSON file with the Human Interface Device (HID) descriptors, USB strings, and a short input report capture. A [`hid-recorder`](https://github.com/hidutils/hid-recorder) log may also help, as the test harness parses both formats.
2. **Add the registry entry** in `Sources/TabletKit/WacomDeviceRegistry.swift` or `Sources/TabletKit/VendorDeviceRegistry.swift`. Mark confidence: `.experimental` if untested, `.crossReferenced` if it matches a known protocol family, `.verified` only with the hardware in hand.
3. **Add a test case** in `Tests/TabletKitTests/`, alongside the matching `<Family>DecoderTests.swift`. Fixtures live inline in those files as hex strings rather than in a separate directory. At minimum, assert that the decoder emits *some* `DecodeResult` for each captured report — that catches regressions without forcing hand-annotated expected values.
4. **Run `swift test`** locally. PRs that fail tests sit until they pass.
5. **Open the PR** with: device model, connection (USB / Bluetooth / dongle), what got verified, and what didn't.

## Pull Request Characteristics

- One sentence description of what the revision does.
- Confidence level — *"verified on a PTH-660 over USB"* vs. *"imported from OTD, untested"*. Both work; the distinction matters for review.
- Anything unusual the capture may have revealed (unexpected report IDs, padding, vendor quirks).
- The test plan actually executed.

## Forking

If project requirements fall outside the scope above, or if waiting for review does not fit timeline needs, another option is to create an independent instance of the project. TabletKit's MPL-2.0 license permits derivatives to ship under any compatible license with no obligation back. The MockTab app pins a specific TabletKit version, so a fork won't disrupt downstream users.