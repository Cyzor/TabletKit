// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
//
// Entries below are mixed-provenance: some hand-authored and hardware-verified,
// some bulk-imported from OpenTabletDriver's Wacom JSON configs via
// `tools/import_otd_configs.py`, and some backfilled from libwacom's `.tablet`
// dimension files via `tools/backfill_libwacom_dimensions.py`. No source data
// (protocol constants, dimensions, PIDs) is copyrightable expression, but the
// import/backfill tools exist specifically to keep entries traceable back to
// their source rather than presenting them as uniformly hand-derived.

import Foundation

// MARK: - Report protocol family

/// Which HID report decoder handles this device family.
///
/// Used by `WacomDeviceRegistry` to route devices to the correct decoder.
/// The decoders in `Decoders/` are the live decode path; per-device app-side
/// glue (`WacomKnownDevice`) still handles device-specific setup such as init
/// steps, LED writes, and OLED labels, but no longer parses reports.
public enum ReportParser: String, Sendable {
    /// Graphire / early consumer line — Report ID 0x02
    /// (kernel `WACOM_REPORT_PENABLED`), 8 bytes.
    /// Covers PenPartner, Graphire 2–4, Volito, Bamboo One (CTF-430).
    /// No tool-change packets; eraser/pen/mouse detected via the tool field
    /// in status byte d[1] bits 5–6. Decoded by `GraphireDecoder`
    /// (experimental — not yet hardware-validated).
    case graphire

    /// IntuosV1 — Report ID 0x02/0x10, 10 bytes, BE16 coordinates.
    /// Covers Intuos 1–2, Intuos4 (PTK-xxx), Intuos5 (PTH-xxx first gen),
    /// and Cintiq pen-displays. Despite the similar byte layout, Intuos3
    /// (PTZ-xxx) is routed through the separate `.intuos3` case below —
    /// its status-byte proximity bit is incompatible (see `Intuos3Decoder`).
    /// Tool-change packets: status `(& 0xFC) == 0xC0`.
    /// 10–12 bit pressure depending on generation.
    case intuosV1

    /// IntuosV2 — Report ID 0x10, 192 bytes, LE24 coordinates, 13-bit pressure.
    /// Covers Intuos Pro second-generation (PTH-460/660/860) and newer.
    /// Also used over BLE HOGP (Report ID 0x01 pen, 0x03 pad).
    case intuosV2

    /// IntuosV3 — Report ID 0x1F (pen, 16-bit XY) or 0x1E (extended pen,
    /// 24-bit XY), with 0x11 aux carrying 10 buttons and two relative
    /// scroll wheels. Covers the PTK-470/670/870 Intuos Pro generation
    /// (OTD's `IntuosV3ReportParser`). Distinct byte layout from intuosV2
    /// — pen status byte at [2] not [1], pressure at [7..8] not [8..9],
    /// and 0x1E here is a different shape than intuosV2's offset report
    /// of the same ID. Experimental: no hardware verification yet.
    case intuosV3

    /// DTUS — small entry-level Cintiq / DTU pen displays. Pen report at
    /// ID 0x11 (7 bytes, BE16 coordinates, 10-bit pressure split across
    /// status byte and pressure byte); pad report at ID 0x15 (4 buttons in
    /// the low nibble of one byte). No tilt, no rotation, no hover. Covers
    /// DTK-1651 (0x0343), DTU-1031 (0x00FB), DTU-1031X (0x032F), DTU-1141
    /// (0x0336). Note: report ID 0x11 collides with IntuosV2's aux ID; per-
    /// decoder dispatch keeps them separate. Experimental.
    case dtus

    /// DTU — Wacom DTU pen-display family using the WACOM_REPORT_PENABLED
    /// (0x02) report format parsed by `wacom_dtu_irq`. Single pen report,
    /// 8 bytes: LE16 X/Y, 9-bit pressure, eraser inferred from tool-type
    /// bits. No pad buttons, no tilt. Covers DTU-1631 (0x00F0) and
    /// DTU-2231 (0x00CE). Distinct from DTUS: little-endian coordinates,
    /// 9-bit (not 10-bit) pressure, no pad report. Experimental.
    case dtu

    /// Bamboo — Report ID 0x10, 20 bytes, BE16 coordinates.
    /// Covers Bamboo Pen & Touch, Bamboo Craft/Comic/Fun series (CTL/CTH-xxx).
    /// Decoded by `BambooDecoder` (experimental — not yet hardware-validated).
    case bamboo

    /// Intuos3 (PTZ-xxx, 2003–2006) — same 10-byte IntuosV1 payload but with
    /// a different status-byte layout: bit 6 (0x40) is the proximity indicator
    /// (vs. bit 5 in IntuosV1).  Aux reports use IDs 0x03/0x0C, not 0x11.
    /// No BLE support.  Two-stage feature init (see `WacomDeviceSpec.initSteps`).
    case intuos3

    /// CintiqV1 — Wacom Cintiq pen-display family using the IntuosV1 10-byte pen
    /// report layout (same as PTH-851) plus a 0x0C aux report for touch rings and
    /// express keys, and a 0x01 tip-switch report that requires device seizure.
    /// Decoded by `CintiqV1Decoder` which handles the WACOM_24HD typeNibble dispatch,
    /// ABS_Z Art Pen rotation, barrel-button debounce, dual-ring 0x0C layout,
    /// tip-switch synthetic pressure, and incompatible-tool suppression.
    case cintiqV1

    /// Xencelabs Pen Tablet (VID 0x28BD) — 10-byte pen report dispatched on
    /// byte-1 flags, XP-Pen-shaped aux report.  The only non-Wacom parser;
    /// specs are synthesized at connect time from `VendorDeviceRegistry`
    /// rather than stored in this registry.  Requires the
    /// `[0x02, 0xB0, 0x04]` output-report init.  Decoded by
    /// `XencelabsDecoder` (experimental — not yet hardware-validated).
    case xencelabs
}

// MARK: - Init step

/// A single step in the device-activation sequence executed when an interface
/// is opened.  Steps run in order; a `.delay` suspends execution and schedules
/// the remainder on the main queue after the specified interval.
///
/// - `.featureReport(_:)`: HID SetReport (feature); first byte is the report ID.
/// - `.outputReport(_:)`: HID output report; first byte is the report ID.
///   Intended for Xencelabs init (`[0x02, 0xB0, 0x04]`) — not yet wired up.
/// - `.delay(_:)`: Pause before the next step, dispatched via `asyncAfter`.
/// - `.stringDescriptor(_:)`: Probe a USB string descriptor at the given index.
///   Intended for Huion frame-button activation — not yet wired up.
public enum InitStep: Equatable, Sendable {
    case featureReport([UInt8])
    case outputReport([UInt8])
    case delay(TimeInterval)
    case stringDescriptor(Int)
}

// MARK: - Confidence tier

/// How well-vetted a registry entry is. Drives UI honesty (e.g. an
/// "Experimental — please report issues" hint when the active device is
/// `.experimental`) and informs which entries are safe to promote.
///
/// - `.verified`: Hand-tested on real hardware in this project.
/// - `.crossReferenced`: Dimensions/parser agree between Linux input-wacom
///   and OpenTabletDriver; not personally hardware-tested but two
///   independent canonical sources concur.
/// - `.experimental`: Imported from a single source (typically OTD JSON or
///   kernel constants) without independent confirmation. May have wrong
///   dimensions, missing init reports, or only partial protocol support.
public enum ConfidenceTier: Sendable {
    case verified
    case crossReferenced
    case experimental
}

// MARK: - Device family

/// Coarse hardware-generation identifier, derived from a device's report
/// parser and name by ``WacomDeviceSpec/family``. Used to check tool
/// compatibility against ``WacomToolSpec/supportedFamilies``.
///
/// The set is closed and small: each case is one decoder generation the
/// project has actually characterised. Adding a case is a source break by
/// design — a new family that a `switch` fails to handle should not compile,
/// rather than fall through silently. Raw values are stable strings, kept
/// for logs and for the `Codable` round-trip on ``WacomToolSpec``.
public enum DeviceFamily: String, Codable, Sendable, CaseIterable {
    case graphire
    case intuos3
    case intuos4
    case intuos5
    case intuosProGen1
    case intuosProGen2
    case intuosProGen3
    case cintiq
    case dtu
    case dtus
    case bamboo
    case xencelabs
}

// MARK: - Per-device spec

/// All hardware parameters for a single Wacom USB or BLE product.
///
/// This table is the single source of truth for device names, coordinate
/// ranges, pressure depth, and initialisation requirements.  It drives
/// device-name display today and will route `WacomKnownDevice` once
/// Phase 3 decoders are in place.
///
/// Data sources, in descending priority for *physical dimensions*:
///   1. Live measurement on owned hardware (PTH-851, PTH-660, PTH-860, PTZ-631W, DTK-2400).
///   2. **libwacom** `.tablet` files (https://github.com/linuxwacom/libwacom) —
///      maintained per-device for hardware metadata; backfilled via
///      `tools/backfill_libwacom_dimensions.py`. Authoritative for any
///      Wacom-vid model it covers.
///   3. Linux **input-wacom** driver `drivers/input/tablet/wacom_wac.c` — its
///      `wacom_features_0x…` tables and family resolution constants
///      (`WACOM_PENPRTN_RES`, `_VOLITO_RES`, `_GRAPHIRE_RES`, `_INTUOS_RES`,
///      `_INTUOS3_RES`) are *approximations*. Reliable for `maxX`/`maxY`
///      device-unit coords; dimensions derived as `maxX / resolution` can be
///      off by ~10–25% (e.g. the kernel's Volito resolution constant
///      mis-estimates 0x0060 by 25%; libwacom is correct).
///   4. **OpenTabletDriver** configs `Configurations/Wacom/` — typically
///      derived from libwacom + kernel; useful tiebreaker but rarely the
///      primary source for Wacom hardware.
///   5. **linuxwacom HID descriptors corpus**
///      (https://github.com/linuxwacom/wacom-hid-descriptors) — drives
///      recognition-only newer-device entries and `.experimental` →
///      `.crossReferenced` promotions via `tools/audit_wacom_hid_descriptors.py`.
///
/// For *non-Wacom* hardware (Huion / Xencelabs / XP-Pen / UC-Logic) the
/// priority inverts: OpenTabletDriver configs are the primary public source
/// and the kernel rarely covers them.
/// Entries marked ⚠ are estimated from driver sources and unverified on
/// hardware; the `⚠ recognition-only` variant additionally means the parser
/// family and `maxX`/`maxY` are guesses by similarity — the device will be
/// named correctly but pen decode may produce nonsense until verified.
public struct WacomDeviceSpec: Sendable {
    public let productID: Int
    public let name: String
    public let parser: ReportParser
    public let maxX: Int
    public let maxY: Int
    public let maxPressure: Int
    /// Number of programmable express/side keys (0 if none).
    public let buttonCount: Int
    /// Number of onboard capacitive bezel buttons (e.g. the Cintiq DTK-2400's
    /// OSD keys), distinct from `buttonCount`'s express keys. 0 if none.
    public let bezelButtonCount: Int
    /// True if this model has a capacitive touch ring (Intuos Pro).
    public let hasTouchRing: Bool
    /// True if `hasTouchRing`'s control is a bare mechanical rotary encoder
    /// (rotation only, no finger-presence sensing) rather than the classic
    /// capacitive ring. Implies `hasTouchRing`; false = capacitive.
    ///
    /// PTK-470/670/870 (Intuos Pro gen 3) are the Wacom case: their HID
    /// descriptor names the control "Wacom TouchRing" for legacy usage-table
    /// consistency, but the device only ever reports rotation — there is no
    /// touchRingActive-equivalent finger-down signal, confirmed against a
    /// real PTK-870 capture (see `IntuosV3Decoder.decodeAuxReport`) and
    /// matching libwacom's own `Dial`/`Dial2` schema naming for this family,
    /// not `Ring`. Every other `hasTouchRing: true` row in this registry —
    /// PTH-family built-in rings, the EKR-100 puck — is genuinely capacitive.
    public let hasMechanicalDial: Bool
    /// True if this model has per-key OLED image displays on its express
    /// keys (Intuos4 family exclusively). Gates the Intuos4 OLED
    /// image-write protocol (`WacomOutputProtocol`) — kernel-confirmed via
    /// `wacom_sys.c`'s device-type dispatch: `intuos4_led_attr_group` (with
    /// the `button*_rawimg` sysfs files) is wired only to
    /// `INTUOS4S`/`INTUOS4`/`INTUOS4WL`/`INTUOS4L`. Intuos5/Intuos Pro get a
    /// different LED group with no image support at all, despite sharing
    /// the same `.intuosV1` parser as Intuos4.
    public let hasKeyOLEDs: Bool
    /// True if this model has two touch rings (one per bezel), e.g. Cintiq 24HD.
    /// Implies hasTouchRing.  The two rings are independently assignable.
    public let hasDualRings: Bool
    /// True if this model has dual capacitive touch strips (Intuos3 WS).
    public let hasTouchStrips: Bool
    /// True if this model has a capacitive touch surface for finger input in
    /// addition to the pen digitizer.  Gates the Touch settings pane and the
    /// touch-enable feature-report path.
    ///
    /// **This means "we can decode touch on this device", not "this device has
    /// a touch surface."**  It puts a whole Touch tab in front of the user, so
    /// setting it on hardware whose reports nothing can decode advertises a
    /// feature that cannot work.  Set it only where the device's parser has a
    /// touch path that actually reaches `.touch([TouchContact])`:
    ///
    /// - `.intuosV2` — yes, report 0x21 (`decodeTouchReport`).
    /// - `.intuosV1` — yes, via `BPT3ContainerDecoder`.
    /// - `.bamboo` — yes, two paths gated on this flag: the 20-byte
    ///   `decodeBPTTouch` (older CTH-460/461 chassis) and the 64-byte
    ///   `BPT3ContainerDecoder` path (INTUOSHT generation).
    /// - `.cintiqV1`, `.intuosV3` — **no touch decode exists.**  Rows in those
    ///   families were carrying this flag as of 2026-07-29 and were turned off;
    ///   several are genuinely touch-capable in hardware (Cintiq 22/24HD Touch,
    ///   27QHD Touch, 13HD Touch, Companion 2, Movink 13), and the flag should
    ///   come back the moment a decoder can serve them.  See the TODO at the top
    ///   of `CintiqV1Decoder` for what that needs.
    public let hasFingerTouch: Bool
    /// Maximum simultaneous touch contacts the device reports.  Zero when
    /// `hasFingerTouch == false`.
    ///
    /// Bounded by what the decoder can emit, not by the panel's advertised
    /// finger count: `.intuosV2`'s report 0x21 carries five fixed slots and
    /// caps at `min(count, 5)`, so five is the ceiling there no matter what a
    /// spec sheet claims.  Eleven rows said 10 until 2026-07-29.  `.intuosV1`
    /// via the BPT3 container reads up to 16.
    public let maxTouchContacts: Int
    /// Coordinate maximum for the capacitive touch sensor's X axis.
    /// Separate from `maxX` (pen digitizer); confirmed by live capture.
    /// PTH-860: 12439. PTH-660: 8960 (estimated, same 1/5 ratio as pen).
    /// Zero when `hasFingerTouch == false`.
    public let touchMaxX: Int
    /// Coordinate maximum for the capacitive touch sensor's Y axis.
    /// PTH-860: 8639. PTH-660: 5920 (estimated).
    /// Zero when `hasFingerTouch == false`.
    public let touchMaxY: Int
    /// Number of ring mode slots to expose in the UI.
    /// Defaults to 4, matching Wacom's standard 4-LED toggle ring layout.
    public let ringSlotCount: Int
    /// True if the pen family includes an eraser tool type.
    public let hasEraser: Bool
    /// True if this device's pen reports include tilt data (Bamboo 4-bit format).
    /// Has no effect on IntuosV1/V2/Intuos3 decoders, which always decode tilt.
    public let hasTilt: Bool
    /// Full-scale tilt angle in degrees for this family's wire tilt value, sourced
    /// from a HID descriptor or a kernel-cited constant — never estimated.
    /// `nil` means unknown: decoders must not substitute a guessed constant, and
    /// should keep the fraction unverified rather than silently claim an angle.
    public let tiltMaxDegrees: Double?
    /// True if this device is a pen display (Cintiq-class) with a built-in screen.
    /// Pen displays may need parallax offset calibration due to thick glass layers.
    public let isPenDisplay: Bool
    /// Ordered list of steps to execute when the interface is opened (USB/dongle only;
    /// skipped for BLE).  An empty array means no init is required.  The first byte
    /// of each `.featureReport` / `.outputReport` payload is the HID report ID.
    ///
    /// Most devices need a single `.featureReport([0x02, 0x02])`.  Intuos3 (PTZ-xxx)
    /// devices need a two-stage sequence with a 150 ms pause between the stages:
    /// `[.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])]`.
    public let initSteps: [InitStep]
    /// True if this interface must be seized (kIOHIDOptionsTypeSeizeDevice)
    /// to prevent macOS's built-in HID mouse driver from consuming reports.
    public let seizeUSB: Bool
    /// Product ID of a companion USB interface that handles LED control separately.
    /// When a Wacom device with this PID is enumerated but has no digitizer elements,
    /// TabletManager routes it to this device's WacomKnownDevice as an LED target
    /// rather than attaching a fallback driver or skipping it entirely.
    /// nil = LED control uses the main digitizer interface (single-interface devices).
    public let ledCompanionPID: Int?
    /// How well-vetted this entry is (see `ConfidenceTier`).
    /// Defaults to `.experimental` — promote explicitly when verified.
    public let confidence: ConfidenceTier
    /// Active-area width in millimetres.  Optional because the registry was
    /// built around device-unit coordinates (`maxX`/`maxY`); physical
    /// dimensions are backfilled incrementally as they're confirmed.
    ///
    /// When present, lets the cursor-mapping layer compute LPI per axis
    /// (`maxX / activeWidthMM × 25.4`) and offer 1:1 mm mapping in the
    /// tablet-area UI.  Matches the canonical (mm, logical-max) data shape
    /// used by Huion and Xencelabs references, easing future cross-vendor
    /// support.  Nil = unknown.
    ///
    /// **What this measures:** the physical extent of the `maxX`/`maxY` logical
    /// coordinate range — not the drawing area a spec sheet advertises.  The
    /// two usually agree to within a percent or two, but they are different
    /// quantities, and `lpi` above only means anything under the first
    /// reading.  Sources, best first:
    ///
    /// 1. The device's own HID report descriptor: `Physical Maximum` scaled by
    ///    `unitExponent` (see `Extending-Support.md`).  Exact by construction,
    ///    since it describes the same range `maxX`/`maxY` come from.
    /// 2. Hand measurement of the active surface.  Six `.verified` rows use it.
    /// 3. libwacom's `.tablet` `Width`/`Height`, which is manufacturer-
    ///    advertised and therefore an *approximation* of (1).  Most rows hold
    ///    this, simply because a descriptor capture usually is not available.
    ///    Rows whose libwacom figure disagreed with the `maxX`/`maxY` aspect
    ///    ratio were rejected during the backfill rather than stored.
    ///
    /// Where a row's value came from is recorded in that row's own comment
    /// (`✓ confirmed live`, `cross-referenced: libwacom`, `⚠ from OTD`, and so
    /// on).  Mixed provenance across rows is expected: the definition is
    /// uniform, the accuracy is not.  0x0351 (Cintiq Pro 24 touch) documents a
    /// worked example where (1) and (3) diverge by ~4% horizontally.
    public let activeWidthMM: Double?
    /// Active-area height in millimetres.  See `activeWidthMM`.
    public let activeHeightMM: Double?
    /// Optional substring matched against the device's `kIOHIDProductKey`
    /// string when multiple specs share a `productID`.  Used to disambiguate
    /// vendor PID collisions — Wacom has none today, but the plumbing is
    /// shared with future Huion support (Huion PIDs `0x006D`/`0x006E` each
    /// cover dozens of distinct models, discriminated only by firmware
    /// string).  Case-insensitive substring match.  Nil = match any.
    public let productStringMatch: String?

