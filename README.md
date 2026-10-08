# TabletKit

**TabletKit** reads the raw data a drawing tablet sends over USB or Bluetooth and turns it into pen, button, and touch events. It powers [MockTab](https://mocktab.org), an open-source macOS driver for older Wacom tablets ([source](https://github.com/Cyzor/tablet-driver)). It has no dependencies beyond macOS's own IOKit, and it leaves moving the cursor to your app.

## Add It to Your Project

```swift
// Package.swift
.package(url: "https://github.com/Cyzor/TabletKit.git", from: "0.5.0")
```

Then add `"TabletKit"` to your target's dependencies and `import TabletKit`.

## Quick Start

```swift
import TabletKit

// Look up the tablet by its USB product ID (0x0357 is the Intuos Pro M).
guard let spec = WacomDeviceRegistry.spec(for: 0x0357) else { fatalError("unknown tablet") }

// The registry knows which decoder each tablet needs.
var decoder = spec.parser.makeDecoder()

// Keep one state per connected tablet.
var state = DecoderState()

// Call this from your HID report callback.
func handleReport(_ report: UnsafePointer<UInt8>, length: CFIndex) {
    let results = decoder.decode(
        report: HIDReport(pointer: report, count: length),
        spec: spec.digitizerSpec,
        state: &state,
        deviceFamily: spec.family
    )
    for result in results {
        switch result {
        case .pen(let point):
            // x and y are in tablet units; pressure runs 0 to 1.
            print("pen at (\(point.x), \(point.y)), pressure \(point.normalizedPressure)")
        case .aux(let buttons):
            print("keys held: \(buttons.buttons.indices.filter { buttons.buttons[$0] })")
        case .touch(let contacts):
            print("\(contacts.count) fingers down")
        default:
            break
        }
    }
}
```

Besides pen, buttons, and touch, a decoder reports when a pen comes into range (`.toolEnter`), mouse buttons and wheels, battery level, and wireless status.

### Switch the Tablet On

Most Wacom tablets start in a reduced mode, where pressure, tilt, or a side button may be missing. Each registry entry lists the commands that switch it to full reports in `spec.initSteps`. Send them once after the tablet connects.

[Building a Minimal Driver](Sources/TabletKit/TabletKit.docc/BuildingAMinimalDriver.md) walks through finding the tablet, switching it on, and moving the cursor, with a working sample you can run.

## Supported Tablets

- `WacomDeviceRegistry` covers Wacom tablets, pen displays, and accessories.
- `VendorDeviceRegistry` covers Xencelabs, Huion, XP-Pen, and other brands. Look them up with `drivableProfile(forVendorID:productID:)`.
- [`registry.json`](registry.json) holds the same list for scripts, websites, and drivers on other platforms.

Decoder names like `IntuosV1` and `IntuosV3` count report formats, not Wacom product generations. `IntuosV1Decoder` handles the Intuos5, for example, and `Intuos3Decoder` has nothing to do with `IntuosV3Decoder`.

## Build and Test

```
swift test
```

Tests run against recordings from real tablets. No Xcode project is needed.

```
tools/build-docs.sh
```

This builds the documentation and prints where it saved it. Open that path to browse it.

Before 1.0, a minor version may require changes to your code. See the [changelog](CHANGELOG.md).

## Contributing

The TabletKit project welcomes tablet profiles, decoder additions, bug fixes with recordings, and corrections. Problems with the MockTab app itself belong in the [MockTab repo](https://github.com/Cyzor/tablet-driver). See [`Contributing.md`](Contributing.md).

## Thanks

- [OpenTabletDriver](https://github.com/OpenTabletDriver/OpenTabletDriver): IDs and sizes for tablets from other brands
- [libwacom](https://github.com/linuxwacom/libwacom): Wacom physical sizes, including corrections to the Linux kernel's figures
- [input-wacom](https://github.com/linuxwacom/input-wacom): Wacom report formats, which several decoders follow closely
- [wacom-hid-descriptors](https://github.com/linuxwacom/wacom-hid-descriptors): report layouts across many tablet families

## License

[MPL-2.0](LICENSES/MPL-2.0.txt). TabletKit is an independent, community-built project. Wacom Co., Ltd. and other vendors don't endorse or sponsor it. Product names here only describe compatibility.
