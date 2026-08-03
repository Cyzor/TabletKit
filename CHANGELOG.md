# TabletKit Changelog

This changelog covers the `TabletKit` Swift package (the decoder layer defined in `Package.swift`).
The MockTab app tracks its own version in `MockTab/Info.plist` and maintains separate release notes in `release-notes/`.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and will adopt [Semantic Versioning](https://semver.org/spec/v2.0.0.html) after 1.0. Before 1.0, minor versions may break source compatibility.

## [Unreleased]

### Added

- `GenericPenLayout` / `GenericPenDecoder` — a descriptor-driven pen
  digitizer decoder, the pen counterpart to `PrecisionTouchLayout`.
  Reads tip switch, in-range, barrel/secondary barrel, eraser, invert,
  X/Y, tip pressure, tilt, twist, and hover distance from a device's own
  report descriptor rather than a hardcoded per-family byte table.
  Modern Wacom hardware declares these on its vendor page using the
  standard Digitizer usage numbers `DigitizerUsage` recognizes —
  confirmed field-for-field against a real Cintiq Pro 24 (DTH-2420)
  descriptor, both pen report variants it declares.

- `DescriptorLayout.modeSwitchFeatureReportID()` and the
  `modeSwitchUsages` list behind it — the report ID a device declares
  for switching into full reporting, vendor control preferred over the
  standard one. Returns nil for classic hardware, which declares
  neither, so callers keep whatever legacy write they used.

- ExpressKey Remote (0x0331) report structure recorded on its registry
  row: which bits in report 0x11 carry the eighteen controls, the ring
  position byte, and what per-action recordings could not settle. The
  row stays name-only — this is groundwork for an implementer with the
  hardware, not a decoder.

- `RepeatingReportStructureDetector` — finds repeating byte-stride
  structure in a report using only per-position variance statistics, no
  descriptor required. Exists for reports the descriptor-driven tools
  cannot help with — classic Wacom BT reports declare every field as
  opaque vendor usage, so there is nothing to derive a layout from —
  and confirmed against a real PTH-860 BT capture, where it recovers the
  kernel-documented 4×43-byte frame / 5×8-byte contact layout from
  statistics alone, plus a CTH-690 capture with no repeating structure,
  correctly reporting none.

- `PrecisionTouchLayout` / `PrecisionTouchDecoder` — a device-agnostic decoder
  for HID Precision-Touchpad-style multitouch reports (Contact Identifier,
  Contact Count, per-finger collections), the touch counterpart to
  `GenericDigitizerFrame`. The layout is derived from the device's own report
  descriptor via `HIDReportDescriptorParser` rather than hardcoded per family,
  so it carries its own axis maxima and adapts to slot counts and optional
  fields. No device path constructs one yet — every current touch decode still
  runs through the Wacom vendor-specific paths.
- `classifyDigitizerInterface` — decides whether an unrecognized HID interface
  may have a pen driver attached, by checking whether its X/Y usages sit inside
  a Digitizer Touch Screen or Touch Pad collection. Usages alone cannot tell pen
  from touch (both declare Generic Desktop X/Y and a Tip Switch); the enclosing
  application collection can. Fails open as `.undetermined` when no descriptor
  is readable. A `.touchOnly` verdict requires evidence of more than one
  contact — more than one finger slot, a contact count, or a per-slot
  contact identifier — because some pen tablets declare their stylus
  under a Touch Screen collection, and withholding the pen driver from
  one of those would leave it with no driver at all. Relative X/Y never
  counts as pen evidence — Windows Precision
  Touchpad devices must declare a legacy Mouse collection alongside their touch
  collection, and treating that as a pen would misclassify most touch hardware.
  Exists so hosts can avoid pointing a pen driver at a multitouch interface,
  where X/Y repeat once per finger and element values cannot be attributed to a
  contact.

### Fixed

- Active-area height on nine current-generation Wacom One/Intuos/Bamboo CTL
  and CTH registry rows (CTL-4100/4100WL ×4, CTL-472, CTL-480, CTH-480,
  CTL-490, CTH-490). Each carried a stale 102mm height against a maxY that
  already meant 95mm — confirmed against Wacom's Important Product
  Information booklets for each cluster (CTL-4100 family, One by Wacom
  CTL-472/672, Intuos CTL-480/680 and CTH-480/680, Intuos Pen/Pen&Touch
  CTL-490/690 and CTH-490/690). Widths, and every other row already checked
  in this pass (CTL-6100 family, CTL-672, CTL-680, CTL-690, CTH-690,
  CTL-671), were already correct.
- Active-area dimensions on four Intuos5/Intuos Pro first-gen registry rows
  (PTH-450, PTH-650, PTH-850, PTH-451). Confirmed against Wacom's own
  Important Product Information booklet for the line and OpenTabletDriver's
  configs. Also surfaced, but deliberately left unfixed: all four confirmed
  touch-capable devices (PTH-450/650/850/451/651/851) carry no
  `hasFingerTouch` in the registry, and MockTab has never decoded their touch
  reports — a real coverage gap, not a spec question, and outside what a
  manual can resolve on its own.
- Active-area dimensions on two Intuos3 (PTZ-xxx) registry rows, PTZ-1231W
  and PTZ-431W. Coordinate ranges for the whole seven-model family were
  already exact matches against OpenTabletDriver's independently-declared
  values; only these two rows' mm fields disagreed with their own maxX/maxY.
  Confirmed against Wacom's own Intuos3 User's Manual.
- Active-area dimensions on twelve Intuos4/Bamboo-family registry rows
  (0x00B8/B9/BA/BB, 0x00D1/D2/D6/D7/D9/DA/DC/DD/DE, 0x0300) didn't match
  their own already-correct maxX/maxY — the mm fields were stale or
  copy-paste estimates, some off by close to 10%. Feeds real scaling math
  (`DisplayMapper`'s relative-mode cursor speed) and the active-area diagram,
  not just display text. Corrected against Wacom's own Intuos4 and Bamboo
  460-family User's Manuals. Two touch-only rows (CTT-460, CTT-460A) were
  deliberately left alone — their true touch coordinate space versus the
  pen-chassis mm they currently borrow is still an open question, not
  something a manual cross-check alone can settle.
- Coordinate ranges for every Intuos 1 and Intuos 2 registry row. Each carried
  a plain 16-bit range, but `IntuosV1Decoder` appends a 1-bit fractional
  extension to X and Y, so the values it emits span twice that. Every one of
  these tablets mapped only its top-left quadrant across the full screen.
  A field report and a capture confirmed the bug and its direction on a
  GD-0608-U (0x0021); the corrected values across the whole family — X/Y and
  active-area mm alike — are cross-checked against Wacom's own Intuos (GD)
  User's Manual and against OpenTabletDriver's GD-*/XD-* configs, whose
  independently-written parser decodes X/Y/tilt with the same bit formulas
  ours does and declares the same maxima for every PID in the family. Three
  rows (Intuos 4×5, 9×12, 12×12/12×18) also had an unrelated pre-existing
  active-height error corrected (102/229/305 mm → 106/241/317 mm), found via
  the same manual cross-check.

## [0.3.0] — 2026-07-22

Xencelabs hardware support (display, Quick Keys, dongle), a device-agnostic
generic digitizer decoder, a Bamboo Pen Tablet (CTL-460), pressure/stabilization
filter overhaul, and a source reorganization into topic folders.

### Added

- `GenericDigitizerFrame` — a device-agnostic decoder path for HID digitizers
  that expose standard Usage Page 0x0D elements but have no dedicated Wacom
  decoder, gated by `BrandHeuristic` USB-string matching.
- CTL-460 Bamboo Pen Tablet identity and mode-2 feature-report decoding.
- Xencelabs Pen Display 16 registry entry, brightness/contrast/gamma/color-mode
  controls, and bezel-button backlight command.
- Xencelabs Quick Keys: screen orientation command, dial custom colors per
  mode, battery-level decoding, wireless dongle support (shares the wired
  puck's identity), and correct handling of config-reply frames that were
  previously misread as button presses.
- Onboard bezel button decoding for the DTK-2400 and Xencelabs displays.
- Touch and express-key support for the Intuos Art tablet.
- `PressureSmoother` — a 1€-filter-based pressure smoother (companion to
  `CursorSmoother`) that damps sensor noise at light touch without dulling
  firm strokes.
- Recognition-only registry rows for the Wacom MobileStudio Pro line:
  13" (0x034D gen 1, 0x0398 gen 2) and 16" (0x034E gen 1, 0x0399 gen 2,
  0x03AA alt). Dimensions derived from libwacom physical size at 5080 LPI;
  parser guess is `.intuosV2` — the kernel drives these via descriptor-based
  generic HID, so promotion requires a user capture. Touch lives on separate
  paired USB devices (0x034A/0x034B/0x039A/0x039B/0x03AC) and is not claimed.
- USB string brand heuristic for recognizing uncataloged tablets by vendor name.
- `tablet-decode` sample executable target, demonstrating the decode loop
  end-to-end against a captured report log.
- Tag-triggered release workflow (`.github/workflows/release.yml`): runs the
  test suite, pulls that version's `CHANGELOG.md` section for release notes,
  and creates a draft GitHub Release.

### Changed

- `CursorSmoother`'s stabilization replaced its flat exponential-moving-average
  with a 1€ filter (Casiez et al.) — cutoff now scales with estimated stroke
  speed, easing off during fast strokes instead of lagging evenly throughout.
- Product-identity and dimension corrections across current-generation Wacom
  tablets, cross-referenced against libwacom.
- Sources reorganized from a flat `Sources/TabletKit/` directory into
  `Core/`, `Decoders/`, `Registry/`, `Smoothing/`, and `HID/` folders; two
  oversized, misleadingly named files (`TabletDevice.swift`, `WacomToolSpec.swift`)
  split along their actual concerns. No public API changed — pure file motion.
- File headers changed from the MockTab app's header to a TabletKit-specific
  one, reflecting the package's independent MPL-2.0 licensing.

### Fixed

- Intuos5 pad report decoding: express keys and the ring button now decode
  correctly (byte-layout correction from a real PTH-850 capture).
- Xencelabs cursor tracking, which was reading a truncated pen position.
- Simulated modifier-key events now look identical to real key presses to
  apps that distinguish synthetic input.
- Stale doc comment referencing a retracted PTH-660 wireless product ID.
- README inaccuracies: an "no IOKit" claim (IOKit HID is used, isolated in
  `HIDDeviceSupport.swift`) and a stale test count.
- Published the missing GitHub Release for the `0.2.0` tag, which had been
  pushed but never published.

## [0.2.0] — 2026-06-10

First non-Wacom decoder, a registry sweep against the Linux input-wacom device
table, and several product-identity corrections.

### Added

- `XencelabsDecoder` — experimental decoder for the Xencelabs Pen Tablet
  Medium (0x28BD:0x5201) and Small (0x5204), ported from OpenTabletDriver's
  parser sources. Pen (position, 8191-level pressure, tilt, eraser, three
  barrel buttons), express keys, and relative wheels. Not yet validated on
  hardware; requires the `[0x02, 0xB0, 0x04]` output-report init.
- `ReportParser.xencelabs` case and the matching `"xencelabs"` family string.
- `VendorDeviceRegistry.drivableProfile(forVendorID:productID:)` — hand-
  maintained allowlist marking which non-Wacom profiles have a working
  decoder, separate from the bulk-imported recognition data.
- Registry sweep from the input-wacom kernel device table (~36 entries):
  decoder-family matches with kernel dimensions (Bamboo1 Medium, Intuos2 6×8
  alt PID, Volito2 2×3, PenPartner2, DTK-2241, DTH-2242, Cintiq 20WSX,
  Bamboo Pen 6×8, Cintiq 27QHD pen/touch, Cintiq 13HD Touch) plus a
  name-only tier (`maxX: 0`, never routed to a driver) covering the PL
  display line, companion touch-sensor interfaces, the ExpressKey Remote,
  and the DFU bootloader PID.
- `canonicalPIDMap` rows for Intuos4 WL (0x00BD → 0x00BC), Intuos BT S/M
  (0x03C6/0x03C8 → CTL-4100WL/6100WL), and PTH-460 BT (0x0393/0x03DD), with
  a test asserting every map target has a registry entry.

### Changed

- Registry lookups (`spec(for:)` and the product-string overload) are now
  dictionary-indexed by PID instead of linear scans.
- Product-identity corrections sourced from input-wacom/libwacom/OTD:
  - 0x0352 is the **Cintiq Pro 32 (DTH-3220)**, not "Intuos Pro S"; the real
    PTH-460 is 0x0392/0x03DC USB and 0x0393/0x03DD BT (entries promoted to
    cross-referenced with ring, touch, and kernel coordinates). The
    fabricated 0x035B entry and the dangling 0x035F mapping are gone.
  - 0x0003 is the **Cintiq Partner (PTU-600)**, not PenPartner; the real
    PenPartner is 0x0000. Both are name-only (PTU/PENPARTNER report
    families have no decoder).
  - 0x009A is the **ISDv4 9A** built-in digitizer, not a wireless receiver.
  - 0x0301 is kernel "Bamboo One M" — renamed, moved to the bamboo parser,
    dimensions corrected.
  - Dimension drift fixes vs kernel feature structs: Cintiq 22HD, 22HD
    Touch, Cintiq Companion 2.
- BLE/Bluetooth and wireless doc comments corrected where they referenced
  the wrong PTH-460/PTH-860 PIDs.

### Removed

- `typealias WacomDecoder = TabletReportDecoder` — the source-compatibility alias kept in 0.1.0 is gone. All conforming decoders and any `any WacomDecoder` annotations now use `TabletReportDecoder` directly.

## [0.1.0] — 2026-05-28

Introduces the first public API. Extracted from the MockTab app so the decoder layer can stand alone.

### Added

- `TabletReportDecoder` protocol — vendor-neutral entry point that converts one HID input report into `[DecodeResult]`. Replaces the internal `WacomDecoder`; keeps `typealias WacomDecoder = TabletReportDecoder` temporarily for MockTab source compatibility (to be removed before 1.0).
- Public value types: `DecodeResult`, `TabletPoint`, `ToolIdentity`, `AuxButtons`, `TouchContact`, `WirelessStatus`, `DigitizerSpec`, `DecoderState`.
- `WacomDeviceRegistry`, now public in the package target, with:
  - `spec(forProductID:productString:)` overload for USB string disambiguation (prepares for vendors like Huion that reuse PIDs across models).
  - `activeWidthMM` / `activeHeightMM` on `WacomDeviceSpec` and derived `lpi: (x:, y:)?`. Hand-measured six `.verified` devices (PTZ-631W, PTH-851, PTH-660, PTH-860 USB + BT, DTK-2400); backfilled 78 entries from libwacom `.tablet` files; filled 22 more using Wacom's 2540 LPI consumer standard or direct spec sheets; filled 11 more (Graphire `0x0010`/`0x0011`/`0x0013`/`0x0015`, Volito `0x0060`/`0x0062`, PenStation2 `0x0061`, DTU-1031 `0x00FB`, Bamboo One `0x0069`, Bamboo Pad `0x0318`/`0x0319`) from libwacom data, falling back to `input-wacom` 4.18 features tables only where libwacom has no entry. The libwacom verification pass also corrected six previously-kernel-derived values where the family-wide resolution constants (`WACOM_VOLITO_RES`, `WACOM_INTUOS_RES`) proved approximate — the Volito 0x0060 height was off by 25%, DTU-1031 height by ~10%, the Graphire 4×5 family height by ~10%. Now 128 of 135 entries include physical dimensions (up from 6); the remaining 7 are four early Graphire/Bamboo variants whose PIDs collide between libwacom, kernel, and OTD, and three wireless receivers (no active area). An LPI consistency check rejected libwacom rows that conflicted with `maxX`/`maxY` ratios (including incorrect Movink 13 data), substituted with Wacom specs instead.
  - `InitStep` enum replaces `featureInit`, `featureInit2`, and `featureInit2Delay` with ordered `initSteps: [InitStep]`. Cases: `.featureReport`, `.outputReport`, `.delay`, `.stringDescriptor` (the latter two reserved for future vendor init flows such as Xencelabs and Huion).
  - Promoted 4 entries from `.experimental` to `.crossReferenced` after auditing against `linuxwacom/wacom-hid-descriptors`: Graphire (`0x0010`), Intuos3 6×8 (`0x00B1`), Cintiq Pro 27 (`0x03C0`), Cintiq Pro 22 (`0x03D0`).
  - Added 12 recognition-only entries from real linuxwacom sysinfo dumps: Cintiq Pro 16 (`0x0350`/`0x0354`), Cintiq Pro 17 (`0x03C4`), Cintiq Companion 2 (`0x0325`/`0x0326`), One Pen Display 13 (`0x03CB`), DTH134 (`0x03EC`), DTC121 (`0x03CF`/`0x03ED`/`0x4900`), Movink 13 alt PID (`0x03F2`), Intuos BT M (`0x0379`). Marked `.experimental`; pen decode remains unverified.
- `VendorDeviceProfile` and `VendorDeviceRegistry` — vendor-neutral recognition for non-Wacom tablets. Imported 154 profiles from OpenTabletDriver (Huion, Xencelabs, XP-Pen). No decoder dispatch yet; the app can identify but not decode these devices. Lookup returns `[Profile]` (not `Profile?`) because some vendors multiplex many models behind one PID and distinguish them via USB string descriptors.
- `TabletManager` expands IOHIDManager matching from Wacom (`0x056A`) to include Huion (`0x256C`), Xencelabs / XP-Pen (`0x28BD`), and UC-Logic (`0x5543`). The system looks up non-Wacom devices in `VendorDeviceRegistry`, logs them (`recognized Huion device — H1060P (…) — no decoder support yet`), and ignores them. Previously, the app did not detect these devices.
- `CaptureLogParser` (test target) parses both the in-app HID capture format and the upstream `hid-recorder` format (https://github.com/hidutils/hid-recorder) into `[CaptureRecord]`. This enables rapid regression tests: parse a user log, replay it through a decoder, and assert on `[DecodeResult]`.
- SwiftPM `library` product: `TabletKit`.
- Per-file MPL-2.0 SPDX headers for all files in the TabletKit target.
- `LICENSES/MPL-2.0.txt`.

### Changed

- Renamed SwiftPM target `MockTabDecoders` → `TabletKit`. Downstream code now imports `TabletKit`. Renamed test target to `TabletKitTests`; kept on-disk path `Tests/MockTabDecodersTests/` for now.
- Updated `WacomDeviceSpec`: replaced `featureInit`, `featureInit2`, and `featureInit2Delay` with `initSteps: [InitStep]`. Migrated existing Intuos3 PTZ sequences directly to `[.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])]`. Preserves behavior for all supported devices.

### Notes

- The MockTab app remains GPL-3.0-or-later; this package uses MPL-2.0. See `README.md` for the dual-license rationale.