    public init(
        productID: Int, name: String, parser: ReportParser,
        maxX: Int, maxY: Int, maxPressure: Int,
        buttonCount: Int, bezelButtonCount: Int = 0, hasTouchRing: Bool, hasDualRings: Bool = false,
        hasMechanicalDial: Bool = false,
        hasKeyOLEDs: Bool = false,
        hasTouchStrips: Bool = false, ringSlotCount: Int = 4, hasEraser: Bool, hasTilt: Bool = false,
        tiltMaxDegrees: Double? = nil,
        hasFingerTouch: Bool = false, maxTouchContacts: Int = 0,
        touchMaxX: Int = 0, touchMaxY: Int = 0,
        isPenDisplay: Bool = false,
        seizeUSB: Bool,
        initSteps: [InitStep] = [],
        ledCompanionPID: Int? = nil,
        confidence: ConfidenceTier = .experimental,
        productStringMatch: String? = nil,
        activeWidthMM: Double? = nil,
        activeHeightMM: Double? = nil
    ) {
        self.productID = productID
        self.name = name
        self.parser = parser
        self.maxX = maxX
        self.maxY = maxY
        self.maxPressure = maxPressure
        self.buttonCount = buttonCount
        self.bezelButtonCount = bezelButtonCount
        self.hasMechanicalDial = hasMechanicalDial
        self.hasTouchRing = hasTouchRing
        self.hasDualRings = hasDualRings
        self.hasKeyOLEDs = hasKeyOLEDs
        self.hasTouchStrips = hasTouchStrips
        self.hasFingerTouch = hasFingerTouch
        self.maxTouchContacts = maxTouchContacts
        self.touchMaxX = touchMaxX
        self.touchMaxY = touchMaxY
        self.ringSlotCount = ringSlotCount
        self.hasEraser = hasEraser
        self.hasTilt = hasTilt
        self.tiltMaxDegrees = tiltMaxDegrees
        self.isPenDisplay = isPenDisplay
        self.seizeUSB = seizeUSB
        self.initSteps = initSteps
        self.ledCompanionPID = ledCompanionPID
        self.confidence = confidence
        self.productStringMatch = productStringMatch
        self.activeWidthMM = activeWidthMM
        self.activeHeightMM = activeHeightMM
    }

    /// Lines per inch derived from `maxX`/`maxY` and `activeWidthMM`/`activeHeightMM`.
    /// Returns nil unless both physical dimensions are populated.  Useful for
    /// the info pane and for cross-vendor cursor-mapping that needs a real DPI
    /// number rather than device-unit ratios.
    public var lpi: (x: Double, y: Double)? {
        guard let w = activeWidthMM, w > 0, let h = activeHeightMM, h > 0 else { return nil }
        return (Double(maxX) / w * 25.4, Double(maxY) / h * 25.4)
    }

    /// Derives the device family from parser and name.
    /// Used to check tool compatibility against `WacomToolSpec.supportedFamilies`.
    ///
    /// The `.intuosV1` branch still sniffs `name` to split one parser across
    /// four families; replacing that with structured data is a separate task.
    public var family: DeviceFamily {
        switch parser {
        case .graphire:
            // Graphire / PenPartner / early consumer line. The four
            // `["graphire"]` tool specs in WacomToolCatalog (PenPartner,
            // Graphire Pen/Eraser/Mouse) are written for exactly these devices;
            // the previous "bamboo2" pointed them at CTH/Intuos-Pro-Gen2 tools
            // two generations later and left the graphire specs unreachable.
            // (GraphireDecoder currently synthesises Grip-Pen tool codes and
            // never runs the compatibility check, so this is a correctness fix
            // for the family string, not a runtime behaviour change — see the
            // decoder's own note about synthetic codes. This case also spans
            // three Bamboo-branded CTE/MTE devices that "graphire" does not
            // describe; that dual coverage is unresolved.)
            return .graphire
        case .intuos3:
            return .intuos3
        case .cintiqV1:
            return .cintiq
        case .intuosV1:
            // Intuos 1-5 and any non-Cintiq pen displays that haven't been migrated.
            if name.contains("Cintiq") || name.contains("DTK") || name.contains("DTH") {
                return .cintiq
            }
            if name.contains("Intuos 4") || name.contains("PTK") {
                return .intuos4
            }
            if name.contains("Intuos 5") || name.contains("PTH-8") {
                return .intuos5
            }
            return .intuosProGen1
        case .intuosV2:
            return .intuosProGen2
        case .intuosV3:
            return .intuosProGen3
        case .dtus:
            return .dtus
        case .dtu:
            return .dtu
        case .bamboo:
            return .bamboo
        case .xencelabs:
            return .xencelabs
        }
    }
}

// MARK: - Registry

public enum WacomDeviceRegistry: Sendable {

    // MARK: Known devices

