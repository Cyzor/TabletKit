# TabletKit

**TabletKit** is a Human Interface Device (HID) decoder layer for drawing tablets on macOS. It turns raw USB and Bluetooth report bytes into structured pen, button, and touch events an app can act on. It contains no AppKit or event-injection plumbing; its only system dependency is IOKit HID, isolated in `HIDDeviceSupport.swift`.

TabletKit serves as the decoder for [**MockTab**](https://mocktab.org), an open-source macOS driver, mainly for older Wacom tablets ([source](https://github.com/Cyzor/tablet-driver)).

License: **MPL-2.0** — see [`LICENSES/MPL-2.0.txt`](LICENSES/MPL-2.0.txt).

TabletKit is an independent, community-built project. It is not affiliated with, endorsed by, or sponsored by Wacom Co., Ltd. or any other device vendor. Product names are used only to describe hardware compatibility.

## Layout

| Folder | Charter |
|---|---|
| `Core/` | Vocabulary types every other folder speaks: `DecoderState`, `DecodeResult`, `TabletReportDecoder`, geometry/math. No I/O. |
| `Decoders/` | One file (± transport extension) per report family, fixed-format and descriptor-driven alike. Pure structs, no IOKit. |
| `HID/` | HID mechanics: descriptor parsing, usage tables, interface classification, and the single IOKit-touching file `HIDDeviceSupport.swift`. |
| `Output/` | Host-to-device output protocols (payload builders), as opposed to decoding inbound reports. |
| `Registry/` | Device data and lookup. Data-as-code, maintained via `tools/`. |
| `Smoothing/` | Pure signal-conditioning math. |

## Adding to your project

```swift
// Package.swift
.package(url: "https://github.com/Cyzor/TabletKit.git", from: "0.2.0")
```

Then add `"TabletKit"` to your target's dependencies and `import TabletKit`.

## Usage

The core loop is:

1. Look up the device in the registry to get its `WacomDeviceSpec`.
2. Build a `DigitizerSpec` from the spec's coordinate and pressure ranges.
3. Allocate a `DecoderState` for this device instance.
4. On each HID report callback, call `decoder.decode(...)` and act on the results.

### Worked example — Wacom Intuos Pro M (PTH-660, USB)

```swift
import TabletKit
import IOKit.hid

// 1. Look up the device. PTH-660 USB product ID is 0x0357.
guard let spec = WacomDeviceRegistry.spec(for: 0x0357) else { fatalError("unknown PID") }

// 2. Build the digitizer dimensions from the registry entry.
var digiSpec = DigitizerSpec(
    maxX: spec.maxX,
    maxY: spec.maxY,
    maxPressure: spec.maxPressure,
    buttonCount: spec.buttonCount,
    hasTilt: spec.hasTilt,
    hasFingerTouch: spec.hasFingerTouch,
    maxTouchContacts: spec.maxTouchContacts
)

// 3. Allocate per-device state (one instance per physical device).
var state = DecoderState()

// 4. Select the decoder for this parser family.
//    spec.parser == .intuosV2 for the PTH-660.
var decoder = IntuosV2Decoder()

// Inside your IOHIDDevice report callback:
func handleReport(_ report: UnsafePointer<UInt8>, length: CFIndex) {
    let results = decoder.decode(
        report: report,
        length: length,
        spec: digiSpec,
        state: &state,
        deviceFamily: spec.family
    )
    for result in results {
        switch result {
        case .pen(let point):
            // point.x / point.y      — raw device units (0..spec.maxX / 0..spec.maxY)
            // point.normalizedPressure — 0.0–1.0 (use this for brush opacity, etc.)
            // point.tiltX / tiltY    — –1.0 to +1.0 (proportional, not degrees)
            // point.inProximity      — true while pen is hovering or touching
            print("pen at (\(point.x), \(point.y)) pressure \(point.normalizedPressure)")
        case .toolEnter(let identity):
            // identity.toolCode — Wacom tool code (look up in WacomToolCatalog for a name)
            print("tool entered: 0x\(String(format: "%04X", identity.toolCode))")
        case .aux(let buttons):
            // buttons.buttons          — [Bool] array, one entry per express key
            // buttons.touchRingActive  — true while a finger is on the ring
            // buttons.touchRingPosition — absolute position 0–71 (0x7F = no contact)
            let held = buttons.buttons.indices.filter { buttons.buttons[$0] }
            print("aux: keys=\(held) ring=\(buttons.touchRingActive ? buttons.touchRingPosition : 0xFF)")
        case .touch(let contacts):
            for contact in contacts {
                print("touch id=\(contact.id) at (\(contact.x), \(contact.y))")
            }
        case .wireless(let status):
            print("wireless: \(status)")
        case .mouseButton(let mask):
            print("mouse buttons: \(mask)")
        case .battery(let percent, let charging):
            print("battery: \(percent)%\(charging ? " charging" : "")")
        case .wheel(let index, let delta):
            print("wheel \(index): \(delta)")
        case .toolCompatibility(let note):
            print("compat: \(note)")
        case .none:
            break
        }
    }
}
```

### Selecting a decoder

The registry's `parser` field tells you which decoder to instantiate:

| `ReportParser` | Decoder | Covers |
|---|---|---|
| `.intuosV2` | `IntuosV2Decoder` | Intuos Pro gen 2 (PTH-460/660/860) |
| `.intuosV1` | `IntuosV1Decoder` | Intuos 1–2, Intuos4 (PTK), Intuos5 first-gen, Cintiq pen-displays |
| `.intuosV3` | `IntuosV3Decoder` | Intuos Pro current-gen (PTK-470/670/870) — experimental |
| `.intuos3` | `Intuos3Decoder` | Intuos3 (PTZ-xxx, 2003–2006) |
| `.cintiqV1` | `CintiqV1Decoder` | Cintiq 24HD, 22HD, 13HD, older pen displays |
| `.bamboo` | `BambooDecoder` | Bamboo Pen & Touch (CTL/CTH) — experimental |
| `.graphire` | `GraphireDecoder` | Graphire 2–4, Volito — experimental |
| `.dtus` | `DTUSDecoder` | DTK-1651, DTU-1031/1031X/1141 — experimental |
| `.dtu` | `DTUDecoder` | DTU-1631, DTU-2231 — experimental |
| `.xencelabs` | `XencelabsDecoder` | Xencelabs Pen Display 24 and Quick Keys puck confirmed on hardware (wired and wireless dongle); Pen Tablet Medium/Small share the protocol but are hardware-unverified |

**Naming note:** `IntuosV1`/`V2`/`V3` name TabletKit's own protocol generations, not Wacom's marketing generations — `.intuosV1` covers Intuos5 hardware, for instance. `Intuos3Decoder` (no "V") is unrelated to `IntuosV3Decoder`: it exists specifically because real Intuos3 (PTZ-xxx) hardware uses an incompatible status-byte layout despite sharing IntuosV1's report shape. Don't infer a hardware generation from the "V" number.

`WacomDeviceRegistry` covers Wacom devices. `VendorDeviceRegistry` covers other vendors; use `VendorDeviceRegistry.drivableProfile(forVendorID:productID:)` to look those up.

### Device init handshake

Some devices require a feature report before they will stream pen data. Check `spec.initSteps` and send each `.featureReport(_:)` step via `IOHIDDeviceSetReport`. Intuos Pro and Cintiq devices need this; Bamboo and older devices generally do not.

## Tests

```
swift test
```

runs the 346-test suite against fixture captures from real devices. No Xcode project required.

## Versioning

Follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and will adopt [SemVer](https://semver.org/spec/v2.0.0.html) after 1.0. Before 1.0, minor versions may break source compatibility.

## Acknowledgments

TabletKit's protocol knowledge and device data draw from several open-source projects:

- **[OpenTabletDriver](https://github.com/OpenTabletDriver/OpenTabletDriver)** — the non-Wacom registry entries come from OTD's per-vendor JSON configurations, the most comprehensive public database of tablet PIDs and dimensions across vendors.
- **[libwacom](https://github.com/linuxwacom/libwacom)** — libwacom's tablet files are the authoritative source for Wacom physical dimensions; they cross-check and correct entries where the kernel's constants are inaccurate.
- **[input-wacom](https://github.com/linuxwacom/input-wacom) / Linux kernel HID subsystem** — the kernel driver is the canonical reference for Wacom report formats and protocol constants; several decoder field mappings follow kernel source directly.
- **[wacom-hid-descriptors](https://github.com/linuxwacom/wacom-hid-descriptors)** — the linuxwacom HID descriptor corpus informed decoder development across multiple tablet families.

## Contributing

Device profiles, decoder additions, bug fixes with capture-log fixtures, and metadata corrections all fit here; UI and app-level issues belong on the [MockTab repo](https://github.com/Cyzor/tablet-driver). See [`Contributing.md`](Contributing.md) for scope and submission format. Forking is also an option, which the MPL-2.0 arrangement supports.
