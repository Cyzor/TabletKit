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
  fields. As of 2026-08-06, `WacomKnownDevice` derives one for any touch
  report ID `IntuosV2Decoder` doesn't reserve — this is what fixed touch on
  Cintiq Pro/DTH devices whose reports were previously discarded by a
  report-ID dispatch gap.

- Backfilled `touchMaxX`/`touchMaxY` on five Cintiq Pro/DTH registry entries
  (0x0350, 0x0354, 0x03C0, 0x03C4, 0x03EC) from the `linuxwacom/wacom-hid-descriptors`
  corpus, with provenance comments on each row.

### Fixed

- `IntuosV2Decoder`'s report-ID dispatch had no case for `0x0C`, silently
  discarding every touch report from Cintiq Pro/DTH pen displays. Touch
  frames on those devices now decode via `PrecisionTouchDecoder`.

### Removed

- `XencelabsControl`, the deprecated typealias left behind when the type was
  renamed to `XencelabsOutputProtocol`. Source-breaking for anything still
  using the old name; the replacement has an identical surface, so the fix is
  a rename. Recorded in `api-breakage-allowlist.txt`.

### Changed

- `TouchContact.init` gained a defaulted `contactMinor` parameter, which the
  Swift API digester flags as a source-compatible but symbol-breaking change
  (see `api-breakage-allowlist.txt`).
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

### Changed

- `XencelabsControl` renamed to `XencelabsOutputProtocol` (moved from
  `Control/` to `Output/`) — the old name read as ambiguous next to
  the report decoders. `XencelabsControl` remains available as a
  deprecated typealias.

### Fixed

- Coordinate range and active area on the Bamboo Touch CTT-460 registry row
  (`0x00D0`), settled by a real hid-recorder capture from the
  bentiss/hid-devices corpus (analysis only — the trace itself is unlicensed
  and not vendored). The touch interface's own HID descriptor declares
  logical max 480×320 and physical max 120×80mm; the capture's touch events
  stay inside that range with Y nearly reaching its max; and the kernel's
  `WACOM_QUIRK_BBTOUCH_LOWRES` quirk (raw values shifted left by 5) confirms
  the kernel's nominal 14720×9200 was never the wire format. Corrected
  14720×9200/127×76mm → 480×320/120×80mm and upgraded the row to verified
  confidence. The two later-generation touch-only siblings (CTT-460A
  `0x00D9`, CTT-470 `0x00DC`) likely use the BBTOUCH3 4096×4096 space
  instead, but no capture covers them — annotated as suspect, values left
  alone. Touch decoding for all three remains an open coverage gap.
- Active-area dimensions on both Cintiq 16 (DTK-1660) registry rows
  (356×203mm → 348×198mm), corrected toward OpenTabletDriver's precise value
  after Wacom's own DTK-1660 manual pointed the same direction.
- Parser assignment on two registry rows (`0x0300` "Wacom CTL-471", `0x00DE`
  "Wacom CTH-470"), reassigned `.intuosV1` → `.bamboo` (little-endian, no
  fractional-bit doubling). Both were flagged as suspect on 2026-08-03 from
  documentation alone and left unfixed pending confirmation; the evidence was
  since upgraded by a third independent primary source — libwacom's own
  `.tablet` files for both PIDs (`wacom-one-by-wacom-s-p.tablet`,
  `wacom-bamboo-16fg-s-pt.tablet`) explicitly label them "third generation
  BambooPT", `Class=Bamboo`, the same family `BambooDecoder`'s own doc
  comment already used to describe the little-endian report path. Combined
  with OpenTabletDriver's independent parser choice for both PIDs (the same
  little-endian family) and, for CTL-471, an active-area figure a fourth
  source (a community tablet-spec mastersheet) also confirms at 152×95mm,
  three-to-four convergent sources now outweigh the prior `.intuosV1` value,
  which was already known wrong from the active-area mismatch alone.
  CTL-471's coordinates were also corrected (14720×9225 → 15200×9500) to
  match; CTH-470's coordinates (14720×9200) were already correct — only its
  parser was wrong. Still no hardware capture for either; one through
  `tools/hid_input_capture.c` remains the definitive check.
- Active-area dimensions on five Kernel-sweep Cintiq registry rows: 13HD
  (DTK-1300), 13HD Touch (DTH-1300), 22 (DTK-2241), 22 Touch (DTH-2242), and
  20WSX (DTZ-2000W). Four had no mm data at all; DTK-1300 had a stale value.
  Every row's existing maxX/maxY was already exactly right — three pairs
  divide out to their manual's stated active area with no rounding at all —
  so only mm was ever in question here. This closes out the "Kernel sweep"
  section's remaining spec-shaped gaps; what's left there (undecoded report
  families, unconfirmed touch-sensor byte layouts, a partially-reverse-
  engineered accessory) needs a decoder or a hardware capture, not a manual,
  and was left alone accordingly.
- Active-area dimensions on the Bamboo/Graphire-era CTE/CTF consumer line
  (CTE-450, CTE-460, CTE-660, CTF-430), against Wacom's Bamboo Fun
  (CTE-450/650) manual. CTE-650 was already exactly right and needed no
  change; CTE-660 shared CTE-650's coordinate range but disagreed with it on
  mm at no plausible resolution, and CTE-460/CTF-430 had no mm data at all.
- Active-area dimensions on nine Graphire-family registry rows (original
  Graphire ×2, Graphire 2/3/4 4×5, Graphire 3/4 6×8, Bamboo1 Medium), against
  Wacom's own Graphire and Graphire4 manuals. All had a stale height carried
  over from a copy-paste, unrelated to their own already-correct maxX/maxY.
  Checked the original Graphire's coordinate range against the manual's
  arithmetic first and found it would have been wrong — OpenTabletDriver's
  hardware-measured value matches the registry's existing figure exactly, not
  what the manual's printed "coordinate resolution" implies — so left
  coordinate ranges alone everywhere in this family and corrected only the
  dimensions the manuals directly and unambiguously settle. Volito's height
  was left as a three-way disagreement between libwacom, a kernel constant,
  and this pass's own manual reading, with no hardware capture available to
  arbitrate; documented rather than resolved.
- Active-area dimensions on three Cintiq pen-display registry rows. Cintiq
  24HD Touch (0x00F8) had a wrong active area (533×330mm) against its own
  confirmed-live sibling (Cintiq 24HD, 0x00F4) sharing the identical panel
  and maxX/maxY — corrected to match. Cintiq 27QHD and 27QHD Touch (0x032A,
  0x032B) had no activeWidthMM/Height at all — added, from Wacom's own
  DTK-2700/DTH-2700 Important Product Information booklet. Also checked but
  deliberately left unchanged: Cintiq Pro 24 pen-only (0x037C) and Cintiq Pro
  32 (0x0352) each disagree with their manual's stated *display* active area
  by several mm, but one already carries a real captured logical-maximum
  value and the other a libwacom-sourced one — a display's active area and a
  digitizer's logical maximum aren't guaranteed to be the same fact, so
  neither was overwritten on a manual's word alone.
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