    public static let knownDevices: [WacomDeviceSpec] = [

        // ── PenPartner / Graphire 1–4 ─────────────────────────────────────────
        // graphire parser: 8-byte Report ID 0x01, ≤511 pressure levels.
        .init(
            // Kernel wacom_features_0x3 identifies this PID as the "Cintiq
            // Partner" (PTU-600), not PenPartner — the 2026-05 dimension
            // "correction" pulled the right struct but kept the wrong name.
            // The PTU report family has no decoder here, so this is name-only
            // (kernel dims: 20480×15360×511). The real PenPartner is 0x0000.
            productID: 0x0003, name: "Cintiq Partner (PTU-600)",  // ⚠ name-only
            parser: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true, seizeUSB: false),
        .init(
            // PENPARTNER report family (5-byte wacom_penpartner_irq) has no
            // decoder here; name-only (kernel dims: 5040×3780×255).
            productID: 0x0000, name: "PenPartner",  // ⚠ name-only
            parser: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false),
        // Original Graphire (0x0004/0x0010) and Graphire 2/3/4 4×5 rows below
        // share one active area: 127.6×92.8mm per Wacom's original Graphire
        // manual (ET-0405-R/U) and the Graphire4 manual (CTE-440), archived
        // at Notes/Scratch/manuals/GraphireManual.pdf and G4Manual.pdf
        // (gitignored). maxX/maxY (10206/10208, 7422/7424) were NOT changed
        // — they already match OpenTabletDriver's ET-0405-U.json exactly,
        // which is real hardware-measured data. Note this contradicts the
        // manuals' own printed "coordinate resolution" figure (40 lpmm, which
        // would give 5104/3712, not ~10208/7424) — the manual's resolution
        // spec isn't the same thing as the raw wire units the decoder emits,
        // confirmed by checking OTD before trusting the manual's arithmetic.
        // Only activeHeightMM (102→93, a stale value unrelated to the above)
        // is corrected here. Confirmed 2026-08-03.
        .init(
            productID: 0x0004, name: "Graphire",
            parser: .graphire, maxX: 10206, maxY: 7422, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, activeWidthMM: 127, activeHeightMM: 93),
        .init(
            productID: 0x0010, name: "Graphire",  // cross-referenced: linuxwacom + OTD
            parser: .graphire, maxX: 10206, maxY: 7422, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-graphire-usb.tablet (Width=127, Height=102)
            seizeUSB: false, confidence: .crossReferenced,
            activeWidthMM: 127, activeHeightMM: 93),
        .init(
            productID: 0x0011, name: "Graphire 2 (4×5)",  // ⚠ estimated; kernel 0x11 = Graphire2 4×5
            parser: .graphire, maxX: 10206, maxY: 7422, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-graphire2-4x5.tablet (Width=127, Height=102)
            seizeUSB: false,
            activeWidthMM: 127, activeHeightMM: 93),
        .init(
            productID: 0x0012, name: "Graphire 2 (5×7)",  // ⚠ estimated; kernel 0x12 = Graphire2 5×7
            parser: .graphire, maxX: 13918, maxY: 10206, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, activeWidthMM: 178, activeHeightMM: 127),
        .init(
            productID: 0x0013, name: "Graphire 3 (4×5)",  // ⚠ estimated
            parser: .graphire, maxX: 10208, maxY: 7424, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-graphire3-4x5.tablet (Width=127, Height=102)
            seizeUSB: false,
            confidence: .crossReferenced,
            activeWidthMM: 127, activeHeightMM: 93),
        .init(
            // Active area 208.8×150.8mm confirmed via the Graphire4 manual's
            // CTE-640 entry — this row shares CTE-640's exact maxX/maxY, same
            // hardware generation. activeWidthMM/Height corrected 203/152→
            // 209/151. Confirmed 2026-08-03.
            productID: 0x0014, name: "Graphire 3 (6×8)",  // ⚠ estimated
            parser: .graphire, maxX: 16704, maxY: 12064, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 209, activeHeightMM: 151),
        .init(
            productID: 0x0015, name: "Graphire 4 (4×5)",  // ⚠ estimated
            parser: .graphire, maxX: 10208, maxY: 7424, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-graphire4-4x5.tablet (Width=127, Height=102)
            seizeUSB: false,
            confidence: .crossReferenced,
            activeWidthMM: 127, activeHeightMM: 93),
        .init(
            // Active area 208.8×150.8mm confirmed directly against the
            // Graphire4 manual's own CTE-640 entry. activeWidthMM/Height
            // corrected 203/152→209/151. Confirmed 2026-08-03.
            productID: 0x0016, name: "Graphire 4 (6×8)",  // ⚠ estimated
            parser: .graphire, maxX: 16704, maxY: 12064, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 209, activeHeightMM: 151),
        .init(
            // Kernel WACOM_MO "BambooFun 4x5"; libwacom CTE-450 (NumRings=1).
            // Was misattributed as MTE-450 here — that model is PID 0x0065.
            // Active area 147.6×92.3mm confirmed against Wacom's Bamboo Fun
            // (CTE-450/650) User's Manual — matches this row's own maxX/maxY
            // (14760/9225 at 100 lpmm) exactly; activeWidthMM/Height corrected
            // 152/102→148/92. Archived at
            // Notes/Scratch/manuals/BambooFun-CTE-450-650-UserManual.pdf
            // (gitignored). Confirmed 2026-08-03.
            productID: 0x0017, name: "Bamboo Fun small (CTE-450)",  // ⚠ from kernel/libwacom/OTD
            parser: .graphire, maxX: 14760, maxY: 9225, maxPressure: 511,
            buttonCount: 4, hasTouchRing: true, hasEraser: true,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 148, activeHeightMM: 92),

        // ── Volito / PenStation ───────────────────────────────────────────────
        .init(
            productID: 0x0060, name: "Volito",  // ⚠ estimated
            parser: .graphire, maxX: 5104, maxY: 3712, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            // dimensions: libwacom wacom-volito-4x5.tablet (Width=127, Height=102).
            // Kernel WACOM_VOLITO_RES=50 lpmm would give 102×74 mm — too small;
            // libwacom measurement supersedes for a 4×5 (FT-0405) tablet.
            // A third figure — Wacom's own Volito manual (technical
            // specifications, model CTF-420/G): 127.6×92.8mm, archived at
            // Notes/Scratch/manuals/Wacom-Volito-Windows-2005.pdf, gitignored
            // — disagrees with libwacom's height (93 vs 102) and doesn't
            // settle it either, since "CTF-420/G" may not be the exact
            // hardware revision this PID maps to. Left unresolved rather than
            // picking a winner among three disagreeing sources with no
            // capture to arbitrate. Noted 2026-08-03.
            //
            // Separately: maxX/maxY (5104/3712) come from the manual's stated
            // "40 lpmm" × this same active area — exactly the arithmetic that
            // proved wrong for the original Graphire (ET-0405), whose real
            // hardware-measured value (OTD) was double what its own manual's
            // "40 lpmm" implied. No independent source exists to check Volito
            // the same way — OpenTabletDriver carries no Volito config — so
            // this row's coordinate range carries the same unconfirmed risk
            // and was deliberately left untouched rather than "corrected"
            // toward either arithmetic. A capture would settle it outright.
            seizeUSB: false,
            confidence: .crossReferenced,
            activeWidthMM: 127, activeHeightMM: 102),
        .init(
            // Kernel calls this PenStation2; dimensions/pressure corrected.
            productID: 0x0061, name: "PenStation2",  // ⚠ from kernel
            parser: .graphire, maxX: 3250, maxY: 2320, maxPressure: 255,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            // dimensions: input-wacom 4.18 wacom_features_0x61 (3250/50 lpmm × 2320/50 lpmm).
            // Not in libwacom; the kernel WACOM_VOLITO_RES=50 constant proved
            // ~25% off for 0x0060 — these values may be similarly low.
            seizeUSB: false,
            activeWidthMM: 65, activeHeightMM: 46.4),
        .init(
            productID: 0x0062, name: "Volito 2",  // ⚠ estimated
            parser: .graphire, maxX: 5104, maxY: 3712, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            // dimensions inferred from sibling 0x0060 (Volito) in libwacom
            // wacom-volito-4x5.tablet (Width=127, Height=102). Volito 2 shares
            // identical kernel max coords with Volito 1 → almost certainly the
            // same physical size. Not in libwacom directly.
            seizeUSB: false,
            activeWidthMM: 127, activeHeightMM: 102),
        .init(
            // Kernel WACOM_MO "Wacom Bamboo"; libwacom MTE-450 (NumRings=1,
            // 4 buttons). Was misattributed as CTF-430 here — that model is
            // PID 0x0069. WACOM_MO family (0x17/0x18/0x65) ring format per
            // OTD BambooAuxReport: byte 8, bit 7 = finger present, bits 0–6 =
            // absolute position 0–71. Ring decode still needs a hardware
            // capture; only the spec facts are recorded here.
            productID: 0x0065, name: "Bamboo (MTE-450)",  // ⚠ from kernel/libwacom/OTD
            parser: .graphire, maxX: 14760, maxY: 9225, maxPressure: 511,
            buttonCount: 4, hasTouchRing: true, hasEraser: true,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),

        // ── Cintiq 21UX first-gen ─────────────────────────────────────────────
        .init(
            // Kernel wacom_features_0x3F: Cintiq 21UX, 1023 pressure, 8 keys.
            // Parser was .graphire (8-byte report) which would never decode a
            // Cintiq pen-display report; corrected to .cintiqV1 in line with
            // every other CINTIQ-family entry. Still ⚠ until hardware-verified.
            productID: 0x003F, name: "Cintiq 21UX (DTZ-2100)",  // ⚠ from kernel
            parser: .cintiqV1, maxX: 87200, maxY: 65600, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 432, activeHeightMM: 330),

        // ── Intuos 1 (1998–2002) — intuosV1 parser ───────────────────────────
        // 10-byte reports, BE16, 1024-level pressure (10-bit).
        //
        // Coordinate ranges across this whole family (and Intuos 2 below) are
        // twice a plain BE16 read of the coordinate bytes, because
        // IntuosV1Decoder.decodeUSBPen appends a 1-bit fractional extension
        // from report[9] (`<<1 | fractional bit`). Originally hardware-confirmed
        // only on the 6×8 (0x0021) 2026-08-03 — the halved value mapped only
        // that tablet's top-left quadrant across the full screen — but every
        // row's maxX/maxY/mm below is now cross-checked two ways:
        //   1. Wacom's own Intuos (GD-series) User's Manual technical-
        //      specifications table (active area in mm, 100 lpmm resolution),
        //      independently reproducing maxX/maxY = width/height(mm) × 100 × 2.
        //   2. OpenTabletDriver's GD-*.json / XD-*.json configs — a mature,
        //      long-shipping driver with its own independently-written parser
        //      (IntuosV1TabletReport.cs) that decodes X/Y/tilt with the exact
        //      same bit formulas as ours, and declares the same MaxX/MaxY for
        //      every PID in this family. Confirmed 2026-08-03.
        // maxPressure stays 1023 (not OTD's 2046): decodeUSBPen right-shifts
        // its combined 11-bit pressure field by 1 whenever spec.maxPressure
        // <= 1023 (see the pen-path comment below), so the two are the same
        // value on two different scales, not a disagreement.
        .init(
            productID: 0x0020, name: "Intuos 4×5",
            parser: .intuosV1, maxX: 25400, maxY: 21200, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 127, activeHeightMM: 106),
        .init(
            productID: 0x0021, name: "Intuos 6×8",
            parser: .intuosV1, maxX: 40640, maxY: 32480, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 203, activeHeightMM: 162),
        .init(
            productID: 0x0022, name: "Intuos 9×12",
            parser: .intuosV1, maxX: 60960, maxY: 48120, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 305, activeHeightMM: 241),
        .init(
            productID: 0x0023, name: "Intuos 12×12",
            parser: .intuosV1, maxX: 60960, maxY: 63360, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 305, activeHeightMM: 317),
        .init(
            productID: 0x0024, name: "Intuos 12×18",
            parser: .intuosV1, maxX: 91440, maxY: 63360, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 457, activeHeightMM: 317),

        // ── Intuos 2 (2002–2004) — intuosV1 parser ───────────────────────────
        // Same coordinate ranges and the same two-source confirmation as
        // Intuos 1 above — see the family note there. Wacom's GD-series manual
        // doesn't cover the XD-series PIDs directly, but OpenTabletDriver
        // declares identical Width/Height/MaxX/MaxY for every XD-* row against
        // its matching GD-* row, consistent with Intuos 1 and 2 sharing the
        // same chassis and active area per size class.
        .init(
            productID: 0x0041, name: "Intuos 2 (4×5)",
            parser: .intuosV1, maxX: 25400, maxY: 21200, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 127, activeHeightMM: 106),
        .init(
            // Same physical 6×8 tablet as 0x0021 and 0x0047.
            productID: 0x0042, name: "Intuos 2 (6×8)",
            parser: .intuosV1, maxX: 40640, maxY: 32480, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 203, activeHeightMM: 162),
        .init(
            productID: 0x0043, name: "Intuos 2 (9×12)",
            parser: .intuosV1, maxX: 60960, maxY: 48120, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 305, activeHeightMM: 241),
        .init(
            productID: 0x0044, name: "Intuos 2 (12×12)",
            parser: .intuosV1, maxX: 60960, maxY: 63360, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 305, activeHeightMM: 317),
        .init(
            productID: 0x0045, name: "Intuos 2 (12×18)",
            parser: .intuosV1, maxX: 91440, maxY: 63360, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 457, activeHeightMM: 317),

        // ── Intuos3 (PTZ-xxx, 2003–2006) — intuos3 parser ───────────────────
        // Status byte layout differs from Intuos5: bit 6 (0x40) is proximity.
        // Aux reports: 0x03 (8 keys in byte 4) and 0x0C (4+4 split).
        // Two-stage feature init: [0x02,0x02] immediately, [0x04,0x00] after 150 ms.
        // PTZ-631W (0x00B5) confirmed live; remaining entries ⚠ estimated but
        // the two-stage init and proximity bit are common to the whole PTZ family.
        //
        // maxX/maxY confirmed 2026-08-03 for every row in this family: exact
        // match against OpenTabletDriver's PTZ-*.json, and against Wacom's own
        // Intuos3 User's Manual (technical specifications table — active area
        // in mm at the family's 200 lpmm, archived at
        // Notes/Scratch/manuals/Intuos3-UserManual.pdf, gitignored) once
        // doubled for IntuosV1Decoder's fractional-bit extension, same as the
        // Intuos1/2/4 families. maxPressure stays 1023 (not OTD's 2046) for
        // the same reason as Intuos4 — see that family's note. Two rows
        // (PTZ-1231W, PTZ-431W) had activeWidthMM/Height corrected to match;
        // the rest were already right.
        .init(
            productID: 0x00B0, name: "Intuos3 4×5 (PTZ-430)",  // dims confirmed 2026-08-03 — see family note
            parser: .intuos3, maxX: 25400, maxY: 20320, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])], activeWidthMM: 127, activeHeightMM: 102),
        .init(
            productID: 0x00B1, name: "Intuos3 6×8 (PTZ-630)",  // cross-referenced: linuxwacom + OTD
            parser: .intuos3, maxX: 40640, maxY: 30480, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])],
            confidence: .crossReferenced,
            activeWidthMM: 203, activeHeightMM: 152),
        .init(
            productID: 0x00B2, name: "Intuos3 9×12 (PTZ-930)",  // dims confirmed 2026-08-03 — see family note
            parser: .intuos3, maxX: 60960, maxY: 45720, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])], activeWidthMM: 305, activeHeightMM: 229),
        .init(
            productID: 0x00B3, name: "Intuos3 12×12 (PTZ-1230)",  // dims confirmed 2026-08-03 — see family note
            parser: .intuos3, maxX: 60960, maxY: 60960, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])], activeWidthMM: 305, activeHeightMM: 305),
        .init(
            // activeWidthMM corrected 483→488 (487.68mm) — see the family
            // note at the top of this section.
            productID: 0x00B4, name: "Intuos3 12×19 (PTZ-1231W)",
            parser: .intuos3, maxX: 97536, maxY: 60960, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])], activeWidthMM: 488, activeHeightMM: 305),
        .init(
            productID: 0x00B5, name: "Intuos3 WS (PTZ-631W)",  // ✓ confirmed live
            parser: .intuos3, maxX: 54204, maxY: 31750, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasTouchStrips: true, hasEraser: true,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])],
            confidence: .verified,
            activeWidthMM: 270.5, activeHeightMM: 158.5),
        .init(
            // activeWidthMM/Height corrected 152/102→157/98 (157.48/98.425mm)
            // — see the family note at the top of this section.
            productID: 0x00B7, name: "Intuos3 4×6 (PTZ-431W)",
            parser: .intuos3, maxX: 31496, maxY: 19685, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])], activeWidthMM: 157, activeHeightMM: 98),

        // ── Intuos4 (PTK-xxx, 2009–2012) — intuosV1 parser ───────────────────
        // OLED display on each express key; 2048-level pressure (11-bit).
        //
        // Unlike the Intuos 1/2 family, maxX/maxY here were already correct —
        // Intuos4's own native resolution (200 lpmm) is exactly double the
        // classic 100 lpmm, so the decoder's `<<1 | fractional bit` folds in
        // cleanly and these rows already carried the right doubled values,
        // confirmed against OpenTabletDriver's PTK-*.json (exact match) and
        // Wacom's own Intuos4 User's Manual (technical specifications table,
        // archived at Notes/Scratch/manuals/Intuos4-UserManual.pdf, gitignored).
        // What was wrong instead: activeWidthMM/activeHeightMM on four of the
        // five rows didn't match their own maxX/maxY (e.g. PTK-640 claimed
        // 152mm tall against a maxY that means 140mm) — a self-consistency
        // bug independent of the doubling question, caught by cross-checking
        // against the manual's active-area table. PTK-540WL was already
        // self-consistent and needed no change. Confirmed 2026-08-03.
        .init(
            productID: 0x00B8, name: "Intuos4 S (PTK-440)",
            parser: .intuosV1, maxX: 31496, maxY: 19685, maxPressure: 2047,
            buttonCount: 6, hasTouchRing: true, hasKeyOLEDs: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 157, activeHeightMM: 98),
        .init(
            productID: 0x00B9, name: "Intuos4 M (PTK-640)",
            parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasKeyOLEDs: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 224, activeHeightMM: 140),
        .init(
            // Dimensions corrected to kernel wacom_features_0xBA (65024×40640).
            productID: 0x00BA, name: "Intuos4 L (PTK-840)",  // dims kernel + OTD
            parser: .intuosV1, maxX: 65024, maxY: 40640, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasKeyOLEDs: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 325, activeHeightMM: 203),
        .init(
            productID: 0x00BB, name: "Intuos4 XL (PTK-1240)",
            parser: .intuosV1, maxX: 97536, maxY: 60960, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasKeyOLEDs: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 488, activeHeightMM: 305),
        .init(
            // Dimensions corrected to kernel wacom_features_0xBC (40640×25400).
            productID: 0x00BC, name: "Intuos4 WL (PTK-540WL)",  // dims kernel + OTD
            parser: .intuosV1, maxX: 40640, maxY: 25400, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasKeyOLEDs: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 203, activeHeightMM: 127),
        .init(
            // BT Classic PID for the same PTK-540WL: libwacom
            // wacom-intuos4-6x9-wl.tablet lists DeviceMatch
            // usb|056a|00bc;bluetooth|056a|00bd — same device, second transport.
            // Coordinates/dims mirror the USB entry above; seizeUSB=false as
            // with other BT Classic entries in this registry.
            //
            // hasKeyOLEDs deliberately NOT set here: the Bluetooth OLED image
            // format is 1-bit monochrome plus a bit-scramble
            // (`76543210`→`GECA6420`, per the kernel's sysfs ABI doc),
            // distinct from USB's 4-bit format. WacomOutputProtocol only
            // implements the USB encoding as of 2026-08-31 — see
            // Notes/Scratch/intuos4-oled-image-design.md. Add this flag once
            // BT support is actually implemented, not before.
            productID: 0x00BD, name: "Intuos4 WL (PTK-540WL) BT",  // ⚠ from libwacom
            parser: .intuosV1, maxX: 40640, maxY: 25400, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, activeWidthMM: 203, activeHeightMM: 127),

        // ── Intuos5 / Intuos Pro 1st-gen (PTH-x50/x51, 2012–2013) ──────────────
        // IntuosV1 10-byte format, 2047-level pressure (vs Intuos Pro 2nd-gen's 8191).
        // Predate widespread BT support; no known BLE variants (USB only).
        //
        // │ Model  │ Gen │ Name Change         │   USB PID   │  BT Classic  │  BLE │
        // │────────┼─────┼─────────────────────┼─────────────┼──────────────┼──────│
        // │PTH-450 │ 1   │ Intuos5 S           │   0x0026    │    unknown   │  —   │
        // │PTH-650 │ 1   │ Intuos5 M           │   0x0027    │    unknown   │  —   │
        // │PTH-850 │ 1   │ Intuos5 L           │   0x0028    │    unknown   │  —   │
        // │PTH-451 │ 2   │ Intuos Pro S (1st)  │   0x0314    │    unknown   │  —   │
        // │PTH-651 │ 2   │ Intuos Pro M (1st)  │   0x0315    │    unknown   │  —   │
        // │PTH-851 │ 2   │ Intuos Pro L (1st)  │   0x00F8    │    unknown   │  —   │
        // │                                                                          │
        // │ These are all IntuosV1 format. Intuos Pro 2nd-gen (PTH-460/660/860)   │
        // │ switched to IntuosV2 format and added Bluetooth support.              │
        // └──────────────────────────────────────────────────────────────────────────┘
        .init(
            // Coordinates confirmed exact against OpenTabletDriver's PTH-450.json
            // and against Wacom's Intuos5 Important Product Information booklet
            // (archived at Notes/Scratch/manuals/IntuosPro-PTH-451-651-851-IPI.pdf,
            // gitignored — shared across the whole Intuos5/Intuos5-Touch line).
            // activeWidthMM/Height corrected to match (157.48×98.43mm).
            // Confirmed 2026-08-03. NOT fixed here: this device is genuinely
            // touch-capable per the kernel's Device IDs table and the manual's
            // own "Multi-finger Touch: Supported" line, but this row carries
            // no `hasFingerTouch` and MockTab has never decoded its touch
            // report — a real coverage gap, not a spec question. Needs a
            // capture (touch report ID + coordinate range), not a manual.
            productID: 0x0026, name: "Intuos5 S (PTH-450)",
            parser: .intuosV1, maxX: 31496, maxY: 19685, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 157, activeHeightMM: 98),
        .init(
            // Same confirmation and same untouched touch-capability gap as
            // 0x0026 above. Confirmed 2026-08-03.
            productID: 0x0027, name: "Intuos5 M (PTH-650)",
            parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 224, activeHeightMM: 140),
        .init(
            // Same confirmation as 0x0026 above; activeWidthMM corrected
            // 330→325 to match (325.12mm). Confirmed 2026-08-03.
            //
            // Touch confirmed live 2026-08-08 via two hardware discovery
            // captures against this exact unit, one per interface (the pen
            // interface's own report 0x02 is a fixed 10 bytes; the touch
            // interface's report 0x02 is a fixed 64 bytes — same report ID,
            // different interfaces, told apart by length, which is exactly
            // what confused earlier capture attempts before the capture tool
            // itself was fixed to stop misattributing reports across
            // interfaces). The 64-byte report matches IntuosV1Decoder's
            // existing BPT3ContainerDecoder dispatch (`id == 0x02 && length
            // == 64`) byte-for-byte: 8-byte slot stride from offset 2, slot
            // key 2–17, bit-7 down flag, nibble-packed 12-bit X/Y, width/
            // height bytes — the same format already shipping for CTH-690.
            // No decoder change needed, only this flag. touchMaxX/Y are the
            // format's natural 12-bit ceiling, corroborated independently by
            // OpenTabletDriver's PTH-850.json ("Touch": {"MaxX": 4095,
            // "MaxY": 4095}). maxTouchContacts mirrors CTH-690's 16 — the
            // slot-key range (2–17) is the same protocol, not device-specific.
            productID: 0x0028, name: "Intuos5 L (PTH-850)",
            parser: .intuosV1, maxX: 65024, maxY: 40640, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 16,
            touchMaxX: 4095, touchMaxY: 4095,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .verified, activeWidthMM: 325, activeHeightMM: 203),

        // ── Intuos Pro first-gen (PTH-x51, 2013) — intuosV1 parser ───────────
        // Renamed from "Intuos5" to "Intuos Pro"; same HID format.
        .init(
            // mm corrected to 157.48×98.43mm — confirmed against Wacom's Intuos
            // Pro (PTH-451/651/851) IPI booklet and OTD's PTH-451.json, same
            // sources and same untouched touch-capability gap as 0x0026 above
            // (this Pro-generation row lacks hasFingerTouch too). Confirmed
            // 2026-08-03.
            productID: 0x0314, name: "Intuos Pro S (PTH-451)",
            parser: .intuosV1, maxX: 31496, maxY: 19685, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 157, activeHeightMM: 98),
        .init(
            // ⚠ estimated, and NOT the PID PTH-651 hardware was observed to
            // use — see 0x0315 below, confirmed by capture 2026-08-19. Kept
            // rather than deleted because some later boards are reported to
            // enumerate here; treat as an unconfirmed variant, not the
            // canonical row for this model.
            productID: 0x0316, name: "Intuos Pro M (PTH-651)",  // ⚠ estimated
            parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 224, activeHeightMM: 140),
        .init(
            // Dimensions corrected to kernel wacom_features_0x317 (65024×40640).
            // Previous values (44704×27940) were the PTH-651 M-size by mistake.
            productID: 0x0317, name: "Intuos Pro L (PTH-851)",  // ✓ confirmed live
            parser: .intuosV1, maxX: 65024, maxY: 40640, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .verified,
            activeWidthMM: 325.1, activeHeightMM: 203.2),

        // ── Intuos Pro second-gen (PTH-x60/x80, 2017–present) — intuosV2 ─────
        // 192-byte reports, LE24 coordinates, 8192-level pressure (13-bit).
        // Also supports BLE HOGP (Report IDs 0x01 pen, 0x03 pad).
        // seizeUSB=true: standard-HID-mouse interface must be seized.
        //
        // ┌─ INTUOS PRO 2ND-GEN DEVICE VARIANTS (PTH-460/660/860) ────────────────┐
        // │ All use IntuosV2 parser; differ only in coordinates (S/M/L sizes).     │
        // │                                                                         │
        // │ Model  │ Size │   USB PID   │  BT Classic PID  │   BLE PID (TBD)      │
        // │────────┼──────┼─────────────┼──────────────────┼──────────────────    │
        // │PTH-460 │  S   │ 0x0392/03DC │  0x0393/03DD     │    ? (LE IntuosPro S)│
        // │PTH-660 │  M   │   0x0357    │    0x0360 (+9)   │    ? (LE IntuosPro M)│
        // │PTH-860 │  L   │   0x0358    │    0x0361 (+9)   │    ? (LE IntuosPro L)│
        // │  (PTH-460 shipped later than 660/860 and does not follow the +9     │
        // │   pattern; 0x0352 belongs to the Cintiq Pro 32.)                     │
        // │                                                                         │
        // │ Transport notes:                                                       │
        // │  • USB: standard HID, requires initSteps=[] + InputMode init           │
        // │  • BT Classic: 361-byte 0x80 container, initSteps=[], no InputMode    │
        // │  • BLE: GATT always active, limited to trackpad mode on macOS         │
        // │    (AppleBluetoothMultitouch kext conflict — requires device seizure) │
        // │                                                                        │
        // │ Pairing hint: BT Classic = power on with USB disconnected, LED blinks│
        // │              BLE = standard BLE pairing (limited functionality)       │
        // └────────────────────────────────────────────────────────────────────────┘
        .init(
            // Previously mislabeled "Intuos Pro S (PTH-460)" by a "+9 PID
            // pattern" guess. libwacom wacom-cintiq-pro-32.tablet identifies
            // 0x0352 as the Cintiq Pro 32 pen interface (PairedID 0x0356 is
            // its separate touch interface — no registry entry; it would need
            // its own touch decoder). The real PTH-460 lives at 0x0392/0x03DC.
            //
            // Dimensions were libwacom's Width=686 Height=381 mm (maxX 137200,
            // maxY 76200) until 2026-08-14. OTD gained a config for this PID
            // (upstream #4974) giving 701.92 × 396.58 mm — same 200 units/mm
            // scale, so not a units disagreement — and Wacom's own spec sheet
            // prints 697 × 392 mm. Two sources within ~5 mm of each other and
            // 11–16 mm off libwacom makes libwacom the outlier here, so the
            // OTD figures are used. Wacom's printed value is a rounded consumer
            // spec and only breaks the tie; it is not the primary source.
            //
            // Same commit added initSteps, which this row was missing: OTD's
            // FeatureInitReport `AgI=` is [0x02, 0x02], and every other
            // intuosV2 pen display in this table already carried it.
            productID: 0x0352, name: "Cintiq Pro 32 (DTH-3220)",  // ⚠ dims OTD + Wacom spec sheet
            parser: .intuosV2, maxX: 140384, maxY: 79316, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 701.92, activeHeightMM: 396.58),
        .init(
            productID: 0x0357, name: "Intuos Pro M (PTH-660)",  // ✓ confirmed live
            parser: .intuosV2, maxX: 44800, maxY: 29600, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            // tiltMaxDegrees 64.0: descriptor-confirmed on this family's sibling
            // PTH-860 (X/Y Tilt usages 0x3D/0x3E declare logical/physical
            // [-64,63], unit degrees — physical equals logical, so the raw
            // signed byte is the angle 1:1). Not independently measured on this
            // PID, but PTH-660/860 share one decoder path and one wire format.
            tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 5,
            // touchMaxX/Y confirmed 2026-07-30 against this device's own touch
            // report descriptor: it declares Logical Maximum 8960 on X and 5920
            // on Y, matching the pen/5 estimate these values were originally
            // derived from — exactly, on both axes. Promoted from estimate to
            // descriptor-derived; the numbers themselves did not change.
            //
            // That the pen/5 heuristic landed dead-on here is evidence for the
            // ratio on this sensor family, not a general rule. Sibling rows
            // still carrying estimated touch maxima stay estimates until each
            // is checked the same way, and 0x0351's are deliberately left 0
            // rather than estimated at all (see the note on that row).
            //
            // Both USB and BT paths use this entry — PTH-660 over BT presents
            // this PID, not 0x0360. BT touch confirmed working 2026-05-22.
            touchMaxX: 8960, touchMaxY: 5920,
            seizeUSB: true,
            confidence: .verified,
            activeWidthMM: 224.0, activeHeightMM: 148.0),
        .init(
            productID: 0x0358, name: "Intuos Pro L (PTH-860)",  // ✓ confirmed live (USB + BT)
            parser: .intuosV2, maxX: 62200, maxY: 43200, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            // tiltMaxDegrees 64.0: HID descriptor-confirmed. X/Y Tilt usages
            // (0x3D/0x3E) declare logical [-64,63], physical [-64,63], unit
            // degrees — physical equals logical, so the raw signed byte is the
            // angle 1:1, full scale 64°. The current /127.0 divisor in
            // IntuosV2Decoder understates tilt by roughly half for this family.
            tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 5,
            // USB coords confirmed 2026-05-21; BT touch confirmed 2026-05-22 via
            // live capture (PID 0x0358 presented over BT, same as PTH-660 pattern).
            touchMaxX: 12439, touchMaxY: 8639,
            seizeUSB: true,
            confidence: .verified,
            activeWidthMM: 311.0, activeHeightMM: 216.0),

        // ── Bamboo / CTL consumer line — bamboo parser ────────────────────────
        // BAMBOO_PT wire format: pen reports on Report ID 0x02 (9 bytes, LE),
        // per kernel wacom_bpt_pen — but only after the feature-report mode
        // switch [0x02, 0x02]; without it the tablet stays in boot-mouse
        // emulation (4-byte relative packets on report 0x01) and no pen data
        // ever reaches the decoder. Confirmed by a CTL-460 user capture
        // 2026-07-21. BambooDecoder also keeps a legacy 0x10 path.
        .init(
            productID: 0x00D0, name: "Bamboo Touch (CTT-460)",
            // maxPressure 0 is intentional: CTT-460 is finger-touch only, no
            // pen. (Kernel's wacom_features_0xD0 lists the family's pen value.)
            // Coordinates settled 2026-08-03 by a real CTT-460 hid-recorder
            // trace (bentiss/hid-devices events/tablet/
            // Wacom_Bamboo_2FG_056a_00D0.hid — unlicensed corpus, analysis
            // only, do NOT vendor into Samples). Three corroborating facts:
            // the touch interface's own HID descriptor declares logical max
            // 480×320 (physical max 12000×8000 → 120×80mm at Wacom's usual
            // 0.01mm scaling); the trace's 336 touch events (report 0x02,
            // big-endian 11-bit fields per kernel wacom_bpt_touch) observe
            // x 82–325, y 61–307, with y nearly reaching 320; and the
            // kernel's WACOM_QUIRK_BBTOUCH_LOWRES quirk shifts raw values
            // left by 5 purely to inflate this low-res space toward the
            // nominal pen-chassis numbers — so the kernel's 14720×9200 for
            // this PID was never the wire format. The manual's 125×85mm is
            // presumably the sensor glass vs. the 120×80mm reported area;
            // the descriptor's own figure wins here. Note BambooDecoder has
            // no touch path for this report — decoding is still a coverage
            // gap; these values just make the row honest about the wire.
            parser: .bamboo, maxX: 480, maxY: 320, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, confidence: .verified,
            activeWidthMM: 120, activeHeightMM: 80),
        .init(
            // Pen active area 147.2×92.0mm confirmed against Wacom's Bamboo
            // Touch/Pen/Pen&Touch (CTT/CTL/CTH-460) User's Manual — matches
            // this row's own maxX/maxY (14720/9200 at the family's 100 lpmm)
            // exactly; the 152/102 this carried before didn't match either.
            // Archived at Notes/Scratch/manuals/Bamboo-CTT-CTH-CTL-460-UserManual.pdf
            // (gitignored). Confirmed 2026-08-03.
            //
            // Touch: kernel's static table (`wacom_features_0xD1`) declares this
            // PID `BAMBOO_PT` with `touch_max = 2`, decoded by `BambooDecoder`'s
            // 20-byte path (`decodeBPTTouch`) added 2026-08-26. 480×320 is the
            // same low-res wire space CTT-460 (0x00D0) settled on. No direct
            // hardware capture of this report on this PID yet — kernel-table
            // confirmed, not hardware-verified.
            productID: 0x00D1, name: "Bamboo Pen & Touch (CTH-460)",
            parser: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            hasFingerTouch: true, maxTouchContacts: 2, touchMaxX: 480, touchMaxY: 320,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            // Identity confirmed 2026-07-21: user capture of a unit labeled
            // "Bamboo Pen CTL-460 / CTL-460/K" enumerating as PID 0x00D4;
            // matches kernel wacom_features_0xD4 ("Wacom Bamboo Pen") and
            // linux-hardware 056a:00d4 "CTL-460 [Bamboo Pen (S)]". Previously
            // misattributed here as CTH-470 (which is 0x00DE, listed below).
            // Pen-only: no express keys, no eraser on the LP-160 pen.
            productID: 0x00D4, name: "Bamboo Pen (CTL-460)",
            parser: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            productID: 0x00D5, name: "Bamboo Pen (CTL-660)",  // ⚠ from kernel 0xD5 (Bamboo Pen 6×8, BAMBOO_PEN family); linux-hardware "Bamboo Pen (M)"
            parser: .bamboo, maxX: 21648, maxY: 13700, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 217, activeHeightMM: 137),
        .init(
            // Same 147.2×92.0mm chassis as CTH-460 (0x00D1) — see that row's
            // manual cross-check. Confirmed 2026-08-03.
            productID: 0x00D6, name: "Bamboo Fun Pen & Touch (CTH-461)",  // dims kernel + OTD; kernel 0xD6 (BambooPT 2FG 4x5); previously misnamed CTL-460 (that's 0x00D4)
            parser: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            // Touch: kernel table declares BAMBOO_PT, touch_max = 2 — see 0x00D1's note.
            hasFingerTouch: true, maxTouchContacts: 2, touchMaxX: 480, touchMaxY: 320,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            // Same 147.2×92.0mm chassis as CTH-460 (0x00D1) — see that row's
            // manual cross-check. Confirmed 2026-08-03.
            productID: 0x00D7, name: "Bamboo Pen & Touch (small)",  // dims kernel + OTD (kernel 0xD7, BambooPT 2FG Small); ⚠ name attribution still uncertain
            parser: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            // Touch: kernel table declares BAMBOO_PT, touch_max = 2 — see 0x00D1's note.
            hasFingerTouch: true, maxTouchContacts: 2, touchMaxX: 480, touchMaxY: 320,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            // Same 147.2×92.0mm chassis as CTH-460 (0x00D1) — see that row's
            // manual cross-check. Confirmed 2026-08-03.
            productID: 0x00DA, name: "Bamboo Pen & Touch SE (CTH-461SE)",  // ⚠ from kernel 0xDA (Bamboo 2FG 4x5 SE)
            parser: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            // Touch: kernel table declares BAMBOO_PT, touch_max = 2 — see 0x00D1's note.
            hasFingerTouch: true, maxTouchContacts: 2, touchMaxX: 480, touchMaxY: 320,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            productID: 0x00DB, name: "Bamboo Pen & Touch SE (CTH-661SE)",  // dims kernel + OTD (kernel 0xDB, Bamboo 2FG 6x8 SE); ⚠ name attribution still uncertain
            parser: .bamboo, maxX: 21648, maxY: 13700, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 217, activeHeightMM: 137),
        .init(
            // libwacom wacom-bamboo-4fg-s-t.tablet: "second generation BambooPT",
            // no stylus, 2FG touch (4FG gesture). maxPressure 0 is intentional —
            // touch-only, same convention as the CTT-460 entry (0x00D0) above.
            // Caution 2026-08-03: CTT-460's pen-chassis maxX/maxY turned out
            // to be wrong on the wire (real touch space 480×320 — see its
            // note). This BPT2-generation row likely uses the later BBTOUCH3
            // format (kernel overrides those to 4096×4096), so its 14720×9200
            // is suspect too, but no capture covers this PID — left alone.
            productID: 0x00D9, name: "Bamboo Touch (CTT-460A)",  // ⚠ from libwacom
            parser: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 0,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, activeWidthMM: 127, activeHeightMM: 76),
        .init(
            // libwacom wacom-bamboo-16fg-s-t.tablet: "third generation BambooPT",
            // header comment says "no stylus; 16FG touch" despite Stylus=true in
            // the [Device] section — treated as touch-only (maxPressure 0) per
            // the descriptive comment, matching CTT-460 (0x00D9) above.
            // activeWidthMM/Height corrected to match this row's own
            // maxX/maxY at 100 lpmm (147.2×92.0mm) — the 152/102 it carried
            // before matched neither that nor the manual's stated touch
            // active area. Which coordinate space this touch-only variant
            // actually transmits in is still open — this only fixes the
            // internal inconsistency. Same caution as 0x00D9 above: after
            // CTT-460's capture proved its pen-chassis numbers wrong on the
            // wire, this third-generation row's 14720×9200 (likely BBTOUCH3,
            // kernel says 4096×4096) is suspect too; no capture, left alone.
            productID: 0x00DC, name: "Bamboo Touch (CTT-470)",  // ⚠ from libwacom
            parser: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 0,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, activeWidthMM: 147, activeHeightMM: 92),

        // ── Cintiq pen-display line — cintiqV1 parser ────────────────────────
        // seizeUSB policy for cintiqV1 pen displays:
        //   All Cintiq pen-display USB devices expose a mouse-compatible HID
        //   collection alongside the digitizer.  Without seizure the OS claims
        //   that interface and processes Report 0x01 (tip-switch) as a standard
        //   mouse click, making accurate click and pressure delivery impossible.
        //   seizeUSB=true is therefore set on every cintiqV1 pen-display entry
        //   that has a real decoder (maxX > 0), whether or not that specific PID
        //   has been hardware-confirmed.  Entries with maxX=0 (name-only stubs)
        //   stay false — seizing a device we cannot decode is strictly worse.
        // All old Cintiqs use the WACOM_24HD report layout handled by CintiqV1Decoder:
        //   Report 0x02 — pen (10-byte IntuosV1, WACOM_24HD typeNibble dispatch)
        //   Report 0x0C — express keys + touch rings
        //   Report 0x01 — tip-switch (requires device seizure)
        // 0x00C0 previously listed as "Cintiq 20WSX" and 0x00C4 as "Cintiq
        // 13HD (DTK-1300)"; both were estimation errors. Kernel identifies
        // them as DTF-720 and DTF-521 respectively — small PL-family pen
        // displays from the early 2000s. We have no PL decoder, so those
        // PIDs would not have worked even with corrected dimensions. The
        // real DTK-1300 lives at 0x0304 (an entry that already exists);
        // the real Cintiq 20WSX is kernel wacom_features_0xC5 (see the
        // 0x00C5 entry in the kernel-sweep section).
        // Entries removed during 2026-05-15 audit; do not re-add under
        // the wrong names.
        .init(
            productID: 0x00C6, name: "Cintiq 12WX",  // ⚠ estimated
            parser: .cintiqV1, maxX: 53020, maxY: 33440, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 261, activeHeightMM: 163),
        .init(
            // Kernel calls this "Cintiq 21UX2" (DTZ-2100B / second gen).
            // Pressure corrected from 1023 to 2047. Renamed to disambiguate
            // from the gen-1 21UX at 0x003F.
            // No bezelButtonCount (0 = default): unlike 24HD, this family has
            // no capacitive OSD buttons — bytes 3-4 of the pad report are
            // touch-strip position, not buttons. See CintiqV1Decoder's pad
            // decode header comment (kernel-cross-checked 2026-08-31).
            productID: 0x00CC, name: "Cintiq 21UX2 (DTK-2100)",  // model per libwacom (DTZ-2100 is the first-gen 21UX, 0x003F); from kernel + OTD
            parser: .cintiqV1, maxX: 87200, maxY: 65600, maxPressure: 2047,
            buttonCount: 18, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 432, activeHeightMM: 330),
        .init(
            productID: 0x00F4, name: "Cintiq 24HD (DTK-2400)",  // ✓ confirmed live
            parser: .cintiqV1, maxX: 104480, maxY: 65600, maxPressure: 2047,
            buttonCount: 8, bezelButtonCount: 3, hasTouchRing: true, hasDualRings: true, ringSlotCount: 3, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], ledCompanionPID: 0x0056,
            confidence: .verified,
            activeWidthMM: 519.0, activeHeightMM: 324.0),
        .init(
            // activeWidthMM/Height corrected 533/330→519.0/324.0 to match
            // 0x00F4 (Cintiq 24HD) exactly — same maxX/maxY, same physical
            // panel, and Wacom's own 24HD/24HD touch IPI booklets both state
            // an identical 518.4×324.0mm pen active area for the two variants
            // (archived at Notes/Scratch/manuals/IPI-0x00F4.pdf and
            // IPI-0x00F8.pdf, gitignored). Matched to 0x00F4's confirmed-live
            // value rather than the manual's own rounder figure — that row
            // outranks this one. Confirmed 2026-08-03.
            productID: 0x00F8, name: "Cintiq 24HD Touch (DTH-2400)",  // ⚠ estimated
            parser: .cintiqV1, maxX: 104480, maxY: 65600, maxPressure: 2047,
            buttonCount: 8, bezelButtonCount: 3, hasTouchRing: true, hasDualRings: true, ringSlotCount: 3, hasEraser: true,
            hasFingerTouch: false, maxTouchContacts: 0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], ledCompanionPID: 0x0056, activeWidthMM: 519.0, activeHeightMM: 324.0),
        .init(
            // No bezelButtonCount (0 = default): shares 21UX2's 18-button
            // pad field (byte[6]/byte[8] express keys + byte[5]/byte[7]
            // center toggles), correctly routed by CintiqV1Decoder's
            // bezelButtonCount gate. Per kernel wacom_wac.c, 22HD ALSO has a
            // distinct byte[9] 3-key field (wrench/info/keys) this decoder
            // does not yet decode — buttonCount: 20 (18 + 2 of those 3?)
            // hints at this but it's unimplemented, not just unverified.
            // Separate follow-up if pursued; not part of the 2026-08-31
            // 21UX2 phantom-OSD-button fix.
            productID: 0x00FA, name: "Cintiq 22HD (DTK-2200)",  // ⚠ from OTD (maxX corrected to kernel wacom_features_0xFA)
            parser: .cintiqV1, maxX: 95840, maxY: 54260, maxPressure: 2047,
            buttonCount: 20, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 483, activeHeightMM: 279),
        // 0x00FB previously listed as "Cintiq 21UX 2 (DTZ-2100B)" but Linux
        // input-wacom's `wacom_features_0xFB` identifies it as DTU-1031 (a
        // small entry-level DTUS pen display). The DTZ-2100B name was an
        // estimation error; corrected during the 2026-05-15 DTUS pass.

        // ── Intuos4 (PTK) additional variants ────────────────────────────────
        // activeWidthMM/HeightMM on both rows were rounded spec-sheet figures
        // rather than the digitizer's real extent. Checking every intuosV1 row
        // against `maxX / 5080 × 25.4` (the family's native resolution), all of
        // them agree to within ±0.5mm except these two and 0x0315 — the three
        // rows sourced from OTD. On 0x0029 the declared height moved the
        // opposite direction from its width, so this is a different source
        // rather than rounding. Corrected to match each row's PTH twin
        // (0x0026 and 0x0027), which carry identical maxX/maxY. Buttons and
        // coordinates untouched. See feedback on manual specs not being
        // authoritative. Corrected 2026-08-22.
        .init(
            productID: 0x0029, name: "Wacom PTK-450",  // ⚠ from OTD
            parser: .intuosV1, maxX: 31496, maxY: 19685, maxPressure: 2047,
            buttonCount: 6, hasTouchRing: true, hasKeyOLEDs: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 157, activeHeightMM: 98),
        .init(
            productID: 0x002A, name: "Wacom PTK-650",  // ⚠ from OTD
            parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasKeyOLEDs: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 224, activeHeightMM: 140),

        // ── Intuos Pro first-gen additional variant ───────────────────────────
        .init(
            // This is the PID real PTH-651 hardware enumerates as — confirmed
            // by three discovery captures from a reporter's unit, 2026-08-19.
            // (The family table above previously listed PTH-651 as 0x0316;
            // that was the error, now corrected there.)
            //
            // hasTouchRing was false, contradicted by those captures: the pad
            // report 0x03 on the 0xFF0D interface carries byte 2 = 0 plus
            // 129–199, i.e. the intuosV1 `ring1 = data[2]` layout with bit 7
            // as the active flag and bits 6–0 as the 0–127 angular position.
            // Byte 4 is a clean single-bit eight-key mask and byte 3 bit 0 is
            // the ninth bit, matching `(data[4] << 1) | (data[3] & 0x01)`.
            //
            // activeWidthMM/HeightMM were 229×152 — the rounded spec-sheet
            // figure. maxX/maxY at the family's 5080 lpi give 223.5×139.7, and
            // every other intuosV1 row agrees with that computation to within
            // ±0.5mm. Corrected to match this row's PTH-650 twin (0x0027),
            // which carries identical maxX/maxY.
            //
            // Touch: the 64-byte report 0x02 on the separate 0xFF00 interface
            // is the BPT3 container byte-for-byte — 8-byte slot stride from
            // offset 2, slot keys inside 2–17, bit-7 down flag, nibble-packed
            // 12-bit X/Y, width/height bytes. IntuosV1Decoder already
            // dispatches `id == 0x02 && length == 64` to it, so this flag is
            // the entire switch; no decoder change was needed.
            //
            // touchMaxX/Y are REASONED, not measured — the captures only ever
            // reached 3535 on one axis while the other hit 4079. Two readings
            // were possible: a genuinely lower ceiling on that axis, or an
            // under-swept axis. Anisotropic normalization settles it. If the
            // sensor used fixed counts per mm and the long axis topped out at
            // the 12-bit ceiling, the short axis would reach 4095 × 140/224 =
            // 2559. The observed 3535 is 38% above that, and this holds under
            // *either* axis assignment, so the sensor cannot be isotropic —
            // it normalizes each axis independently to the full 12-bit range.
            // Hence 4095/4095, matching PTH-850 (0x0028) and OTD's
            // PTH-850.json for the same protocol.
            //
            // Axis assignment assumed un-transposed. The asymmetry needs no
            // transposition to explain: the captures came from someone testing
            // touch, i.e. mostly vertical two-finger scrolling, which sweeps Y
            // far more than X — exactly the observed signature. The same
            // formula is already validated on PTH-850 and CTH-690, same
            // protocol family. If touch comes out rotated 90° on hardware,
            // this assumption is what to revisit first.
            //
            // maxTouchContacts mirrors CTH-690/PTH-850: slot range 2–17 is a
            // property of the protocol, not the device, so 16 is the ceiling
            // even though the spec sheet advertises 10 fingers.
            productID: 0x0315, name: "Intuos Pro M (PTH-651)",
            parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 16,
            touchMaxX: 4095, touchMaxY: 4095,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 224, activeHeightMM: 140),

        // ── Intuos Pro second-gen Bluetooth Classic PIDs (PTH-460/660/860) ──────
        // These PIDs appear when the tablet connects over BT Classic (transport="Bluetooth").
        // Coordinate ranges match the USB entries; seizeUSB=false (BT Classic needs no seizure).
        .init(
            productID: 0x0360, name: "Wacom PTH-660",  // dims kernel + OTD
            parser: .intuosV2, maxX: 44800, maxY: 29600, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            // tiltMaxDegrees 64.0: see the 0x0357/0x0358 USB entries for the
            // descriptor citation. Rarely hit (see note below), kept aligned.
            tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 5,
            // Touch values mirror the USB PTH-660 entry.  In practice this
            // entry is rarely hit: PTH-660 over BT presents the USB PID
            // 0x0357, not 0x0360, so the USB entry's touchMaxX/Y is what
            // actually drives BT touch projection (confirmed working
            // 2026-05-22).  Kept here as a defensive fallback.
            touchMaxX: 8960, touchMaxY: 5920,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 229, activeHeightMM: 152),
        .init(
            productID: 0x0361, name: "Intuos Pro L (PTH-860) BT",  // ✓ confirmed live (BT Classic)
            parser: .intuosV2, maxX: 62200, maxY: 43200, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            // tiltMaxDegrees 64.0: see the 0x0357/0x0358 USB entries for the
            // descriptor citation. Rarely hit (see note below), kept aligned.
            tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 5,
            // PTH-860 over BT presents PID 0x0358 (USB PID), not this entry —
            // same pattern as PTH-660/0x0360.  Kept as a defensive fallback.
            // Touch confirmed working 2026-05-22 via 0x0358 path.
            touchMaxX: 12439, touchMaxY: 8639,
            seizeUSB: false,
            confidence: .verified,
            activeWidthMM: 311.0, activeHeightMM: 216.0),
        // (0x035B "Intuos Pro S (PTH-460) BT" removed 2026-06-09: the PID was
        // fabricated from the PTH-660/860 "+9" BT pattern. PTH-460 shipped
        // later with PIDs 0x0392 (USB) / 0x0393 (BT); see entries below.)
        .init(
            // Kernel features_0x393 (INTUOSP2S_BT) + OTD PTH-460.json + libwacom
            // wacom-intuos-pro-2-s.tablet all agree on PIDs and coordinates.
            // 6 express keys + touch ring (libwacom's 7th button is the ring
            // center). Touch fields mirror the PTH-660 pattern: kernel reports
            // touch_max=10 but the sibling 0x21 report carries 5 slots;
            // touchMaxX/Y estimated as pen/5 like PTH-660 until captured.
            productID: 0x0392, name: "Intuos Pro S (PTH-460)",  // cross-referenced: kernel + OTD + libwacom
            parser: .intuosV2, maxX: 31920, maxY: 19950, maxPressure: 8191,
            buttonCount: 6, hasTouchRing: true, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            touchMaxX: 6384, touchMaxY: 3990,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 159.6, activeHeightMM: 99.75),
        .init(
            // Hardware-revision PID variant; OTD PTH-460.json ProductID 988 and
            // libwacom DeviceMatch usb|056a|03dc. Same device as 0x0392.
            productID: 0x03DC, name: "Intuos Pro S (PTH-460)",  // cross-referenced: OTD + libwacom
            parser: .intuosV2, maxX: 31920, maxY: 19950, maxPressure: 8191,
            buttonCount: 6, hasTouchRing: true, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            touchMaxX: 6384, touchMaxY: 3990,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 159.6, activeHeightMM: 99.75),

        // ── Bamboo / Graphire-era CTE / CTF consumer line ─────────────────────
        // Graphire-era: intuosV1 8-byte format.
        .init(
            // activeWidthMM/Height added (148/92) — this row had none. Shares
            // its exact maxX/maxY with CTE-450 (0x0017), whose active area is
            // confirmed against Wacom's Bamboo Fun manual — see that row's
            // note. Confirmed 2026-08-03.
            productID: 0x006A, name: "Wacom CTE-460",  // ⚠ from kernel
            parser: .intuosV1, maxX: 14760, maxY: 9225, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 148, activeHeightMM: 92),
        .init(
            // activeWidthMM/Height corrected 203/127→216/135 to match
            // 0x0018 (Bamboo Fun medium, CTE-650) exactly — identical
            // maxX/maxY, and 0x0018's mm is confirmed against Wacom's own
            // manual (see that row's comment). This row's 203/127 didn't
            // match its own coordinate range at any plausible resolution.
            // Confirmed 2026-08-03.
            productID: 0x006B, name: "Wacom CTE-660",  // ⚠ from kernel
            parser: .bamboo, maxX: 21648, maxY: 13530, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 216, activeHeightMM: 135),
        .init(
            // Kernel WACOM_MO "BambooFun 6x8"; libwacom CTE-650 (NumRings=1).
            // Active area 216.5×135.3mm confirmed against Wacom's Bamboo Fun
            // (CTE-450/650) User's Manual — this row's existing maxX/maxY and
            // mm (21648/13530, 216/135) already matched exactly; no change
            // needed, kept as corroboration for the sibling rows above and
            // below. Confirmed 2026-08-03.
            productID: 0x0018, name: "Bamboo Fun medium (CTE-650)",  // ⚠ from kernel/libwacom/OTD
            parser: .bamboo, maxX: 21648, maxY: 13530, maxPressure: 511,
            buttonCount: 4, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            // activeWidthMM/Height corrected 127/102→128/93. Shares its exact
            // maxX/maxY with the original Graphire/Volito 4×5 chassis
            // (127.6×92.8mm, confirmed against Wacom's Graphire manual — see
            // that family's note above). Not directly covered by the Bamboo
            // Fun manual; inferred from the shared coordinate range instead.
            // Confirmed 2026-08-03.
            productID: 0x0069, name: "Wacom CTF-430",  // ⚠ from OTD
            parser: .bamboo, maxX: 5104, maxY: 3712, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 128, activeHeightMM: 93),

        // ── Bamboo CTH (pen + touch) ──────────────────────────────────────────
        .init(
            productID: 0x0319, name: "Wacom CTH-300",  // ⚠ from OTD
            parser: .bamboo, maxX: 10690, maxY: 6680, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-bamboo-pad-wireless.tablet (Width=102, Height=76)
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 102, activeHeightMM: 76),
        .init(
            productID: 0x0318, name: "Wacom CTH-301",  // ⚠ from OTD
            parser: .bamboo, maxX: 10690, maxY: 6680, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-bamboo-pad.tablet (Width=102, Height=76)
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 102, activeHeightMM: 76),
        .init(
            // mm matched to this row's own maxX/maxY (147.2×92.0mm chassis,
            // same as 0x00D1/0x00D6/0x00D7/0x00DA) per the Bamboo 460 User's
            // Manual — see 0x00D1's note. Confirmed 2026-08-03.
            //
            // Parser corrected .intuosV1 → .bamboo 2026-08-26: kernel's static
            // table (`wacom_features_0xD2`, "Wacom Bamboo Craft") declares this
            // PID `BAMBOO_PT` — the same little-endian 2009-2011 generation as
            // 0x00D1/0x00D6/0x00D7/0x00DA, not the big-endian IntuosV1 layout.
            // OTD's CTH-461.json independently bundles this PID (210) with
            // 0x00D7 (215) and 0x00DA (218) under one config: 9-byte
            // `IntuosReportParser` for pen (little-endian family, per the
            // 0x00DE note's convention) and 20-byte `BambooV2AuxReportParser`
            // for touch/pad — exactly this decoder's `decodeBPT`/`decodeBPTTouch`
            // split. Touch enabled on the strength of that same chassis-sibling
            // match (480×320 wire space, confirmed on 0x00D1 — see its note).
            productID: 0x00D2, name: "Wacom CTH-461",  // ⚠ from OTD
            parser: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 2, touchMaxX: 480, touchMaxY: 320,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            // Same mm correction as 0x00D2 above. Confirmed 2026-08-03.
            // Parser corrected .intuosV1 → .bamboo 2026-08-03. `BambooDecoder`'s
            // own doc comment already lists CTH-470 among its "Used by"
            // devices, contradicting this row's prior `.intuosV1` assignment.
            // Independently confirmed by two more sources: OTD's CTH-470.json
            // uses `Wacom.Intuos.IntuosReportParser` (the same little-endian
            // family as CTL-471's fix elsewhere in this file) while its own
            // MaxX/MaxY (14720/9200) already match this row exactly, so only
            // the parser was wrong here, not the coordinates; and libwacom's
            // `wacom-bamboo-16fg-s-pt.tablet` (DeviceMatch=usb|056a|00de)
            // labels it "third generation BambooPT", Class=Bamboo — identical
            // wording to CTL-471's own libwacom entry. Same three-source
            // convergence that justified that fix; see its note for the full
            // reasoning. Still no hardware capture — a CTH-470 capture through
            // tools/hid_input_capture.c remains the definitive check.
            productID: 0x00DE, name: "Wacom CTH-470",  // ⚠ from OTD
            parser: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            // ⚠️ SUSPECT DECODE (2026-07-28): a real hid-recorder capture run through
            // .intuosV1 decodes to X/Y ≈130,600 regardless of this row's maxX/maxY —
            // Parser corrected .intuosV1 → .bamboo 2026-07-29. This is the INTUOSHT
            // generation (2013), whose pen report is ID 0x02 / 10 bytes / little-endian
            // — kernel wacom_bpt_pen — not the big-endian IntuosV1 layout. Under
            // .intuosV1 all four of these PIDs decoded every position to ~130,600
            // regardless of tablet size; little-endian hits registered maxX exactly on
            // all four. An earlier pass dismissed this as "not a family mismatch"
            // because the reports are 10 bytes rather than BPT's 9 — but length never
            // distinguished the families, report ID and endianness do. Their INTUOSHT2
            // successors (0x033B/033C/033D/033E) genuinely are .intuosV1; the split is
            // real and matches the kernel's. Express keys ride the 64-byte BPT3
            // container, decoded by BPT3ContainerDecoder for both generations.
            // activeHeightMM corrected 102→95 — confirmed against Wacom's
            // Intuos (CTL-480/680), Intuos touch (CTH-480/680) Important
            // Product Information booklet (archived at
            // Notes/Scratch/manuals/IPI-0x0323.pdf, gitignored): "152.0 x
            // 95.0 mm". Width was already right. Confirmed 2026-08-03.
            productID: 0x0302, name: "Wacom CTH-480",  // ⚠ from OTD
            parser: .bamboo, maxX: 15200, maxY: 9500, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // activeHeightMM corrected 102→95 — confirmed against Wacom's
            // Intuos Pen (CTL-490/690), Intuos Pen & Touch (CTH-490/690)
            // Important Product Information booklet (archived at
            // Notes/Scratch/manuals/IPI-0x033b.pdf, gitignored): "152.0 x
            // 95.0 mm". Width was already right. Confirmed 2026-08-03.
            productID: 0x033C, name: "Wacom CTH-490",  // ⚠ from OTD
            parser: .intuosV1, maxX: 15200, maxY: 9500, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // Parser corrected .intuosV1 → .bamboo 2026-08-26: kernel's static
            // table (`wacom_features_0xD3`, "Wacom Bamboo 2FG 6x8") declares
            // this PID `BAMBOO_PT`, same little-endian family as 0x00D2 above
            // — see its note. OTD's CTH-661.json bundles this PID (211) with
            // 0x00D8 (216) and 0x00DB (219) under one config, same 9-byte
            // pen / 20-byte touch-and-pad split. Touch NOT enabled here: this
            // is the 6x8 chassis, not the 4x5 one 0x00D1's 480×320 wire space
            // was confirmed on, and nothing has captured this size class's own
            // touch descriptor — leaving `hasFingerTouch` off rather than
            // guessing a wire space, per the CTT-460A/470 convention.
            productID: 0x00D3, name: "Wacom CTH-661",  // ⚠ from OTD
            parser: .bamboo, maxX: 21648, maxY: 13700, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 217, activeHeightMM: 137),
        .init(
            // Same chassis/parser fix as 0x00D3 above (kernel: "Wacom Bamboo
            // Comic 2FG", BAMBOO_PT; OTD bundles it into the same CTH-661.json
            // as 0x00D3/0x00DB). Touch not enabled for the same reason.
            productID: 0x00D8, name: "Wacom CTH-661",  // ⚠ from OTD
            parser: .bamboo, maxX: 21648, maxY: 13700, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 217, activeHeightMM: 137),
        .init(
            // Parser corrected .intuosV1 → .bamboo 2026-08-26: kernel's static
            // table (`wacom_features_0xDF`, "Wacom Bamboo 16FG 6x8") declares
            // this PID `BAMBOO_PT` with `touch_max = 16` — the 16-finger
            // capacitive generation, sibling of 0x00DE (16FG 4x5, already
            // .bamboo). OTD's CTH-670.json confirms: 9/10-byte pen via
            // `IntuosReportParser` (little-endian) plus a 64-byte
            // `Wacom64bAuxReportParser` — the BPT3 container, not the 20-byte
            // format 0x00D1-class devices use. Same gap as 0x00DE: no
            // registry row sets `hasFingerTouch` for the 64-byte container
            // path yet, so left off here too, consistently.
            //
            // activeWidthMM/activeHeightMM corrected 152×102 → 216.48×137:
            // the prior figure didn't match this row's own maxX/maxY
            // (21648×13700, ~100 lpmm like every other row in this family) at
            // all — it was CTH-480's 152×95-class number, misapplied here.
            // OTD's CTH-670.json Digitizer Width/Height (216.48/137) matches
            // maxX/maxY exactly.
            productID: 0x00DF, name: "Wacom CTH-670",  // ⚠ from OTD
            parser: .bamboo, maxX: 21648, maxY: 13700, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216.48, activeHeightMM: 137),
        .init(
            // Parser corrected .intuosV1 → .bamboo 2026-07-29 — see the note on
            // 0x0302 (CTH-480) above.
            productID: 0x0303, name: "Wacom CTH-680",  // ⚠ from OTD
            parser: .bamboo, maxX: 21600, maxY: 13500, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x033E, name: "Wacom CTH-690",  // ✓ format confirmed via user discovery capture 2026-07-03
            parser: .intuosV1, maxX: 21600, maxY: 13500, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            // Capture confirmed classic Intuos pen packets on report 0x10
            // (tool-change 0xC2, exit 0x80, pen 0xE0/0xE1) and the 64-byte
            // BPT3 container on 0x02 carrying 16-finger touch (12-bit coords)
            // plus the four express keys. Coordinate/pressure maxima are from
            // the kernel (wacom_features_0x33E); capture ranges consistent.
            // LP-190K pen has no eraser end.
            hasFingerTouch: true, maxTouchContacts: 16,
            // NOT the 12-bit ceiling, despite the 12-bit field. The kernel
            // hardcodes touch ranges for this whole protocol family because
            // the touch descriptor declares nothing usable, and it splits by
            // generation (`wacom_wac.c`, the WACOM_PKGLEN_BBTOUCH3 block):
            // INTUOSHT2 — this device — gets pen max / 10, while Intuos5/Pro
            // gets a flat 4096. 21600/10 × 13500/10 lands on exactly 10.0
            // units/mm on both axes over the 216 × 135 mm surface, and the
            // 2026-07-03 capture agrees: its Y high byte tops out at 84,
            // i.e. 1350 >> 4, exactly this ceiling. Touch pointer motion is
            // relative and scaled by coordinate/touchMax, so the previous
            // 4095/4095 divided every gesture down by 1.9× in X and 3.0× in
            // Y — a full-surface swipe crossed a third of the screen.
            touchMaxX: 2160, touchMaxY: 1350,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),

        // ── Wacom One / Intuos (CTL) pen-only line ────────────────────────────
        .init(
            // mm matched to this row's own maxX/maxY, same 147.2×92.0mm
            // chassis as the CTH-460 group — see 0x00D1's note. Confirmed
            // 2026-08-03; same open parser-family caveat as 0x00D2 applies.
            productID: 0x00DD, name: "Wacom CTL-470",  // ⚠ from OTD
            parser: .intuosV1, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            // Parser corrected .intuosV1 → .bamboo 2026-08-03. Originally
            // flagged as SUSPECT DECODE on documentation alone (Wacom's IPI
            // booklet + OTD's CTL-471.json both giving 152×95mm/15200×9500
            // against a different, little-endian wire format than
            // `.intuosV1` decodes) — same mismatch shape as the CTH-480/680,
            // CTL-480/680 fix from 2026-07-29, but without that fix's capture
            // confirmation, so left untouched at the time.
            //
            // Evidence upgraded by a third, independent, primary source:
            // libwacom's own `wacom-one-by-wacom-s-p.tablet`
            // (DeviceMatch=usb|056a|0300, matching this PID exactly) labels
            // CTL-471 "third generation BambooPT" and Class=Bamboo — the same
            // family name `BambooDecoder`'s own doc comment uses for the
            // little-endian report-ID-0x02 path. That path's dispatch
            // (`BambooDecoder.decode`, ~line 100) is keyed on report ID 0x02
            // + length 9–10, not on PID, and OTD's CTL-471.json declares
            // InputReportLength 10 — so a real CTL-471 report lands on
            // `decodeBPT`'s LE12-bit-pressure formula, which is byte-for-byte
            // what OTD's IntuosTabletReport.cs implements. Three independent
            // sources (OTD's parser choice, our own decoder's terminology,
            // libwacom's explicit classification) now converge, against a
            // decode already confirmed wrong by the active-area mismatch —
            // still no hardware capture, but the current state was already
            // confirmed broken, so this is very likely a strict improvement.
            // mm kept at OTD/manual's 152×95 rather than libwacom's
            // self-contradictory 152×102 (which disagrees with its own
            // "5.8 x 3.63in" ≈ 147×92mm comment).
            // A CTL-471 capture through tools/hid_input_capture.c would still
            // be the definitive check.
            productID: 0x0300, name: "Wacom CTL-471",  // ⚠ from kernel
            parser: .bamboo, maxX: 15200, maxY: 9500, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // activeHeightMM corrected 102→95 — confirmed against Wacom's One
            // by Wacom (CTL-472/672) Important Product Information booklet
            // (archived at Notes/Scratch/manuals/IPI-0x037a.pdf, gitignored).
            // 9500÷100=95, matching maxY exactly; width was already right.
            // Confirmed 2026-08-03.
            productID: 0x037A, name: "Wacom CTL-472",  // ⚠ from OTD
            parser: .intuosV1, maxX: 15200, maxY: 9500, maxPressure: 2047,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // Parser corrected .intuosV1 → .bamboo 2026-07-29 — see the note on
            // 0x0302 (CTH-480) above.
            // activeHeightMM corrected 102→95 — same source and correction
            // as 0x0302 (CTH-480) above. Confirmed 2026-08-03.
            productID: 0x030E, name: "Wacom CTL-480",  // ⚠ from OTD
            parser: .bamboo, maxX: 15200, maxY: 9500, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // activeHeightMM corrected 102→95 — same source and correction
            // as 0x033C (CTH-490) above. Confirmed 2026-08-03.
            productID: 0x033B, name: "Wacom CTL-490",  // ⚠ from OTD
            parser: .intuosV1, maxX: 15200, maxY: 9500, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // Kernel wacom_features_0x301 names this "Bamboo One M" (BAMBOO_PEN
            // family) — parser switched from .intuosV1 to .bamboo to match, and
            // dims corrected to the kernel values. Both unverified on hardware.
            productID: 0x0301, name: "Bamboo One M (CTL-671)",  // ⚠ from kernel + OTD
            parser: .bamboo, maxX: 21648, maxY: 13530, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x037B, name: "Wacom CTL-672",  // ⚠ from OTD
            parser: .intuosV1, maxX: 21600, maxY: 13500, maxPressure: 2047,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            // Parser corrected .intuosV1 → .bamboo 2026-07-29 — see the note on
            // 0x0302 (CTH-480) above.
            productID: 0x0323, name: "Wacom CTL-680",  // ⚠ from OTD
            parser: .bamboo, maxX: 21600, maxY: 13500, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x033D, name: "Wacom CTL-690",  // ⚠ from OTD
            parser: .intuosV1, maxX: 21600, maxY: 13500, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            // activeHeightMM corrected 102→95 — confirmed against Wacom's
            // Intuos (CTL-4100 family) Important Product Information booklet
            // (archived at Notes/Scratch/manuals/IPI-0x0374.pdf, gitignored —
            // one document covers CTL-4100/4100WL/6100/6100WL). 9500÷100=95,
            // matching maxY and the manual's "152 x 95 mm" exactly; width was
            // already right. Confirmed 2026-08-03.
            productID: 0x0374, name: "Wacom CTL-4100",  // ⚠ from OTD
            parser: .intuosV2, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, confidence: .crossReferenced,
            activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // Same correction as 0x0374 above. Confirmed 2026-08-03.
            productID: 0x0376, name: "Wacom CTL-4100WL",  // ⚠ from OTD
            parser: .intuosV2, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // Same correction as 0x0374 above. Confirmed 2026-08-03.
            productID: 0x0377, name: "Wacom CTL-4100WL",  // ⚠ from OTD
            parser: .intuosV2, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // Same correction as 0x0374 above. Confirmed 2026-08-03.
            productID: 0x03C5, name: "Wacom CTL-4100WL",  // ⚠ from OTD
            parser: .intuosV2, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            productID: 0x0375, name: "Wacom CTL-6100",  // ⚠ from OTD
            parser: .intuosV2, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x0378, name: "Wacom CTL-6100WL",  // ⚠ from OTD
            parser: .intuosV2, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x03C7, name: "Wacom CTL-6100WL",  // ⚠ from OTD
            parser: .intuosV2, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 216, activeHeightMM: 135),

        // ── Wacom One CTC (IntuosV3) consumer line ────────────────────────────
        // CTC-4110WL / CTC-6110WL use the IntuosV3 report parser (same as
        // PTK-470/670/870), not the IntuosV2 used by CTL-4100/6100.
        // Confirmed from OTD Configurations/Wacom/CTC-4110WL.json and
        // CTC-6110WL.json (FeatureInitReport "AgI=" = [0x02, 0x02]).
        // No touch ring, no express keys, no eraser — pen-only AES devices.
        .init(
            // PID collision: kernel wacom_features_0x100 is "ISDv4 100", a
            // built-in tablet-PC digitizer that can never appear standalone on
            // macOS — the modern CTC-4110WL (Wacom One S, per OTD) reuses the
            // PID and is the only device this entry can match in practice.
            productID: 0x0100, name: "Wacom CTC-4110WL",  // ⚠ from OTD
            parser: .intuosV3, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])]),
        .init(
            productID: 0x0102, name: "Wacom CTC-6110WL",  // ⚠ from OTD
            parser: .intuosV3, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x0103, name: "Wacom CTC-6110WL",  // ⚠ from OTD
            parser: .intuosV3, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 216, activeHeightMM: 135),

        // ── Cintiq pen-display additional models ──────────────────────────────
        .init(
            // Pressure and dimensions corrected to kernel wacom_features_0x304
            // (59552×33848, 1023 pressure). Previous dims were 59800×34200 (~0.4 %
            // drift); aligned during 2026-05-21 audit pass.
            //
            // ⚠️ maxPressure 1023 now has teeth (2026-07-29): CintiqV1Decoder halves
            // the 11-bit raw form whenever maxPressure ≤ 1023, so if this value is
            // wrong the device loses half its pressure range rather than merely
            // overshooting. Kept at 1023 because that is what the kernel declares —
            // but note the kernel gives 2047 for 0x0333 (13HD Touch) on the *same*
            // 59552×33848 panel, and Wacom specs the model at 2048 levels. Unresolved
            // asymmetry; needs a real DTK-1300 capture. Run it through
            // hid-trace-sweep's parity check: mostly-even values ⇒ 1023 is right.
            productID: 0x0304, name: "Wacom Cintiq 13HD (DTK-1300)",  // ⚠ from OTD
            parser: .cintiqV1, maxX: 59552, maxY: 33848, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            // activeWidthMM/Height corrected 294/165→299/171 (298.74×171.35mm)
            // per Wacom's DTK-1300/DTH-1300 Important Product Information
            // booklet (archived at Notes/Scratch/manuals/IPI-0x0304.pdf,
            // gitignored). Unrelated to the maxPressure question noted above,
            // which the manual doesn't settle either — still needs a capture.
            // Confirmed 2026-08-03.
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 299, activeHeightMM: 171),
        .init(
            productID: 0x00F9, name: "Wacom Cintiq 22HD (DTK-2200)",  // ⚠ from OTD
            parser: .cintiqV1, maxX: 95040, maxY: 54260, maxPressure: 2047,
            buttonCount: 20, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 479, activeHeightMM: 271),
        // ── IntuosV2 / IntuosV3 pen displays — seizeUSB policy ───────────────
        // IntuosV2 and IntuosV3 pen-display USB interfaces expose a
        // mouse-compatible HID collection alongside the digitizer, identical to
        // the cintiqV1 case: without seizure macOS processes Report 0x01
        // (tip-switch) as a standard mouse click.  seizeUSB=true on every
        // pen-display entry with a real decoder (maxX > 0); maxX=0 stubs stay
        // false — seizing a device we cannot decode is strictly worse.
        .init(
            productID: 0x034F, name: "Wacom DTH-1320",  // ⚠ from OTD
            parser: .intuosV2, maxX: 59552, maxY: 33848, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 294, activeHeightMM: 166),
        .init(
            // activeWidthMM/Height corrected 356/203→348/198. OTD's own
            // DTK-1660.json states 348.16×197.59mm (maxX/maxY match this row
            // exactly); Wacom's DTK-1660 IPI booklet gives 344×194mm — a
            // print-rounded figure in the same direction and rough magnitude,
            // archived at Notes/Scratch/manuals/IPI-0x0390.pdf (gitignored).
            // Both external sources sit meaningfully below this row's old
            // value; corrected toward OTD's more precise figure. Confirmed
            // 2026-08-03.
            productID: 0x0390, name: "Wacom Cintiq 16 (DTK-1660)",  // ⚠ from OTD
            parser: .intuosV2, maxX: 69632, maxY: 39518, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 348, activeHeightMM: 198),
        .init(
            // Same correction as 0x0390 above — same panel. Confirmed 2026-08-03.
            productID: 0x03AE, name: "Wacom Cintiq 16 (DTK-1660)",  // ⚠ from OTD
            parser: .intuosV2, maxX: 69632, maxY: 39518, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 348, activeHeightMM: 198),
        .init(
            productID: 0x03A6, name: "Wacom DTC-133",  // ⚠ from OTD
            parser: .intuosV2, maxX: 29434, maxY: 16556, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 279, activeHeightMM: 152),
        .init(
            productID: 0x03C0, name: "Wacom Cintiq Pro 27 (DTH-271)",  // cross-referenced: linuxwacom + libwacom + OTD
            parser: .intuosV2, maxX: 120032, maxY: 67868, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            // touchMaxX/Y from this PID's own touch report descriptor
            // (linuxwacom/wacom-hid-descriptors, 2026-08-06): Logical Maximum
            // 23848 x 13412 on report 0x0C.
            touchMaxX: 23848, touchMaxY: 13412,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 610, activeHeightMM: 330),
        .init(
            productID: 0x03F0, name: "Wacom Movink 13 (DTH-135)",  // ⚠ from OTD; buttonCount 3 per libwacom
            parser: .intuosV3, maxX: 59552, maxY: 33848, maxPressure: 8191,
            buttonCount: 3, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: false, maxTouchContacts: 0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 294.6, activeHeightMM: 165.1),

        // ── Cintiq Pro / DTK / DTH current-gen pen displays — groundwork only ──
        // groundwork only: Wacom's own macOS driver currently supports every
        // model in this block. Kept here (⚠ .experimental, not prioritized)
        // so a future decoder pass has known dimensions/PIDs if/when Wacom
        // drops support, the same rationale as the existing Cintiq Pro 32
        // (0x0352) entry above. Parser assigned by similarity to that sibling
        // (.intuosV2, isPenDisplay, seizeUSB, single [0x02,0x02] init) — none
        // of these are hardware-verified. Dimensions are libwacom Width/Height
        // (mm) × 200 units/mm, the same round factor the 0x0352 entry uses;
        // actual native resolution may differ per model.
        .init(
            // libwacom wacom-cintiq-pro-16-2.tablet: Width=356 Height=203mm,
            // Touch=true, Buttons Left=A;B;C;D Right=E;F;G;H (8 express keys).
            productID: 0x03B2, name: "Cintiq Pro 16 (DTH/DTK-1662)",  // ⚠ groundwork only
            parser: .intuosV2, maxX: 71200, maxY: 40600, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 356, activeHeightMM: 203),
        .init(
            // libwacom wacom-cintiq-pro-24-p.tablet: Width=508 Height=305mm,
            // Touch=false, no [Buttons] section (pen-only variant, no keys).
            //
            // ⚠ DIMENSIONS LIKELY WRONG the same way 0x0351's were — see the
            // correction note there. Both variants share a panel, and libwacom's
            // 508x305 gives a 1.666 aspect rather than the panel's 16:9, so this
            // row is probably also 105286 x 59574 over 526.43 x 297.87 mm. NOT
            // changed: the descriptor capture that settled 0x0351 came from the
            // touch variant, and nobody has confirmed the pen-only unit reports
            // identical maxima. Fix when a DTK-2420 descriptor turns up.
            //
            // Corroboration 2026-07-29, still short of proof: a curated catalog
            // lists one active area for both variants and gives touch as their
            // only difference, which is what the shared-panel argument above
            // assumed. That raises confidence that the values belong here too,
            // but it is an advertised figure — it says nothing about the logical
            // maxima, which are the part actually in question.
            productID: 0x037C, name: "Cintiq Pro 24 (DTK-2420, pen only)",  // ⚠ groundwork only
            parser: .intuosV2, maxX: 101600, maxY: 61000, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 508, activeHeightMM: 305),
        .init(
            // Dimensions corrected 2026-07-28 from this unit's own HID report
            // descriptor (a real capture, published in a third-party macOS driver
            // project). The pen report declares Logical Maximum 105286 x 59574 and
            // Physical Maximum 526.43 x 297.87 mm — exactly 200 units/mm on both
            // axes, aspect 1.767, which matches the 3840x2160 16:9 panel.
            //
            // The previous values came from libwacom's Width=508 Height=305mm,
            // which give aspect 1.666 — not 16:9, so libwacom is measuring
            // something other than the digitizer's active area here. Density was
            // coincidentally also 200 units/mm, so mapping was self-consistent but
            // wrong at the edges by roughly 4% horizontally and 2% vertically.
            //
            // Also confirmed from the same descriptor: parser .intuosV2 is correct
            // (report 0x10 fields match this decoder byte for byte), maxPressure
            // 8191 is correct (declared Logical Maximum 0x1FFF), and the init step
            // below is correct — vendor usage 0xFF0D1002 (kernel WD_DATAMODE) sits
            // on feature report 0x02 with declared valid range 1...2, so writing
            // [0x02, 0x02] is exactly the documented switch into full data mode.
            //
            // ── Descriptor-derived vs. inferred, for this row ──
            //
            // Descriptor-derived (the four fields above plus the init step):
            // logical maxima, physical size, pressure ceiling, mode-switch write.
            //
            // buttonCount stays 0, and that is not an omission. This display has
            // no express keys at all: Wacom's own documentation for it ships every
            // express key on a detachable ExpressKey Remote, the same arrangement
            // 0x032A (Cintiq 27QHD) documents a few rows up.
            //
            // What report 0x11 does declare — four one-bit buttons at vendor
            // usages 0x0981, 0x0982, 0x0983, 0x0986 in byte [1] — are the "Touch
            // Keys", a lit row along the top edge of the panel. Documented
            // functions, in order: video input source, Wacom Center, toggle
            // on-screen keyboard, Wacom Display Settings, and touch on/off. Five
            // keys, four declared bits, and the usage numbering skips 0x0984 and
            // 0x0985 — consistent with touch on/off being handled in firmware
            // rather than forwarded, which also fits report 0x13 appearing in this
            // same descriptor (8 constant bytes, usage 0xFF0D1013 — the report
            // that carries touch-switch state on PTH-860).
            //
            // These are display-function keys, not drawing shortcuts, and Wacom's
            // documentation offers no way to reassign them — only a long-press
            // requirement to avoid accidental taps. So `buttonCount` is the wrong
            // field for them twice over: they are not express keys, and treating
            // them as bindable would imply a freedom the hardware's own vendor
            // does not offer. `bezelButtonCount` is the right field by intent
            // (that is what it holds for the DTK-2400's OSD keys) but does not fit
            // yet: it caps at three downstream (`InputInjector` loops 0..<3 over
            // bezelButtonBindings) and no .intuosV2 path emits buttons[16...18] —
            // only CintiqV1Decoder does. Wiring a fourth means widening that
            // binding set and routing report 0x11's low bits there, which is a
            // feature, not a registry value.
            //
            // Worth knowing for whoever picks that up: without Wacom's driver
            // these four keys do nothing at all, so binding them would be additive
            // rather than a conflict.
            //
            // The remote is 0x0331, still a name-only row with no pad decode. Its
            // buttonCount 18 against Wacom's advertised "17 ExpressKeys and a
            // Touch Ring" is the usual spec-sheet-versus-kernel-total gap, not an
            // error — the ring's center click is the eighteenth.
            //
            // maxTouchContacts 5 replaces an inherited 10. Nothing here supports
            // 10: `IntuosV2Decoder.decodeTouchReport` reads report 0x21 as five
            // fixed 8-byte slots and caps at `min(count, 5)`, so five is the most
            // the pipeline can deliver. The field only feeds the Touch and
            // Scratchpad panes, so this corrects an advertised capability rather
            // than a decode path. Several sibling .intuosV2 rows still say 10 and
            // have the same ceiling; left alone pending their own review.
            //
            // touchMaxX/touchMaxY deliberately left 0 = unknown. The capture that
            // settled everything else covers a single interface with no touch
            // collection at all, so there is no descriptor basis for a touch
            // coordinate range, and the Intuos `pen / 5` estimate used elsewhere
            // in this file is a quirk of that sensor family, not a general rule —
            // applying it here would invent provenance. Consequence to know:
            // `InputInjector` clamps a 0 maximum to 1, so enabling touch on this
            // device before a real range exists yields saturated coordinates.
            // Touch is opt-in (`touchEnabled` defaults false), so nothing
            // misbehaves until someone turns it on. A touch-interface descriptor
            // or capture settles it.
            productID: 0x0351, name: "Cintiq Pro 24 (DTH-2420, touch)",
            parser: .intuosV2, maxX: 105286, maxY: 59574, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 526.43, activeHeightMM: 297.87),
        .init(
            // libwacom wacom-cintiq-22.tablet: Width=483 Height=254mm,
            // Touch=false, no [Buttons] section (pen-only, non-Pro Cintiq 22).
            productID: 0x0391, name: "Cintiq 22 (DTK-2200)",  // ⚠ groundwork only
            parser: .intuosV2, maxX: 96600, maxY: 50800, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 483, activeHeightMM: 254),
        .init(
            // libwacom wacom-dtk-1660e.tablet: Width=356 Height=203mm, no touch,
            // no buttons. First-revision PID; 0x03B0 below is a hardware-revision
            // sibling with identical dimensions (same pattern as Cintiq 16's
            // 0x0390/0x03AE pair already in this registry).
            productID: 0x0396, name: "DTK-1660E",  // ⚠ groundwork only
            parser: .intuosV2, maxX: 71200, maxY: 40600, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 356, activeHeightMM: 203),
        .init(
            // libwacom wacom-dtk-1660e-2.tablet: hardware-revision sibling of
            // 0x0396, identical dimensions.
            productID: 0x03B0, name: "DTK-1660E",  // ⚠ groundwork only
            parser: .intuosV2, maxX: 71200, maxY: 40600, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 356, activeHeightMM: 203),
        .init(
            // libwacom wacom-dtk-168e.tablet: Width=356 Height=203mm, no touch,
            // no buttons.
            productID: 0x03EE, name: "DTK-168E",  // ⚠ groundwork only
            parser: .intuosV2, maxX: 71200, maxY: 40600, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 356, activeHeightMM: 203),
        .init(
            // libwacom wacom-dtk-246e.tablet: Width=533 Height=305mm, no touch,
            // no buttons.
            productID: 0x03EF, name: "DTK-246E",  // ⚠ groundwork only
            parser: .intuosV2, maxX: 106600, maxY: 61000, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 533, activeHeightMM: 305),
        .init(
            // libwacom wacom-dth-1152.tablet: Width=229 Height=127mm, Touch=true,
            // no [Buttons] section, header note "Stylus does not have an
            // eraser". PID 0x035A previously misattributed in canonicalPIDMap
            // as an unsourced PTH-860 wireless-dongle guess — removed above
            // 2026-07-17 in favor of this libwacom-sourced identity.
            productID: 0x035A, name: "DTH-1152",  // ⚠ groundwork only
            parser: .intuosV2, maxX: 45800, maxY: 25400, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            hasFingerTouch: true, maxTouchContacts: 5,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 229, activeHeightMM: 127),
        .init(
            // libwacom wacom-dth-2452.tablet: Width=508 Height=305mm, Touch=true,
            // Buttons Right=A;B;C;D (4 express keys).
            productID: 0x037D, name: "DTH-2452",  // ⚠ groundwork only
            parser: .intuosV2, maxX: 101600, maxY: 61000, maxPressure: 8191,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 508, activeHeightMM: 305),
        .init(
            // libwacom wacom-dth-246e.tablet: Width=533 Height=305mm, Touch=true,
            // no [Buttons] section.
            productID: 0x03FF, name: "DTH-246E",  // ⚠ groundwork only
            parser: .intuosV2, maxX: 106600, maxY: 61000, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 533, activeHeightMM: 305),
        .init(
            // libwacom wacom-dtu-1141b.tablet: Width=229 Height=127mm,
            // Touch=false, Buttons Top=A;B;C;D (4 express keys). PID 0x0359
            // previously misattributed in canonicalPIDMap as an unsourced
            // PTH-660 wireless-dongle guess — removed above 2026-07-17 in
            // favor of this libwacom-sourced identity.
            productID: 0x0359, name: "DTU-1141B",  // ⚠ groundwork only
            parser: .intuosV2, maxX: 45800, maxY: 25400, maxPressure: 8191,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 229, activeHeightMM: 127),
        .init(
            // libwacom wacom-one.tablet: DeviceMatch usb|056a|03a6;usb|056a|03bd,
            // Width=279 Height=152mm — same physical panel already registered
            // as 0x03A6 "Wacom DTC-133" above (identical dims). 0x03BD is a
            // second PID for the same hardware sold under the "Wacom One"
            // branding; added as its own entry rather than folded into the
            // 0x03A6 spec since productID is this table's primary key.
            productID: 0x03BD, name: "Wacom One (DTC-133)",  // ⚠ groundwork only
            parser: .intuosV2, maxX: 29434, maxY: 16556, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 279, activeHeightMM: 152),

        // ── Cintiq Companion / Companion 2 / Companion Hybrid — NOT added ──────
        // Considered for this pass but these are standalone Windows tablet-PCs
        // (libwacom Class=Cintiq, IntegratedIn=Display;System for 0x030A/0x0325;
        // IntegratedIn=Display for the Hybrid at 0x0307) — the digitizer is
        // built into a self-contained Windows computer, not a USB peripheral a
        // Mac could ever attach to and drive. Skipped as out of scope, same
        // reasoning as the ISDV4 tablet-PC entries excluded elsewhere in this
        // registry.

        // ── Wireless dongle ───────────────────────────────────────────────────
        // ACK-40401 RF dongle (PID 0x0084) presents the same HID interfaces as
        // the paired tablet.  WacomFallbackDevice auto-detects the report family.
        // Report 0x80 carries wireless status (byte[1]: 0x02=active, 0x05=lost,
        // 0x06=battery low).  maxX/maxY/maxPressure are 0 — queried via HID
        // descriptor on first connection by WacomFallbackDevice.querySpec().
        .init(
            productID: 0x0084, name: "ACK-40401 Wireless Dongle",
            parser: .intuosV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false),

        // ── Wireless receiver dongles (HID-based) ─────────────────────────────
        // Blueto WL tablets (Intuos4 WL, Intuos5 WL, Intuos Pro gen1 WL) pair with
        // USB wireless receivers instead of integrated Bluetooth. The receiver
        // enumerates as HID and presents the paired tablet's report format.
        // These are experimental (untested on owned hardware).
        .init(
            productID: 0x009D, name: "Wireless Receiver (Intuos4/5 WL)",  // ⚠ experimental
            parser: .intuosV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])]),
        .init(
            // Kernel wacom_features_0x9A identifies this as "ISDv4 9A", a
            // built-in tablet-PC digitizer (TABLETPC type) — the previous
            // "Wireless Receiver (Intuos Pro gen1 WL)" name was a guess; the
            // real wireless receiver is the ACK-40401 at 0x0084. maxX 0 keeps
            // this name-only (never routed to a driver).
            productID: 0x009A, name: "Wacom ISDv4 9A (built-in digitizer)",  // ⚠ from kernel
            parser: .intuosV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false),

        // ── Upstream OTD sync 2026-05-15 ──────────────────────────────────────
        // Imported from OpenTabletDriver master, not yet in Linux input-wacom
        // (4.18 branch, April 2026). Pen-only; coordinates and pressure
        // extrapolated from OTD configs and unverified on hardware.
        //
        // PL-800-U was NOT imported — PLReportParser uses 8-byte reports
        // with bit-6 in-range, incompatible with our IntuosV1 decoder and
        // not worth a dedicated parser for hardware that's effectively gone.
        // See Notes/Scratch/Upstream-Sync-2026-05-15.md for the analysis.
        .init(
            productID: 0x03CE, name: "Wacom One Pen Display 12 (DTC-121)",  // ⚠ from OTD; name per libwacom
            parser: .intuosV2, maxX: 25632, maxY: 14418, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 279, activeHeightMM: 152),
        .init(
            productID: 0x005B, name: "Wacom Cintiq 22HD Touch (DTH-2200)",  // ⚠ from OTD (dims corrected to kernel wacom_features_0x5B)
            parser: .cintiqV1, maxX: 95840, maxY: 54260, maxPressure: 2047,
            buttonCount: 20, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: false, maxTouchContacts: 0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 483, activeHeightMM: 279),
        .init(
            productID: 0x03D0, name: "Wacom Cintiq Pro 22 (DTH-227)",  // cross-referenced: linuxwacom + libwacom + OTD
            parser: .intuosV2, maxX: 96012, maxY: 54356, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 457, activeHeightMM: 254),
        .init(
            // Dimensions corrected 2026-07-29 — see the density note on the M
            // size below. 37400/187 and 21000/105 are both exactly 200 units/mm;
            // the previous 178 x 102 gave 210.1 x 205.9, anisotropic and round in
            // neither axis.
            //
            // hasTouchRing left false pending its own capture — see libwacom's
            // wacom-intuos-pro-3-s.tablet (checked 2026-09-03): it actually
            // claims 5 buttons AND NumDials=1 (one button doubles as the
            // dial's press), a different physical layout than M/L's 8-key +
            // 2-separate-dial-press arrangement, and our decodeAuxReport byte
            // layout is untested against it. Known open bug, not fixed here —
            // if this row's hasTouchRing is ever corrected to true, it should
            // also get hasMechanicalDial: true, matching M/L below.
            productID: 0x03F5, name: "Intuos Pro S gen 3 (PTK-470)",  // cross-referenced: OTD + libwacom (2025 model)
            parser: .intuosV3, maxX: 37400, maxY: 21000, maxPressure: 8191,
            buttonCount: 5, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 187, activeHeightMM: 105),
        .init(
            // buttonCount/hasTouchRing/hasDualRings corrected 2026-07-28 from a
            // real PTK-870 capture (see IntuosV3Decoder.decodeAuxReport):
            // this family has 8 express keys and two dials, not 10 express keys
            // and no ring. The two dial usages are literally named "Wacom
            // TouchRing" (x2) in the device's own descriptor. Applied to M and L
            // (both known to ship with twin dials on real hardware); S (PTK-470,
            // above) is left at buttonCount 5/no ring pending its own capture —
            // smaller Intuos Pro units have traditionally shipped without dials.
            //
            // The two bits in aux byte [3] are NOT dial presses: the dials rotate
            // only. They are the center key of each express-key cluster — vendor
            // documentation describes "four customizable keys on the outside and
            // one in the middle" per cluster, which is where the eight outer keys
            // plus these two come from, and gives the middle key a default of
            // "Dial toggle". Wording corrected 2026-07-29.
            //
            // ── Dimensions corrected 2026-07-29 ──
            //
            // This family runs at exactly 200 units/mm, the same density the
            // DTH-2420 descriptor declares outright a few hundred rows up. Against
            // that constant, the logical maxima imply 187 x 105 (S), 263 x 148 (M)
            // and 349 x 195 (L). A curated third-party catalog independently lists
            // 187 x 105 and 349 x 195 for S and L — matching to the millimeter —
            // and 264 x 148 for M.
            //
            // Stored values follow the 200 units/mm constant, so M is 263 rather
            // than the catalog's 264: maxY/148 is exactly 200 on this size, and
            // both sibling sizes are exactly 200 on both axes, so the family
            // density is not in doubt. One of maxX 52600 and that 264 is off by
            // about 0.4%; which one needs a real PTK-670 descriptor to settle.
            //
            // Previous values (254 x 152 here, 356 x 203 on L, 178 x 102 on S)
            // were libwacom's advertised drawing areas and produced densities of
            // 207.1 x 194.7, 196.1 x 192.1 and 210.1 x 205.9 — none round, none
            // even isotropic. Textbook case of the distinction documented on
            // `activeWidthMM`.
            productID: 0x03F7, name: "Intuos Pro M gen 3 (PTK-670)",  // cross-referenced: OTD + libwacom (2025 model)
            parser: .intuosV3, maxX: 52600, maxY: 29600, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasDualRings: true, hasMechanicalDial: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 263, activeHeightMM: 148),
        .init(
            // Dimensions corrected 2026-07-29; 69800/349 and 39000/195 are both
            // exactly 200 units/mm. See the density note on the M size above.
            productID: 0x03F9, name: "Intuos Pro L gen 3 (PTK-870)",  // cross-referenced: OTD + libwacom (2025 model); dials hardware-confirmed
            parser: .intuosV3, maxX: 69800, maxY: 39000, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasDualRings: true, hasMechanicalDial: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 349, activeHeightMM: 195),
        .init(
            productID: 0x03E6, name: "Wacom Cintiq 16 gen 3 (DTK-168)",  // ⚠ recognition-only; PID + dims from libwacom (wacom-cintiq-16-3), logical extents copied from same-size DTK-1660
            parser: .intuosV2, maxX: 69632, maxY: 39518, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 356, activeHeightMM: 203),
        .init(
            productID: 0x040F, name: "Wacom One 14 (DTC-141)",  // ⚠ recognition-only; PID + dims from libwacom (wacom-one-14), logical extents estimated at the One 13's ~105.5 units/mm
            parser: .intuosV2, maxX: 32180, maxY: 18779, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 305, activeHeightMM: 178),

        // ── DTUS family (Linux input-wacom DTUS / DTUSX) ──────────────────────
        // Small entry-level pen displays sharing wacom_dtus_irq.  Dimensions
        // and button counts from input-wacom 4.18 wacom_wac.c, decoded by
        // DTUSDecoder.swift.  Experimental: pen events should decode but no
        // hardware verification yet.  Feature init [0x02, 0x02] sent on the
        // chance some firmware revisions require it; the kernel block does
        // not specify a .feature_init array so it may be unnecessary.
        .init(
            productID: 0x0343, name: "Wacom DTK1651",  // ⚠ from kernel
            parser: .dtus, maxX: 34816, maxY: 19759, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 356, activeHeightMM: 203),
        .init(
            productID: 0x00FB, name: "Wacom DTU-1031",  // ⚠ from kernel
            parser: .dtus, maxX: 22096, maxY: 13960, maxPressure: 511,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            // dimensions: libwacom wacom-dtu-1031.tablet (Width=229, Height=127).
            // Kernel math (22096/100 × 13960/100) gives 221×140 — height is
            // wrong (digitiser maxY over-ranges past the bezel).
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 229, activeHeightMM: 127),
        .init(
            productID: 0x032F, name: "Wacom DTU-1031X",  // ⚠ from kernel
            parser: .dtus, maxX: 22672, maxY: 12928, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 229, activeHeightMM: 127),
        .init(
            productID: 0x0336, name: "Wacom DTU-1141",  // ⚠ from kernel
            parser: .dtus, maxX: 23672, maxY: 13403, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 229, activeHeightMM: 127),

        // ── DTU family (Linux input-wacom DTU type, wacom_dtu_irq) ────────────
        // Older entry-level pen displays. Single pen report 0x02 (LE16 X/Y,
        // 9-bit pressure). No pad buttons.  Decoded by DTUDecoder.swift.
        // Dimensions and pressure from input-wacom 4.18 wacom_wac.c.
        // Experimental: no hardware verification yet.
        .init(
            productID: 0x00CE, name: "Wacom DTU-2231",  // ⚠ from kernel
            parser: .dtu, maxX: 47864, maxY: 27011, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 483, activeHeightMM: 279),
        .init(
            productID: 0x00F0, name: "Wacom DTU-1631",  // ⚠ from kernel
            parser: .dtu, maxX: 34623, maxY: 19553, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 356, activeHeightMM: 203),
        .init(
            // DTI-520: old fiber-optic interactive pen display (~2001), the
            // oldest Wacom pen display in this registry. libwacom
            // wacom-dti-520.tablet: Width=356 Height=305mm, 10 usable buttons
            // (Top=F;G;H;I;J, Bottom=B;A;D;E;C — libwacom notes an 11th button
            // exists but the two Ctrl keys share one scancode), and "does not
            // appear to support erasers on styli". No confirmed protocol
            // family for this era predates the .dtu/.dtus decoders were built
            // against — .dtu picked as the closest-generation sibling (single
            // 0x02 pen report, no pad report modeled by that decoder either).
            // maxX reused from DTU-1631 (0x00F0) which shares the 356mm width;
            // maxY scaled by the same per-mm ratio for the taller 305mm panel.
            // Wholly unverified: parser assignment is a guess, not a match.
            productID: 0x003A, name: "DTI-520",  // ⚠ recognition-only, parser unverified
            parser: .dtu, maxX: 34623, maxY: 29354, maxPressure: 511,
            buttonCount: 10, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 356, activeHeightMM: 305),

        // ── Tablet-PC ISDV4 PIDs 0x0090/0x0093 — deliberately NOT added ────────
        // Considered for this pass (early Tablet-PC ISDV4 PIDs) but both
        // libwacom entries carry IntegratedIn=Display;System:
        //   wacom-isdv4-90.tablet (ASUS R1E/R1F)      — laptop-integrated digitizer
        //   wacom-isdv4-93.tablet (HP Pavilion TX2000/TX2500) — same
        // Both are built into the laptop's own screen/system, not standalone
        // peripherals a Mac could ever enumerate — skipped per the same policy
        // that excludes other ISDV4 entries from this registry.

        // ── Imported from wacom-hid-descriptors 2026-05-26 ─────────────────────
        // Recognition-only entries for devices that appear in real linuxwacom
        // sysinfo dumps (https://github.com/linuxwacom/wacom-hid-descriptors)
        // but were absent from this registry.  Parser family, maxX/maxY, and
        // pressure bit-depth are *guesses* by similarity to the closest in-
        // registry relative — these entries name the device and provide
        // libwacom-derived physical dimensions, but the decoder output is not
        // verified.  Each one is `.experimental` and a candidate for promotion
        // once a real capture log (in-app or hid-recorder format) replays
        // cleanly through the assumed parser.
        .init(
            productID: 0x0325, name: "Wacom Cintiq Companion 2 (DTH-W1310)",  // ⚠ recognition-only (dims from kernel wacom_features_0x325)
            parser: .cintiqV1, maxX: 59552, maxY: 33848, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: false, maxTouchContacts: 0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 294, activeHeightMM: 166),
        .init(
            productID: 0x0326, name: "Wacom Cintiq Companion 2 (DTH-W1310, alt)",  // ⚠ recognition-only
            parser: .cintiqV1, maxX: 61000, maxY: 35600, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: false, maxTouchContacts: 0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 294, activeHeightMM: 166),
        .init(
            productID: 0x034D, name: "Wacom MobileStudio Pro 13 (DTH-W1320)",  // ⚠ recognition-only; touch is a separate USB device (0x034A)
            parser: .intuosV2, maxX: 61000, maxY: 35600, maxPressure: 8191,
            buttonCount: 6, hasTouchRing: true, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 294, activeHeightMM: 165),
        .init(
            productID: 0x034E, name: "Wacom MobileStudio Pro 16 (DTH-W1620)",  // ⚠ recognition-only; touch is a separate USB device (0x034B)
            parser: .intuosV2, maxX: 71200, maxY: 40600, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 356, activeHeightMM: 203),
        .init(
            productID: 0x0350, name: "Wacom Cintiq Pro 16 (DTH-1620)",  // ⚠ recognition-only
            parser: .intuosV2, maxX: 71200, maxY: 40600, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            // touchMaxX/Y from the paired 0x0354 interface's own touch report
            // descriptor (linuxwacom/wacom-hid-descriptors, 2026-08-06):
            // Logical Maximum 13824 x 7776 on report 0x0C.
            touchMaxX: 13824, touchMaxY: 7776,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 356, activeHeightMM: 203),
        .init(
            productID: 0x0354, name: "Wacom Cintiq Pro 16 (DTH-1620, alt)",  // ⚠ recognition-only
            parser: .intuosV2, maxX: 71200, maxY: 40600, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            // touchMaxX/Y confirmed directly from this PID's own touch report
            // descriptor (linuxwacom/wacom-hid-descriptors, 2026-08-06):
            // Logical Maximum 13824 x 7776 on report 0x0C.
            touchMaxX: 13824, touchMaxY: 7776,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 356, activeHeightMM: 203),
        .init(
            productID: 0x0379, name: "Wacom Intuos BT M (CTL-6100WL)",  // ⚠ recognition-only
            parser: .intuosV2, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 229, activeHeightMM: 127),
        .init(
            productID: 0x0398, name: "Wacom MobileStudio Pro 13 (DTH-W1321)",  // ⚠ recognition-only; touch is a separate USB device (0x039A)
            parser: .intuosV2, maxX: 61000, maxY: 35600, maxPressure: 8191,
            buttonCount: 6, hasTouchRing: true, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 294, activeHeightMM: 165),
        .init(
            productID: 0x0399, name: "Wacom MobileStudio Pro 16 (DTH-W1621)",  // ⚠ recognition-only; touch is a separate USB device (0x039B)
            parser: .intuosV2, maxX: 71200, maxY: 40600, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 356, activeHeightMM: 203),
        .init(
            productID: 0x03AA, name: "Wacom MobileStudio Pro 16 (DTH-W1620, alt)",  // ⚠ recognition-only; touch is a separate USB device (0x03AC)
            parser: .intuosV2, maxX: 71200, maxY: 40600, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 356, activeHeightMM: 203),
        .init(
            productID: 0x03C4, name: "Wacom Cintiq Pro 17 (DTH172)",  // ⚠ recognition-only; buttonCount 8 per libwacom
            parser: .intuosV2, maxX: 76200, maxY: 40600, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            // touchMaxX/Y decoded from this PID's own raw touch report
            // descriptor via TabletKit's descriptor-dump tool
            // (linuxwacom/wacom-hid-descriptors, 2026-08-06): Logical Maximum
            // 15276 x 8592 on report 0x0C.
            touchMaxX: 15276, touchMaxY: 8592,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 381, activeHeightMM: 203),
        .init(
            productID: 0x03CB, name: "Wacom One Pen Display 13 (DTH134)",  // ⚠ recognition-only; touch per libwacom
            parser: .intuosV2, maxX: 34815, maxY: 18779, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 330, activeHeightMM: 178),
        .init(
            productID: 0x03CF, name: "Wacom DTC121 (alt)",  // ⚠ recognition-only
            parser: .intuosV2, maxX: 29434, maxY: 16036, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 279, activeHeightMM: 152),
        .init(
            productID: 0x03EC, name: "Wacom DTH134",  // ⚠ recognition-only; touch per libwacom
            parser: .intuosV2, maxX: 34815, maxY: 18779, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            // touchMaxX/Y decoded from this PID's own raw touch report
            // descriptor via TabletKit's descriptor-dump tool
            // (linuxwacom/wacom-hid-descriptors, 2026-08-06): Logical Maximum
            // 11752 x 6608 on report 0x0C.
            touchMaxX: 11752, touchMaxY: 6608,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 330, activeHeightMM: 178),
        .init(
            productID: 0x03ED, name: "Wacom DTC121",  // ⚠ recognition-only
            parser: .intuosV2, maxX: 29434, maxY: 16036, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 279, activeHeightMM: 152),
        .init(
            productID: 0x03F2, name: "Wacom Movink 13 (DTH-135, alt)",  // ⚠ recognition-only; buttonCount 3 per libwacom
            parser: .intuosV3, maxX: 59552, maxY: 33848, maxPressure: 8191,
            buttonCount: 3, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: false, maxTouchContacts: 0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 294.6, activeHeightMM: 165.1),
        .init(
            productID: 0x4900, name: "Wacom DTC121 (alt 2)",  // ⚠ recognition-only
            parser: .intuosV2, maxX: 29434, maxY: 16036, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 279, activeHeightMM: 152),

        // ── Kernel sweep 2026-06-09 ───────────────────────────────────────────
        // PIDs present in input-wacom's device table but previously absent
        // here. Dimensions and button counts come from the corresponding
        // wacom_features_0xXX structs. Entries with maxX 0 are deliberately
        // name-only: their report family has no decoder (PL line) or they are
        // non-digitizer interfaces — DeviceRouter only attaches a driver when
        // maxX > 0, so these resolve a correct device name and nothing else.

        // Decoder-family matches (full entries, ⚠ from kernel unless noted):
        .init(
            // activeWidthMM/Height added — this row had none. Shares its exact
            // maxX/maxY with Graphire4 6×8 (CTE-640), whose 208.8×150.8mm
            // active area is confirmed against Wacom's own manual — see that
            // row's note. Confirmed 2026-08-03.
            productID: 0x0019, name: "Bamboo1 Medium",  // ⚠ from kernel (graphire family)
            parser: .graphire, maxX: 16704, maxY: 12064, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, activeWidthMM: 209, activeHeightMM: 151),
        .init(
            productID: 0x0047, name: "Intuos 2 (6×8, alt)",  // ⚠ from kernel — second XD-0608-U PID
            // Same 6×8 active area as 0x0021 (GD-0608-U) — see the Intuos 1
            // family note for why the coordinate range is doubled.
            parser: .intuosV1, maxX: 40640, maxY: 32480, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 203, activeHeightMM: 162),
        .init(
            productID: 0x0063, name: "Volito 2 (2×3)",  // ⚠ from kernel
            parser: .graphire, maxX: 3248, maxY: 2320, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false),
        .init(
            productID: 0x0064, name: "PenPartner2",  // ⚠ from kernel — sibling of PenStation2 0x0061
            parser: .graphire, maxX: 3250, maxY: 2320, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false),
        .init(
            // activeWidthMM/Height added — this row had none. 479.2×271.3mm
            // per Wacom's DTK-2241/DTH-2242 Important Product Information
            // booklet (archived at Notes/Scratch/manuals/IPI-0x0057.pdf,
            // gitignored); divides the kernel's maxX/maxY exactly at 200
            // lpmm, corroborating both sources at once. Confirmed 2026-08-03.
            productID: 0x0057, name: "Cintiq 22 (DTK-2241)",  // ⚠ from kernel (DTK type, 6 keys)
            parser: .cintiqV1, maxX: 95840, maxY: 54260, maxPressure: 2047,
            buttonCount: 6, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 479, activeHeightMM: 271),
        .init(
            // activeWidthMM/Height added — same source and figure as 0x0057
            // above (same panel). Confirmed 2026-08-03.
            productID: 0x0059, name: "Cintiq 22 Touch (DTH-2242)",  // ⚠ from kernel (DTK type, 6 keys)
            parser: .cintiqV1, maxX: 95840, maxY: 54260, maxPressure: 2047,
            buttonCount: 6, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: false, maxTouchContacts: 0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 479, activeHeightMM: 271),
        .init(
            // activeWidthMM/Height added — this row had none. 433.4×270.9mm
            // per Wacom's Cintiq 20WSX User's Manual (archived at
            // Notes/Scratch/manuals/Cintiq20WSX-DTZ2000W-UserManual.pdf,
            // gitignored); divides the kernel's maxX/maxY exactly at 200
            // lpmm, and the manual's stated 1024 pressure levels matches this
            // row's maxPressure too — corroborating both fields at once.
            // Confirmed 2026-08-03.
            productID: 0x00C5, name: "Cintiq 20WSX (DTZ-2000W)",  // ⚠ from kernel (WACOM_BEE type)
            parser: .cintiqV1, maxX: 86680, maxY: 54180, maxPressure: 1023,
            buttonCount: 10, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 433, activeHeightMM: 271),
        .init(
            // 27QHD uses the ExpressKey Remote (0x0331) instead of bezel keys.
            // activeWidthMM/Height added — this row had none. 596.7×335.6mm
            // per Wacom's DTK-2700/DTH-2700 Important Product Information
            // booklet (archived at Notes/Scratch/manuals/IPI-0x032A.pdf,
            // gitignored), same figure for both the pen and touch active
            // area. Confirmed 2026-08-03.
            productID: 0x032A, name: "Cintiq 27QHD (DTK-2700)",  // ⚠ from kernel (WACOM_27QHD type)
            parser: .cintiqV1, maxX: 120140, maxY: 67920, maxPressure: 2047,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 597, activeHeightMM: 336),
        .init(
            // Pen interface of the touch model; finger touch arrives on the
            // separate 0x032C interface (layout unconfirmed — see name-only
            // entry below). activeWidthMM/Height added — same source and
            // figure as 0x032A above. Confirmed 2026-08-03.
            productID: 0x032B, name: "Cintiq 27QHD Touch (DTH-2700)",  // ⚠ from kernel
            parser: .cintiqV1, maxX: 120140, maxY: 67920, maxPressure: 2047,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: false, maxTouchContacts: 0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 597, activeHeightMM: 336),
        .init(
            // Pen interface; finger touch arrives on the separate 0x0335
            // interface (layout unconfirmed).
            // activeWidthMM/Height added — this row had none. Shares its
            // exact pen active area with 0x0304 (DTK-1300) per Wacom's own
            // IPI booklet for this model pair — see that row's note.
            // Confirmed 2026-08-03.
            productID: 0x0333, name: "Cintiq 13HD Touch (DTH-1300)",  // dims kernel (WACOM_13HD type) + OTD
            parser: .cintiqV1, maxX: 59552, maxY: 33848, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: false, maxTouchContacts: 0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 299, activeHeightMM: 171),

        // Name-only: PL report family (wacom_pl_irq) has no decoder here.
        // Kernel dims in comments for when one lands.
        .init(
            productID: 0x0030, name: "PL400",  // ⚠ name-only; kernel: 5408×4056×255 (PL)
            parser: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true, seizeUSB: false),
        .init(
            productID: 0x0031, name: "PL500",  // ⚠ name-only; kernel: 6144×4608×255 (PL)
            parser: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true, seizeUSB: false),
        .init(
            productID: 0x0032, name: "PL600",  // ⚠ name-only; kernel: 6126×4604×255 (PL)
            parser: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true, seizeUSB: false),
        .init(
            productID: 0x0033, name: "PL600SX",  // ⚠ name-only; kernel: 6260×5016×255 (PL)
            parser: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true, seizeUSB: false),
        .init(
            productID: 0x0034, name: "PL550",  // ⚠ name-only; kernel: 6144×4608×511 (PL)
            parser: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true, seizeUSB: false),
        .init(
            productID: 0x0035, name: "PL800",  // ⚠ name-only; kernel: 7220×5780×511 (PL)
            parser: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true, seizeUSB: false),
        .init(
            productID: 0x0037, name: "PL700",  // ⚠ name-only; kernel: 6758×5406×511 (PL)
            parser: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true, seizeUSB: false),
        .init(
            productID: 0x0038, name: "PL510",  // ⚠ name-only; kernel: 6282×4762×511 (PL)
            parser: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true, seizeUSB: false),
        .init(
            productID: 0x0039, name: "DTU-710",  // ⚠ name-only; kernel: 34080×27660×511 (PL)
            parser: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true, seizeUSB: false),
        .init(
            productID: 0x00C0, name: "DTF-720",  // ⚠ name-only; kernel: 6858×5506×511 (PL)
            parser: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true, seizeUSB: false),
        .init(
            productID: 0x00C2, name: "DTF-720a",  // ⚠ name-only; kernel: 6858×5506×511 (PL)
            parser: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true, seizeUSB: false),
        .init(
            productID: 0x00C4, name: "DTF-521",  // ⚠ name-only; kernel: 6282×4762×511 (PL)
            parser: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true, seizeUSB: false),
        .init(
            productID: 0x00C7, name: "DTU-1931",  // ⚠ name-only; kernel: 37832×30305×511 (PL)
            parser: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true, seizeUSB: false),

        // Name-only: companion touch interfaces of pen displays we already
        // list. Touch layouts unconfirmed; pen lives on the paired PID.
        .init(
            productID: 0x00F6, name: "Cintiq 24HD Touch sensor (pairs 0x00F8)",  // ⚠ name-only
            parser: .cintiqV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false),
        .init(
            productID: 0x005E, name: "Cintiq 22HD Touch sensor (pairs 0x005B)",  // ⚠ name-only
            parser: .cintiqV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false),
        .init(
            productID: 0x032C, name: "Cintiq 27QHD Touch sensor (pairs 0x032B)",  // ⚠ name-only
            parser: .cintiqV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false),
        .init(
            productID: 0x005D, name: "Cintiq 22 Touch sensor (pairs 0x0059)",  // ⚠ name-only
            parser: .cintiqV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false),
        .init(
            productID: 0x0335, name: "Cintiq 13HD Touch sensor (pairs 0x0333)",  // ⚠ name-only
            parser: .cintiqV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false),

        // Name-only: accessories and special modes.
        .init(
            // 18-button pad accessory for the Cintiq 27QHD line. No digitizer;
            // pad decode not yet supported.
            //
            // Groundwork for whoever implements it. The descriptor is opaque
            // (31 bytes, vendor page 0xFF0C, usage 0x00 throughout), so this
            // structure comes from correlating per-action recordings — press
            // one control, see which bit moves — published in the MIT-licensed
            // `whot/wacom-recordings`. Facts recorded here rather than fixtures
            // committed, per the rule that a third-party capture's licence does
            // not relicense Wacom's own report format.
            //
            // Input report 0x11, 32 bytes. Bytes [0..8] hold a report header,
            // a device serial and a battery percentage, all steady during use.
            // The controls live in four bytes:
            //
            //   [9]  bit 0        ring centre button
            //        bits 1,4,5   the keys arranged around the ring
            //        bits 6,7     express keys
            //        bits 2,3     never exercised in the recordings; presumed
            //                     the remaining two keys, see the count below
            //   [10] bits 0..7    eight express keys
            //   [11] bits 0,1     two express keys
            //        bit 6        set only while the ring is turning
            //        bit 7        set only on button events
            //   [12]             ring position, 70 distinct values observed
            //
            // Eight bits in [9], eight in [10] and two in [11] give exactly the
            // 18 controls `buttonCount` already claims from the kernel — two
            // independent sources agreeing, which is the main reason to trust
            // the two unexercised bits.
            //
            // What the recordings cannot settle, and hardware would: which bit
            // corresponds to which key *by position on the device*, and whether
            // the ring really spans 0...71 (70 values were seen, but an opaque
            // descriptor declares no maximum to check against). Both matter for
            // a binding UI more than for decode. Bytes [11] bits 6,7 are read
            // here as an event-source pair; that is inference from five
            // recordings, not a documented meaning.
            productID: 0x0331, name: "ExpressKey Remote (EKR-100)",  // ⚠ name-only
            parser: .intuosV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 18, hasTouchRing: true, hasEraser: false,
            seizeUSB: false),
        .init(
            // Firmware-update (DFU) mode. Never attach a driver to this.
            productID: 0x0094, name: "Wacom Bootloader (DFU mode)",  // ⚠ name-only
            parser: .intuosV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false),

        // ── Legacy Bluetooth devices (serial-port based, out-of-scope) ─────────
        // CTE-630BT (Graphire4 Bluetooth, PID 0x0081) and XD-0608-BT (Intuos2
        // Bluetooth, PID 0x0CA) use RFCOMM/SPP (serial port over Bluetooth)
        // instead of the HID Profile. They do NOT enumerate as IOHIDDevices;
        // instead they appear as /dev/cu.* serial ports. These require a
        // completely different driver architecture (serial I/O, not IOHIDManager).
        // Not implemented; documented for reference.
        // .init(productID: 0x0081, name: "CTE-630BT (Graphire4 BT) — SPP/RFCOMM", ...),
        // .init(productID: 0x0CA, name: "XD-0608-BT (Intuos2 BT) — SPP/RFCOMM", ...),
    ]

    // MARK: - Transport-variant unification

    /// Maps Bluetooth Classic and wireless dongle PIDs to the canonical (USB) PID for their model family.
    ///
    /// Wacom assigns distinct product IDs per transport (USB, Bluetooth, wireless dongle).
    /// This map normalizes them so that all three transports of the same physical tablet
    /// share one `DeviceContext` and one settings namespace.
    ///
    /// The USB PID is canonical because it's the reference for HID feature reports and
    /// is always enumerable first. Example: PTH-660 family maps to 0x0357 (USB).
    public static let canonicalPIDMap: [Int: Int] = [
        // Intuos Pro S (PTH-460 family) — PIDs per kernel BT_DEVICE_WACOM(0x393)
        // and libwacom DeviceMatch (usb 0392 / bt 0393; usb 03dc / bt 03dd).
        // The old 0x035B/0x035F entries were "+9 pattern" guesses pointing at
        // PIDs that belong to the Cintiq Pro 32 family; removed 2026-06-09.
        0x0393: 0x0392,  // BT Classic
        0x03DD: 0x03DC,  // BT Classic (hardware-revision variant)
        0x03F6: 0x03F5,  // Intuos Pro S gen 3 Bluetooth (libwacom DeviceMatch)
        0x03F8: 0x03F7,  // Intuos Pro M gen 3 Bluetooth (libwacom DeviceMatch)
        0x03FA: 0x03F9,  // Intuos Pro L gen 3 Bluetooth (libwacom DeviceMatch)
        0x0401: 0x03F9,  // Intuos Pro L gen 3 USB hardware-revision variant (libwacom DeviceMatch)

        // Intuos Pro M (PTH-660 family)
        0x0360: 0x0357,  // BT Classic

        // Intuos Pro L (PTH-860 family)
        0x0361: 0x0358,  // BT Classic

        // NOTE: 0x0359/0x035A previously appeared here as unsourced
        // "Wireless dongle" mappings for PTH-660/860 — no kernel macro or
        // libwacom DeviceMatch backed them, unlike every other row in this
        // map, and the only wireless-dongle transport this project has ever
        // verified is the older ACK-40401 RF dongle (PID 0x0084, Intuos5
        // PTH-850), a different mechanism entirely; PTH-660/860 wireless is
        // Bluetooth Classic (0x0360/0x0361 above), not a dongle. Removed
        // 2026-07-17 — same "+9 pattern"-guess shape as the 0x035B/0x035F
        // entries already found wrong and removed 2026-06-09. libwacom
        // independently and specifically assigns 0x0359/0x035A to DTU-1141B
        // and DTH-1152 (see their registry entries above), which is now
        // treated as authoritative for those two PIDs.

        // Intuos4 WL (PTK-540WL): kernel BT_DEVICE_WACOM(0xBD) is the
        // Bluetooth PID of the USB 0x00BC entry. Decode over BT untested.
        0x00BD: 0x00BC,

        // Intuos BT S/M (CTL-4100WL/6100WL): kernel 0x3C6/0x3C8 are the
        // INTUOSHT3_BT Bluetooth PIDs of the USB entries.
        0x03C6: 0x0376,
        0x03C8: 0x0378,
    ]

    // MARK: Lookups

    /// PID-keyed index over `knownDevices`. `Dictionary(grouping:)` preserves
    /// declaration order within each group, so "first match" semantics are
    /// identical to the previous linear scans.
    private static let specsByPID: [Int: [WacomDeviceSpec]] =
        Dictionary(grouping: knownDevices, by: \.productID)

    /// Returns the spec for `productID`, or nil if unrecognised.
    public static func spec(for productID: Int) -> WacomDeviceSpec? {
        specsByPID[productID]?.first
    }

    /// Returns the best-matching spec for `productID`, optionally using the
    /// device's `kIOHIDProductKey` string to disambiguate when more than one
    /// entry shares the PID.
    ///
    /// Selection order among entries with matching `productID`:
    ///   1. An entry whose `productStringMatch` is a case-insensitive
    ///      substring of `productString` (when `productString != nil`).
    ///   2. An entry with `productStringMatch == nil` (the catch-all).
    ///   3. The first entry, as a last resort.
    ///
    /// Wacom has no PID collisions today, so this returns the same result as
    /// `spec(for:)` for every current device.  The overload exists so the
    /// app-side lookup path is already vendor-neutral when Huion / Xencelabs
    /// support arrives.
    public static func spec(forProductID productID: Int, productString: String?) -> WacomDeviceSpec? {
        let matches = specsByPID[productID] ?? []
        guard !matches.isEmpty else { return nil }
        if let needle = productString?.lowercased() {
            if let hit = matches.first(where: {
                guard let m = $0.productStringMatch?.lowercased(), !m.isEmpty else { return false }
                return needle.contains(m)
            }) {
                return hit
            }
        }
        return matches.first(where: { $0.productStringMatch == nil }) ?? matches.first
    }

    /// Human-readable display name for any Wacom product.
    /// Returns "Wacom 0xXXXX" for PIDs not yet in the table.
    public static func deviceName(forProductID productID: Int) -> String {
        spec(for: productID)?.name
            ?? "Wacom 0x\(String(productID, radix: 16, uppercase: true))"
    }

    /// True when a real decoder exists for this device.
    /// All five parser families have decoders as of Phase 4 (2026-05-07).
    /// `.graphire` is wired up but routes carry `confidence: .experimental` —
    /// the decoder is kernel-canonical but not yet hardware-validated.
    public static func hasLiveDecoder(for productID: Int) -> Bool {
        spec(for: productID) != nil
    }

    /// Returns the canonical (USB) product ID for any transport variant of a tablet.
    ///
    /// If `productID` is a Bluetooth or wireless dongle variant, returns the equivalent USB PID.
    /// If `productID` is already canonical (USB) or unmapped, returns it unchanged.
    ///
    /// Used at device connection to unify multi-transport tablets: USB PTH-660 (0x0357) and
    /// BT PTH-660 (0x0360) both normalize to 0x0357, so they share the same `DeviceContext`
    /// and settings namespace.
    public static func canonicalProductID(for productID: Int) -> Int {
        canonicalPIDMap[productID] ?? productID
    }
}
