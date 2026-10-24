// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
//
// Entries are mixed-provenance: some hand-authored and hardware-verified,
// some imported from OpenTabletDriver's configs (`tools/import_otd_configs.py`),
// and some backfilled from libwacom (`tools/backfill_libwacom_dimensions.py`).
// The tools keep each entry traceable to its source.
//
// Scope: ISDv4/ISDv5 tablet-PC digitizers are left out on purpose; claiming
// one would seize a device the user never plugged in, so their
// `missing_from_registry` verdicts in `registry_audit.csv` are expected.
// 0x009A has maxX 0, so it only names the device.

import Foundation

// MARK: - Report protocol family

/// Which HID report decoder handles this device family.
///
/// Used by `WacomDeviceRegistry` to route devices to the correct decoder.
public enum ReportFormat: String, Sendable {
    /// Graphire / early consumer line — Report ID 0x02
    /// (kernel `WACOM_REPORT_PENABLED`), 8 bytes.
    /// Covers PenPartner, Graphire 2–4, Volito, Bamboo One (CTF-430).
    /// No tool-change packets; eraser/pen/mouse detected via the tool field
    /// in status byte d[1] bits 5–6. Decoded by `GraphireDecoder`.
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

    /// IntuosV3 — pen on Report ID 0x1E (24-bit XY) over USB and 0x1A over
    /// Bluetooth LE, with 0x11 aux carrying 8 keys, 2 cluster-center keys,
    /// and two dials. Covers the PTK-470/670/870 Intuos Pro and the Movink
    /// 13 (OTD's `IntuosV3ReportParser`). See `IntuosV3Decoder`.
    case intuosV3

    /// DTUS — small entry-level Cintiq / DTU pen displays. Pen report at
    /// ID 0x11 (7 bytes, BE16 coordinates, 10-bit pressure split across
    /// status byte and pressure byte); pad report at ID 0x15 (4 buttons in
    /// the low nibble of one byte). No tilt, no rotation, no hover. Covers
    /// DTK-1651 (0x0343), DTU-1031 (0x00FB), DTU-1031X (0x032F), DTU-1141
    /// (0x0336). Not yet validated on hardware.
    case dtus

    /// DTU — Wacom DTU pen-display family using the WACOM_REPORT_PENABLED
    /// (0x02) report format parsed by `wacom_dtu_irq`. Single pen report,
    /// 8 bytes: LE16 X/Y, 9-bit pressure, eraser inferred from tool-type
    /// bits. No pad buttons, no tilt. Covers DTU-1631 (0x00F0) and
    /// DTU-2231 (0x00CE). Not yet validated on hardware.
    case dtu

    /// Bamboo — pen on Report ID 0x02, LE16 coordinates, with touch and pad
    /// in the BPT3 container. Covers Bamboo Pen & Touch, Craft, Comic, and
    /// Fun (CTL/CTH-xxx), and the INTUOSHT models. See `BambooDecoder`.
    case bamboo

    /// Intuos3 (PTZ-xxx, 2003–2006) — the 10-byte IntuosV1 payload, but
    /// frames with bit 6 clear still carry data. Aux reports use IDs
    /// 0x03/0x0C, not 0x11. Two-stage feature init (see
    /// `TabletSpec.initSteps`). See `Intuos3Decoder`.
    case intuos3

    /// CintiqV1 — Wacom Cintiq pen-display family using the IntuosV1 10-byte pen
    /// report layout (same as PTH-851) plus a 0x0C aux report for touch rings and
    /// express keys, and a 0x01 tip-switch report.
    /// Decoded by `CintiqV1Decoder` which handles the WACOM_24HD typeNibble dispatch,
    /// ABS_Z Art Pen rotation, barrel-button debounce, dual-ring 0x0C layout,
    /// tip-switch synthetic pressure, and incompatible-tool suppression.
    case cintiqV1

    /// Xencelabs Pen Tablet (VID 0x28BD) — 10-byte pen report dispatched on
    /// byte-1 flags, XP-Pen-shaped aux report.  The only non-Wacom parser;
    /// specs come from `VendorDeviceRegistry`, not this registry. Requires
    /// the `[0x02, 0xB0, 0x04]` output-report init. Decoded by
    /// `XencelabsDecoder`.
    case xencelabs

    /// Huion, Gaomon, XP-Pen, UGEE, and Parblo tablets, whose ranges come from
    /// the tablet when it's switched on (see `UCLogicTabletInfo`). Decoded by
    /// `UCLogicDecoder`.
    case ucLogic

    /// ExpressKey Remote (EKR-100, PID 0x0331) — standalone wireless
    /// button/ring accessory, no digitizer. Report ID 0x11, 32 bytes, opaque
    /// vendor collection (usage page 0xFF0C, no field-level HID descriptor).
    /// Decoded by `ExpressKeyRemoteDecoder`, from the kernel's
    /// `wacom_remote_irq`.
    case expressKeyRemote

    /// PL — Wacom's "PL" report family (`WACOM_REPORT_PENABLED`, Report ID
    /// 0x02, 8 bytes). Covers the PL-400 through PL-800 LCD pen displays
    /// (1998–2005), the direct ancestors of the Cintiq line — PL-550/PL-800
    /// are literally the Cintiq 15X/18SX under their internal model
    /// numbers. Ported from the kernel's `wacom_pl_irq()`; decoded by
    /// `WacomPLDecoder`. OpenTabletDriver has tested the PL-800 on hardware;
    /// the other seven PIDs are untested.
    case pl

    /// A tablet the registry doesn't know, read from its own report
    /// descriptor by `DescriptorPenDecoder`: any standard HID pen
    /// digitizer. Pen only; no buttons, rings, or touch.
    case descriptor
}

extension ReportFormat {
    func decoder() -> any TabletReportDecoder {
        switch self {
        case .graphire: return GraphireDecoder()
        case .intuosV1: return IntuosV1Decoder()
        case .intuosV2: return IntuosV2Decoder()
        case .intuosV3: return IntuosV3Decoder()
        case .dtus: return DTUSDecoder()
        case .dtu: return DTUDecoder()
        case .bamboo: return BambooDecoder()
        case .intuos3: return Intuos3Decoder()
        case .cintiqV1: return CintiqV1Decoder()
        case .xencelabs: return XencelabsDecoder()
        case .ucLogic: return UCLogicDecoder()
        case .expressKeyRemote: return ExpressKeyRemoteDecoder()
        case .pl: return WacomPLDecoder()
        case .descriptor: return DescriptorPenDecoder()
        }
    }
}

// MARK: - Init step

/// A single step in the device-activation sequence executed when an interface
/// is opened.  Steps run in order; a `.delay` suspends execution and schedules
/// the remainder on the main queue after the specified interval.
///
/// - `.featureReport(_:)`: HID SetReport (feature); first byte is the report ID.
/// - `.outputReport(_:)`: HID output report; first byte is the report ID.
/// - `.delay(_:)`: Pause before the next step, dispatched via `asyncAfter`.
/// - `.stringDescriptor(_:)`: Probe a USB string descriptor at the given index.
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
/// - `.verified`: Confirmed working on real hardware, either ours or a
///   user's submitted diagnostics.
/// - `.crossReferenced`: Dimensions/parser agree between two independent
///   sources (Linux input-wacom, OpenTabletDriver, or Wacom model
///   data); not personally hardware-tested.
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
/// parser and name by ``TabletSpec/family``. Used to check tool
/// compatibility against ``ToolSpec/supportedFamilies``.
///
/// The set is closed and small: each case is one decoder generation the
/// project has actually characterised. Adding a case is a source break by
/// design — a new family that a `switch` fails to handle should not compile,
/// rather than fall through silently. Raw values are stable strings, kept
/// for logs and for the `Codable` round-trip on ``ToolSpec``.
public enum DeviceFamily: String, Codable, Sendable, CaseIterable {
    case graphire

    /// Intuos 1 (GD-series) and Intuos 2 (XD-series). One case for both: same
    /// digitizer generation, same 10-byte report, same 1023-level pressure
    /// channel, and nothing observed distinguishes them for tool
    /// compatibility. Split them if a tool ever works on one and not the
    /// other.
    case intuos1And2

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

    /// Huion, Gaomon, XP-Pen, UGEE, and Parblo tablets. Their shared pen,
    /// `0xE902`, works with any family, so no catalog entry names this one.
    case ucLogic

    /// ExpressKey Remote (EKR-100) — standalone button/ring accessory, no
    /// digitizer and no pen. `ToolCatalog` has and needs no entries for
    /// this case; a device with no pen input never reaches tool-compatibility
    /// checking in the first place, so the `supportedFamilies.isEmpty`
    /// fallback documented on `.pl` below is moot here rather than active.
    case expressKeyRemote

    /// PL-series (PL-400–PL-800, 1998–2005 LCD pen displays). Its own case,
    /// not `.graphire`: PL was the professional line, and nothing confirms
    /// shared tools. No `ToolCatalog` entry names it yet, so the
    /// `supportedFamilies.isEmpty` fallback calls every tool compatible.
    /// That means "no data", not "unrestricted"; add entries once someone
    /// verifies which pens it accepts.
    case pl

    /// A tablet read from its own report descriptor. Its pens don't
    /// identify themselves, so any tool counts as compatible.
    case descriptor
}

// MARK: - Per-device spec

/// All hardware parameters for a single Wacom USB or BLE product.
///
/// This table is the single source of truth for device names, coordinate
/// ranges, pressure depth, and initialization requirements, and it picks
/// each device's decoder.
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
///
/// **Known divergences from OpenTabletDriver.** The 27 rows
/// `verify_registry.py` marks `otd_disagrees` all agree with the kernel;
/// don't "fix" them toward OTD on the audit verdict alone.
///
///   * **Pressure, 18 rows:** OTD has exactly 2× ours (2046 vs 1023) on
///     Intuos 1/2/3, Graphire, and Cintiq 21UX. These are 10-bit devices; the
///     shared extraction formula spans 11 bits, which is why the decoders
///     shift right when `spec.maxPressure <= 1023`. Raising the value without
///     removing that shift would halve pressure; see `KERNEL_HALF_SCALE_PIDS`
///     in `tools/verify_registry.py`.
///
///   * **Dimensions, 9 rows:** OTD's maxima work out to exactly 100.0
///     units/mm (CTE-460, CTE-660, CTL-671), back-computed from rounded
///     millimetres. Ours match the kernel.
/// Entries marked ⚠ are estimated from driver sources and unverified on
/// hardware; the `⚠ recognition-only` variant additionally means the parser
/// family and `maxX`/`maxY` are guesses by similarity — the device will be
/// named correctly but pen decode may produce nonsense until verified.
public struct TabletSpec: Sendable {
    /// USB product ID; Bluetooth and dongle variants have their own entries.
    public let productID: Int
    /// Display name, usually with the model number.
    public let name: String
    /// Which report format the device sends, and so which decoder reads it.
    public let format: ReportFormat
    /// Largest pen X coordinate, in device units.
    public let maxX: Int
    /// Largest pen Y coordinate, in device units.
    public let maxY: Int
    /// Largest pressure value; 0 for entries with no pen.
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
    /// The PTK-470/670/870 are the Wacom case: the descriptor calls the
    /// control "Wacom TouchRing", but it only reports rotation, with no
    /// finger-down signal; libwacom calls it `Dial`. Every other
    /// `hasTouchRing: true` row is capacitive.
    public let hasMechanicalDial: Bool
    /// True if this model has per-key OLED image displays on its express
    /// keys (Intuos4 only). Gates the OLED image protocol
    /// (`WacomOutputProtocol`); the kernel wires image support only to the
    /// Intuos4 types, though Intuos5 shares `.intuosV1`.
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
    /// **This means "touch can be decoded", not "the device has a touch
    /// surface."** It puts a Touch tab in front of the user, so set it only
    /// where a decoder reaches `.touch([TouchContact])`:
    ///
    /// - `.intuosV2`: report 0x21 (`decodeTouchReport`).
    /// - `.intuosV1`: the BPT3 container.
    /// - `.bamboo`: the 20-byte `decodeBPTTouch` (CTH-460/461) and the BPT3
    ///   container (INTUOSHT).
    /// - Pen displays whose touch arrives on a separate interface: the
    ///   fixed-layout `Wacom24HDTDecoder` (see
    ///   `DeviceDecoder.fixedLayoutTouch`) or the sensor's own descriptor
    ///   (`PrecisionTouchDecoder`).
    public let hasFingerTouch: Bool
    /// Maximum simultaneous touch contacts the device reports.  Zero when
    /// `hasFingerTouch == false`.
    ///
    /// Bounded by what the decoder can emit, not by the panel's advertised
    /// finger count: `.intuosV2`'s report 0x21 carries five fixed slots and
    /// caps at `min(count, 5)`, so five is the ceiling there no matter what a
    /// spec sheet claims.  `.intuosV1` via the BPT3 container reads up to 16.
    public let maxTouchContacts: Int
    /// Coordinate maximum for the capacitive touch sensor's X axis.
    /// Separate from `maxX` (pen digitizer). PTH-860: 12439 (capture).
    /// PTH-660: 8960 (descriptor). Zero when `hasFingerTouch == false`.
    public let touchMaxX: Int
    /// Coordinate maximum for the capacitive touch sensor's Y axis.
    /// PTH-860: 8639. PTH-660: 5920.
    /// Zero when `hasFingerTouch == false`.
    public let touchMaxY: Int
    /// Number of ring mode slots to expose in the UI.
    /// Defaults to 4, matching Wacom's standard 4-LED toggle ring layout.
    public let ringSlotCount: Int
    /// True if the pen family includes an eraser tool type.
    public let hasEraser: Bool
    /// True if the tablet senses pen tilt. Pass it to `init` to override; by
    /// default it's false for formats with no tilt field (Graphire, Bamboo,
    /// PL, DTU, DTUS), for consumer and business models that lack tilt, and
    /// for entries with no pen, and true otherwise. Decoders don't read it;
    /// it describes the hardware.
    public let hasTilt: Bool
    /// Full-scale tilt angle in degrees for this family's wire tilt value, sourced
    /// from a HID descriptor, a kernel-cited constant, or a stop-to-stop hardware
    /// capture paired with a vendor-tool reading — never estimated, and never a
    /// spec-sheet figure. `nil` means unknown: decoders must not substitute a
    /// guessed constant, and should keep the fraction unverified rather than
    /// silently claim an angle.
    ///
    /// This is the *physical* range, which is not necessarily the raw divisor.
    /// The two coincide on the devices measured so far but are independent:
    /// a device could saturate at raw 60 while spanning 90°. Read this only as
    /// an angle; a decoder needing a divisor should hold its own constant.
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
    /// the session routes it to this tablet's transport as an LED target
    /// rather than reading it as an unknown tablet or skipping it entirely.
    /// nil = LED control uses the main digitizer interface (single-interface devices).
    public let ledCompanionPID: Int?
    /// Product ID of a companion USB interface carrying this tablet's finger
    /// touch, when the sensor enumerates under its own PID rather than as a
    /// second interface of this one (Cintiq 27QHD Touch: pen 0x032B, sensor
    /// 0x032C). The session joins the sensor to this tablet, whose spec
    /// carries `hasFingerTouch`; on its own, the sensor's name-only row
    /// would decode nothing.
    /// nil = touch arrives on this PID's own interfaces, or not at all.
    public let touchCompanionPID: Int?
    /// Init sequence for the `touchCompanionPID` sensor, which `initSteps`
    /// can't reach, being a separate USB product.
    ///
    /// A standard HID digitizer starts in single-contact mode until its
    /// Device Mode feature is set, so empty here can mean "basic touch, no
    /// gestures" on hardware that supports more.
    public let touchCompanionInitSteps: [InitStep]
    /// How well-vetted this entry is (see `ConfidenceTier`).
    /// Defaults to `.experimental` — promote explicitly when verified.
    public let confidence: ConfidenceTier
    /// Active-area width in millimetres, or nil if unknown. Lets the mapping
    /// layer compute LPI per axis (`maxX / activeWidthMM × 25.4`) and offer
    /// 1:1 mapping.
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
    /// Each row's comment names its source (`✓ confirmed live`,
    /// `cross-referenced: libwacom`, `⚠ from OTD`, and so on). 0x0351
    /// (Cintiq Pro 24 touch) shows (1) and (3) diverging by ~4%.
    public let activeWidthMM: Double?
    /// Active-area height in millimetres.  See `activeWidthMM`.
    public let activeHeightMM: Double?
    /// Optional substring matched against the device's `kIOHIDProductKey`
    /// string when multiple specs share a `productID`.  Used to disambiguate
    /// vendor PID collisions; Wacom has none. Case-insensitive substring
    /// match. Nil = match any.
    public let productStringMatch: String?
    /// How this tablet departs from the plain open-and-read path. Family
    /// defaults unless the entry overrides them.
    public internal(set) var quirks: TabletQuirks

    /// Creates an entry. Capabilities default to absent; `hasTilt` defaults
    /// from the parser and model when omitted.
    public init(
        productID: Int, name: String, format: ReportFormat,
        maxX: Int, maxY: Int, maxPressure: Int,
        buttonCount: Int, bezelButtonCount: Int = 0, hasTouchRing: Bool, hasDualRings: Bool = false,
        hasMechanicalDial: Bool = false,
        hasKeyOLEDs: Bool = false,
        hasTouchStrips: Bool = false, ringSlotCount: Int = 4, hasEraser: Bool, hasTilt: Bool? = nil,
        tiltMaxDegrees: Double? = nil,
        hasFingerTouch: Bool = false, maxTouchContacts: Int = 0,
        touchMaxX: Int = 0, touchMaxY: Int = 0,
        isPenDisplay: Bool = false,
        seizeUSB: Bool,
        initSteps: [InitStep] = [],
        ledCompanionPID: Int? = nil,
        touchCompanionPID: Int? = nil,
        touchCompanionInitSteps: [InitStep] = [],
        confidence: ConfidenceTier = .experimental,
        productStringMatch: String? = nil,
        activeWidthMM: Double? = nil,
        activeHeightMM: Double? = nil
    ) {
        self.productID = productID
        self.name = name
        self.format = format
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
        self.hasTilt = hasTilt ?? Self.defaultHasTilt(format: format, productID: productID)
        self.tiltMaxDegrees = tiltMaxDegrees
        self.isPenDisplay = isPenDisplay
        self.seizeUSB = seizeUSB
        self.initSteps = initSteps
        self.ledCompanionPID = ledCompanionPID
        self.touchCompanionPID = touchCompanionPID
        self.touchCompanionInitSteps = touchCompanionInitSteps
        self.confidence = confidence
        self.productStringMatch = productStringMatch
        self.activeWidthMM = activeWidthMM
        self.activeHeightMM = activeHeightMM
        self.quirks = TabletQuirks.defaults(for: format)
    }

    /// A spec for a tablet the registry doesn't know, from the pen reports
    /// its descriptor declares, or nil when it declares none. Ranges come
    /// from the native-resolution pen report.
    package static func described(by descriptor: [UInt8], productID: Int, name: String) -> TabletSpec? {
        guard !descriptor.isEmpty, let parsed = try? HIDReportDescriptorParser.parse(descriptor),
            let pen = GenericPenLayout.native(in: GenericPenLayout.derive(from: parsed))
        else { return nil }
        return TabletSpec(
            productID: productID, name: name, format: .descriptor,
            maxX: pen.logicalMaxX, maxY: pen.logicalMaxY, maxPressure: Swift.max(pen.logicalMaxPressure, 1),
            buttonCount: 0, hasTouchRing: false,
            hasEraser: pen.invert != nil || pen.eraserSwitch != nil,
            hasTilt: pen.tiltX != nil || pen.tiltY != nil,
            seizeUSB: false)
    }

    /// A spec that decodes nothing, for an interface that's only watched
    /// so a capture can record it.
    package static func observing(productID: Int, name: String) -> TabletSpec {
        TabletSpec(
            productID: productID, name: name, format: .descriptor,
            maxX: 1, maxY: 1, maxPressure: 1, buttonCount: 0, hasTouchRing: false, hasEraser: false,
            hasTilt: false, seizeUSB: false
        ).withQuirks { $0.readsDescriptorPens = false }
    }

    /// A best guess for a Wacom tablet the registry doesn't know.
    ///
    /// Report size picks the family: over 64 bytes reads as IntuosV2, the
    /// rest as IntuosV1. Pen reports the descriptor declares are read from
    /// it first, since a modern pen report is small enough to pass for
    /// IntuosV1. Ranges come from the descriptor where it has them. Init is
    /// the mode switch the descriptor declares, or report 0x02.
    package static func guessed(
        forUnknownWacom productID: Int, name: String, maxInputReportSize: Int, descriptor: [UInt8]
    ) -> TabletSpec {
        let format: ReportFormat = maxInputReportSize > 64 ? .intuosV2 : .intuosV1
        let parsed = descriptor.isEmpty ? nil : try? HIDReportDescriptorParser.parse(descriptor)
        // A relative mouse's X/Y tops out at 127, which is no tablet's range.
        let fields = parsed?.reports.filter { $0.direction == .input }.flatMap(\.fields).filter { !$0.isRelative } ?? []
        func largest(page: UInt32, usage: UInt32) -> Int {
            fields.filter { $0.usagePage == page && $0.usage == usage }.map(\.logicalMax).max() ?? 0
        }
        var maxX = largest(page: 0x01, usage: 0x30)
        var maxY = largest(page: 0x01, usage: 0x31)
        var maxPressure = largest(page: 0x0D, usage: 0x30)
        if let pen = parsed.flatMap({ GenericPenLayout.native(in: GenericPenLayout.derive(from: $0)) }) {
            maxX = pen.logicalMaxX
            maxY = pen.logicalMaxY
            if pen.logicalMaxPressure > 0 { maxPressure = pen.logicalMaxPressure }
        }
        // An Intuos5 or a second-generation Intuos Pro, as the closest
        // common shape.
        if maxX <= 0 || maxY <= 0 {
            (maxX, maxY) = format == .intuosV2 ? (44800, 29600) : (44704, 27940)
        }
        if maxPressure <= 0 { maxPressure = format == .intuosV2 ? 8191 : 1023 }
        let modeSwitch = parsed?.modeSwitchFeatureReportID() ?? 0x02
        return TabletSpec(
            productID: productID, name: name, format: format,
            maxX: maxX, maxY: maxY, maxPressure: maxPressure,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            initSteps: [.featureReport([modeSwitch, 0x02])]
        ).withQuirks { $0.readsDescriptorPens = true }
    }

    /// Products without tilt in formats that otherwise carry it: consumer
    /// Intuos (CTL/CTH-x90, CTL-x100), CTE-460, CTL-470, DTU-class business
    /// displays, and entries with no pen (touch sensors, receivers,
    /// bootloader). From DrawTabData's per-model tilt where it has one.
    static let noTiltProductIDs: Set<Int> = [
        0x005D, 0x005E, 0x006A, 0x0084, 0x0094, 0x009A, 0x009D, 0x00DD,
        0x00F6, 0x00F9, 0x0326, 0x032C, 0x0335, 0x033B, 0x033C, 0x033D,
        0x033E, 0x0354, 0x0359, 0x035A, 0x0374, 0x0375, 0x0376, 0x0377,
        0x0378, 0x0379, 0x037D, 0x03B3, 0x03C5, 0x03C6, 0x03C7, 0x03C8,
    ]

    static func defaultHasTilt(format: ReportFormat, productID: Int) -> Bool {
        switch format {
        case .graphire, .bamboo, .pl, .dtu, .dtus, .expressKeyRemote: return false
        default: return !noTiltProductIDs.contains(productID)
        }
    }

    /// Lines per inch derived from `maxX`/`maxY` and `activeWidthMM`/`activeHeightMM`.
    /// Returns nil unless both physical dimensions are populated.  Useful for
    /// the info pane and for cross-vendor cursor-mapping that needs a real DPI
    /// number rather than device-unit ratios.
    public var lpi: (x: Double, y: Double)? {
        guard let w = activeWidthMM, w > 0, let h = activeHeightMM, h > 0 else { return nil }
        return (Double(maxX) / w * 25.4, Double(maxY) / h * 25.4)
    }

    /// Factory value for the per-tool pressure dead zone (`ToolSettings`'
    /// `pressureThreshold`), as a fraction of `maxPressure`. Zero wherever
    /// the shared noise floor (`InputInjector.tipPressureThreshold`, 0.004)
    /// already covers the device's hover baseline — everything but Intuos 1/2.
    ///
    /// A GD-0608-U capture puts that family's hover noise at up to
    /// 10/1023 ≈ 0.0098, ~2.4× the shared floor: the hairline-on-hover in
    /// Cyzor/tablet-driver#4. 0.015 clears it and stays below a deliberate
    /// touch.
    ///
    /// Computed rather than stored, since only nine rows differ from 0.
    /// Store it when a second family needs its own value.
    public var defaultPressureThreshold: Double {
        // Intuos 1 (GD-series, 0x20-0x24) and Intuos 2 (XD-series, 0x41-0x45).
        // Same digitizer generation and the same 1023-level pressure channel;
        // only the 6×8 (0x0021) is measured, and the value is applied
        // family-wide on the strength of that shared channel. A capture from
        // any other row that shows a quieter baseline should narrow this.
        switch productID {
        case 0x0020...0x0024, 0x0041...0x0045: return 0.015
        default: return 0.0
        }
    }

    /// Derives the device family from parser and name.
    /// Used to check tool compatibility against `ToolSpec.supportedFamilies`.
    ///
    /// `.intuosV1` covers five families: Intuos 1/2, 4, and 5 by PID, and
    /// the Cintiq split by `name`.
    ///
    /// Reaches tool-compatibility checks only: it picks no decoder and
    /// changes no decoded value. Its output is the `.toolCompatibility`
    /// message.
    public var family: DeviceFamily {
        switch format {
        case .graphire:
            // Graphire / PenPartner / early consumer line, matching the four
            // `["graphire"]` tool specs in ToolCatalog. GraphireDecoder sends
            // synthetic tool codes and never runs the compatibility check.
            // Three Bamboo-branded CTE/MTE devices also land here, which
            // "graphire" doesn't describe; unresolved.
            return .graphire
        case .intuos3:
            return .intuos3
        case .cintiqV1:
            return .cintiq
        case .intuosV1:
            // Intuos 1-5 and any non-Cintiq pen displays that haven't been migrated.
            //
            // Intuos 1/2 match by PID first: their names have no token the
            // checks below look for. The same two ranges as
            // `defaultPressureThreshold`.
            if (0x0020...0x0024).contains(productID) || (0x0041...0x0045).contains(productID) {
                return .intuos1And2
            }
            if name.contains("Cintiq") || name.contains("DTK") || name.contains("DTH") {
                return .cintiq
            }
            // Intuos4/5 by product ID: their names don't separate the
            // generations reliably.
            if (0x00B8...0x00BD).contains(productID) {
                return .intuos4
            }
            if (0x0026...0x002A).contains(productID) {
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
        case .ucLogic:
            return .ucLogic
        case .expressKeyRemote:
            return .expressKeyRemote
        case .pl:
            return .pl
        case .descriptor:
            return .descriptor
        }
    }
}

// MARK: - Registry

/// Every Wacom device TabletKit recognizes, keyed by USB product ID.
///
/// Look a device up with `spec(for:)`, then call its
/// ``TabletSpec/makeDecoder()``.
public enum WacomDeviceRegistry: Sendable {

    /// Every USB vendor ID whose PIDs this registry is keyed on.
    ///
    /// Wacom ships under two VIDs: 0x056A for the main line, and 0x0531
    /// (Wacom Technology Corp.) for the consumer Wacom One CTC line. Test
    /// membership here rather than comparing against 0x056A; a second
    /// literal once left the 0x0531 rows without their `initSteps`.
    public static let vendorIDs: Set<Int> = [0x056A, 0x0531]

    // MARK: Known devices

    /// Intuos4 over USB. A cold tablet can ignore the mode switch without an
    /// error, so it's read back and resent. A tablet that falls back to
    /// mouse mode (report 0x01) gets init again.
    private static func intuos4USB(_ q: inout TabletQuirks) {
        q.usbModeReadBack = TabletQuirks.ModeReadBack(report: [0x02, 0x02], resendAfter: [0.15, 0.4])
        q.usbIdleReport = TabletQuirks.IdleReportRule(reportID: 0x01, liveReportIDs: [0x02, 0x0C], timeout: 1)
    }

    /// All entries, in family order. Prefer `spec(for:)` for lookups.
    public static let knownDevices: [TabletSpec] = [

        // ── PenPartner / Graphire 1–4 ─────────────────────────────────────────
        // graphire parser: 8-byte Report ID 0x02 once the [0x02, 0x02] init takes
        // the tablet out of mouse mode; ≤511 pressure levels.
        .init(
            // The kernel names this PID the Cintiq Partner (PTU-600), not
            // PenPartner (0x0000). No decoder handles the PTU family, so it's
            // name-only (kernel dims: 20480×15360×511).
            productID: 0x0003, name: "Cintiq Partner (PTU-600)",  // ⚠ name-only
            format: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true, seizeUSB: false),
        .init(
            // PENPARTNER report family (5-byte wacom_penpartner_irq) has no
            // decoder here; name-only (kernel dims: 5040×3780×255).
            productID: 0x0000, name: "PenPartner",  // ⚠ name-only
            format: .graphire, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false),
        // Original Graphire (0x0004/0x0010) and Graphire 2/3/4 4×5 rows below
        // share one active area: 127.6×92.8mm per Wacom's Graphire and
        // Graphire4 manuals. maxX/maxY (10206/10208, 7422/7424) match OTD's
        // measured ET-0405-U.json, double what the manuals' printed 40 lpmm
        // implies: the wire units aren't the manual's resolution.
        .init(
            productID: 0x0004, name: "Graphire",
            format: .graphire, maxX: 10206, maxY: 7422, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 127, activeHeightMM: 93),
        .init(
            productID: 0x0010, name: "Graphire",  // cross-referenced: linuxwacom + OTD
            format: .graphire, maxX: 10206, maxY: 7422, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-graphire-usb.tablet (Width=127, Height=102)
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced,
            activeWidthMM: 127, activeHeightMM: 93),
        .init(
            productID: 0x0011, name: "Graphire 2 (4×5)",  // ⚠ estimated; kernel 0x11 = Graphire2 4×5
            format: .graphire, maxX: 10206, maxY: 7422, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-graphire2-4x5.tablet (Width=127, Height=102)
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 127, activeHeightMM: 93),
        .init(
            productID: 0x0012, name: "Graphire 2 (5×7)",  // ⚠ estimated; kernel 0x12 = Graphire2 5×7
            format: .graphire, maxX: 13918, maxY: 10206, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 178, activeHeightMM: 127),
        .init(
            productID: 0x0013, name: "Graphire 3 (4×5)",  // ⚠ estimated
            format: .graphire, maxX: 10208, maxY: 7424, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-graphire3-4x5.tablet (Width=127, Height=102)
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 127, activeHeightMM: 93),
        .init(
            // Active area 208.8×150.8mm per the Graphire4 manual's CTE-640,
            // whose maxX/maxY this row shares.
            productID: 0x0014, name: "Graphire 3 (6×8)",  // ⚠ estimated
            format: .graphire, maxX: 16704, maxY: 12064, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 209, activeHeightMM: 151),
        .init(
            productID: 0x0015, name: "Graphire 4 (4×5)",  // ⚠ estimated
            format: .graphire, maxX: 10208, maxY: 7424, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-graphire4-4x5.tablet (Width=127, Height=102)
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 127, activeHeightMM: 93),
        .init(
            // Active area 208.8×150.8mm per the Graphire4 manual's CTE-640.
            productID: 0x0016, name: "Graphire 4 (6×8)",  // ⚠ estimated
            format: .graphire, maxX: 16704, maxY: 12064, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 209, activeHeightMM: 151),
        .init(
            // Kernel WACOM_MO "BambooFun 4x5"; libwacom CTE-450 (NumRings=1).
            // The MTE-450 is 0x0065. Active area 147.6×92.3mm per the Bamboo
            // Fun manual, matching maxX/maxY at 100 lpmm.
            productID: 0x0017, name: "Bamboo Fun small (CTE-450)",  // ⚠ from kernel/libwacom/OTD
            format: .graphire, maxX: 14760, maxY: 9225, maxPressure: 511,
            buttonCount: 4, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 148, activeHeightMM: 92),

        // ── Volito / PenStation ───────────────────────────────────────────────
        .init(
            productID: 0x0060, name: "Volito",  // ⚠ estimated
            format: .graphire, maxX: 5104, maxY: 3712, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            // Dimensions from libwacom (127×102mm). The kernel's 50 lpmm gives
            // 102×74mm, too small, and the Volito manual's 127.6×92.8mm may
            // describe another revision. Unresolved without a capture.
            //
            // maxX/maxY (5104/3712) are the manual's 40 lpmm × that area, the
            // arithmetic that came out half the real value on the original
            // Graphire. OTD has no Volito config to check against, so a
            // capture would settle this too.
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 127, activeHeightMM: 102),
        .init(
            // Kernel calls this PenStation2; dimensions/pressure corrected.
            productID: 0x0061, name: "PenStation2",  // ⚠ from kernel
            format: .graphire, maxX: 3250, maxY: 2320, maxPressure: 255,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            // dimensions: input-wacom 4.18 wacom_features_0x61 (3250/50 lpmm × 2320/50 lpmm).
            // Not in libwacom; the kernel WACOM_VOLITO_RES=50 constant proved
            // ~25% off for 0x0060 — these values may be similarly low.
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 65, activeHeightMM: 46.4),
        .init(
            productID: 0x0062, name: "Volito 2",  // ⚠ estimated
            format: .graphire, maxX: 5104, maxY: 3712, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            // dimensions inferred from sibling 0x0060 (Volito) in libwacom
            // wacom-volito-4x5.tablet (Width=127, Height=102). Volito 2 shares
            // identical kernel max coords with Volito 1 → almost certainly the
            // same physical size. Not in libwacom directly.
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 127, activeHeightMM: 102),
        .init(
            // Kernel WACOM_MO "Wacom Bamboo"; libwacom MTE-450 (NumRings=1,
            // 4 buttons). The CTF-430 is 0x0069. WACOM_MO ring (0x17/0x18/
            // 0x65), per OTD's BambooAuxReport: byte 8, bit 7 = finger
            // present, bits 0–6 = position 0–71. Unverified on hardware.
            productID: 0x0065, name: "Bamboo (MTE-450)",  // ⚠ from kernel/libwacom/OTD
            format: .graphire, maxX: 14760, maxY: 9225, maxPressure: 511,
            buttonCount: 4, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),

        // tiltMaxDegrees: 64.0 below (Cintiq 21UX through the end of the
        // intuosV1/intuos3/cintiqV1 families) comes from the kernel: tilt is a
        // 7-bit field biased by 64, raw range [-64, 63], the convention the
        // PTH-660/860 descriptors confirm. The decoders still divide by a
        // literal 63.0; reading this field instead would move which extreme
        // lands on ±1.0, and needs hardware this project lacks.

        // ── Cintiq 21UX first-gen ─────────────────────────────────────────────
        .init(
            // Kernel wacom_features_0x3F: Cintiq 21UX, 1023 pressure, 8 keys.
            // Two rear strips, seen in a public recording.
            productID: 0x003F, name: "Cintiq 21UX (DTZ-2100)",  // ⚠ from kernel
            format: .cintiqV1, maxX: 87200, maxY: 65600, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasTouchStrips: true, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 432, activeHeightMM: 330),

        // ── Intuos 1 (1998–2002) — intuosV1 parser ───────────────────────────
        // 10-byte reports, BE16, 1024-level pressure (10-bit).
        //
        // Coordinate ranges here and in Intuos 2 below are twice a plain BE16
        // read, because IntuosV1Decoder appends a fractional bit from
        // report[9]. Confirmed on the 6×8 (0x0021) and, for every row, against
        // the GD-series manual (mm × 100 lpmm × 2) and OTD's GD-*/XD-*
        // configs. maxPressure stays 1023, not OTD's 2046: the decoder shifts
        // its 11-bit field right when maxPressure <= 1023.
        .init(
            productID: 0x0020, name: "Intuos 4×5",
            format: .intuosV1, maxX: 25400, maxY: 21200, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 127, activeHeightMM: 106),
        .init(
            productID: 0x0021, name: "Intuos 6×8",
            format: .intuosV1, maxX: 40640, maxY: 32480, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .verified, activeWidthMM: 203, activeHeightMM: 162),
        .init(
            productID: 0x0022, name: "Intuos 9×12",
            format: .intuosV1, maxX: 60960, maxY: 48120, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 305, activeHeightMM: 241),
        .init(
            productID: 0x0023, name: "Intuos 12×12",
            format: .intuosV1, maxX: 60960, maxY: 63360, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 305, activeHeightMM: 317),
        .init(
            productID: 0x0024, name: "Intuos 12×18",
            format: .intuosV1, maxX: 91440, maxY: 63360, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 457, activeHeightMM: 317),

        // ── Intuos 2 (2002–2004) — intuosV1 parser ───────────────────────────
        // Same ranges as Intuos 1 above. OTD declares identical dimensions for
        // each XD-* row and its GD-* match.
        .init(
            productID: 0x0041, name: "Intuos 2 (4×5)",
            format: .intuosV1, maxX: 25400, maxY: 21200, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 127, activeHeightMM: 106),
        .init(
            // Same physical 6×8 tablet as 0x0021 and 0x0047.
            productID: 0x0042, name: "Intuos 2 (6×8)",
            format: .intuosV1, maxX: 40640, maxY: 32480, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 203, activeHeightMM: 162),
        .init(
            productID: 0x0043, name: "Intuos 2 (9×12)",
            format: .intuosV1, maxX: 60960, maxY: 48120, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 305, activeHeightMM: 241),
        .init(
            productID: 0x0044, name: "Intuos 2 (12×12)",
            format: .intuosV1, maxX: 60960, maxY: 63360, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 305, activeHeightMM: 317),
        .init(
            productID: 0x0045, name: "Intuos 2 (12×18)",
            format: .intuosV1, maxX: 91440, maxY: 63360, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 457, activeHeightMM: 317),

        // ── Intuos3 (PTZ-xxx, 2003–2006) — intuos3 parser ───────────────────
        // Frames with status bit 6 clear still carry data; see Intuos3Decoder.
        // Aux reports: 0x03 (8 keys in byte 4) and 0x0C (strips + 4+4 keys).
        // Two-stage feature init: [0x02,0x02] immediately, [0x04,0x00] after 150 ms.
        // PTZ-631W (0x00B5) confirmed live; the rest share its init.
        //
        // maxX/maxY match OTD's PTZ-*.json and the Intuos3 manual (mm at 200
        // lpmm, doubled for the fractional bit). maxPressure stays 1023, not
        // OTD's 2046, for the same reason as Intuos 1.
        .init(
            productID: 0x00B0, name: "Intuos3 4×5 (PTZ-430)",  // dims confirmed — see family note
            format: .intuos3, maxX: 25400, maxY: 20320, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])], confidence: .crossReferenced, activeWidthMM: 127, activeHeightMM: 102),
        .init(
            productID: 0x00B1, name: "Intuos3 6×8 (PTZ-630)",  // cross-referenced: linuxwacom + OTD
            format: .intuos3, maxX: 40640, maxY: 30480, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasTouchStrips: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])],
            confidence: .crossReferenced,
            activeWidthMM: 203, activeHeightMM: 152),
        .init(
            productID: 0x00B2, name: "Intuos3 9×12 (PTZ-930)",  // dims confirmed — see family note
            format: .intuos3, maxX: 60960, maxY: 45720, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasTouchStrips: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])], confidence: .crossReferenced, activeWidthMM: 305, activeHeightMM: 229),
        .init(
            productID: 0x00B3, name: "Intuos3 12×12 (PTZ-1230)",  // dims confirmed — see family note
            format: .intuos3, maxX: 60960, maxY: 60960, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasTouchStrips: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])], confidence: .crossReferenced, activeWidthMM: 305, activeHeightMM: 305),
        .init(
            // activeWidthMM corrected 483→488 (487.68mm) — see the family
            // note at the top of this section.
            productID: 0x00B4, name: "Intuos3 12×19 (PTZ-1231W)",
            format: .intuos3, maxX: 97536, maxY: 60960, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasTouchStrips: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])], confidence: .crossReferenced, activeWidthMM: 488, activeHeightMM: 305),
        .init(
            productID: 0x00B5, name: "Intuos3 WS (PTZ-631W)",  // ✓ confirmed live
            format: .intuos3, maxX: 54204, maxY: 31750, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasTouchStrips: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])],
            confidence: .verified,
            activeWidthMM: 270.5, activeHeightMM: 158.5),
        .init(
            // activeWidthMM/Height corrected 152/102→157/98 (157.48/98.425mm)
            // — see the family note at the top of this section.
            productID: 0x00B7, name: "Intuos3 4×6 (PTZ-431W)",
            format: .intuos3, maxX: 31496, maxY: 19685, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])], confidence: .crossReferenced, activeWidthMM: 157, activeHeightMM: 98),

        // ── Intuos4 (PTK-xxx, 2009–2012) — intuosV1 parser ───────────────────
        // Key OLEDs on all but the PTK-440; 2048 pressure levels. maxX/maxY
        // are the native 200 lpmm values (OTD and Wacom's manual agree), and
        // active areas follow them.
        .init(
            productID: 0x00B8, name: "Intuos4 S (PTK-440)",
            format: .intuosV1, maxX: 31496, maxY: 19685, maxPressure: 2047,
            buttonCount: 6, hasTouchRing: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 157, activeHeightMM: 98)
            .withQuirks(intuos4USB),
        .init(
            productID: 0x00B9, name: "Intuos4 M (PTK-640)",
            format: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasKeyOLEDs: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 224, activeHeightMM: 140)
            .withQuirks(intuos4USB),
        .init(
            // Dimensions corrected to kernel wacom_features_0xBA (65024×40640).
            productID: 0x00BA, name: "Intuos4 L (PTK-840)",  // dims kernel + OTD
            format: .intuosV1, maxX: 65024, maxY: 40640, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasKeyOLEDs: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 325, activeHeightMM: 203)
            .withQuirks(intuos4USB),
        .init(
            productID: 0x00BB, name: "Intuos4 XL (PTK-1240)",
            format: .intuosV1, maxX: 97536, maxY: 60960, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasKeyOLEDs: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 488, activeHeightMM: 305)
            .withQuirks(intuos4USB),
        .init(
            // Dimensions corrected to kernel wacom_features_0xBC (40640×25400).
            productID: 0x00BC, name: "Intuos4 WL (PTK-540WL)",  // dims kernel + OTD
            format: .intuosV1, maxX: 40640, maxY: 25400, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasKeyOLEDs: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 203, activeHeightMM: 127)
            .withQuirks(intuos4USB),
        .init(
            // BT Classic PID for the same PTK-540WL: libwacom
            // wacom-intuos4-6x9-wl.tablet lists DeviceMatch
            // usb|056a|00bc;bluetooth|056a|00bd — same device, second transport.
            // Coordinates/dims mirror the USB entry above; seizeUSB=false as
            // with other BT Classic entries in this registry.
            //
            // No hasKeyOLEDs: the Bluetooth image format is 1-bit with a bit
            // scramble (`76543210`→`GECA6420`, per the kernel's sysfs ABI
            // doc), and WacomOutputProtocol only writes USB's 4-bit format.
            productID: 0x00BD, name: "Intuos4 WL (PTK-540WL) BT",  // ⚠ from libwacom
            format: .intuosV1, maxX: 40640, maxY: 25400, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, confidence: .crossReferenced, activeWidthMM: 203, activeHeightMM: 127),

        // ── Intuos5 / Intuos Pro 1st-gen (PTH-x50/x51, 2012–2013) ──────────────
        // IntuosV1 10-byte format, 2047-level pressure. No Bluetooth.
        //
        //   PTH-450  Intuos5 S             0x0026
        //   PTH-650  Intuos5 M             0x0027
        //   PTH-850  Intuos5 L             0x0028
        //   PTH-451  Intuos Pro S (1st)    0x0314
        //   PTH-651  Intuos Pro M (1st)    0x0315
        //   PTH-851  Intuos Pro L (1st)    0x0317
        .init(
            // Coordinates match OTD's PTH-450.json and Wacom's Intuos5 product
            // booklet (157.48×98.43mm). Touch: kernel `touch_max = 16`, OTD
            // MaxX/MaxY 4095, the same BPT3 container as the hardware-verified
            // PTH-850 (0x0028) and PTH-651 (0x0315). 6 ExpressKeys, like the
            // PTK-450 (libwacom's 7th button is the ring center).
            productID: 0x0026, name: "Intuos5 S (PTH-450)",
            format: .intuosV1, maxX: 31496, maxY: 19685, maxPressure: 2047,
            buttonCount: 6, hasTouchRing: true, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 16,
            touchMaxX: 4095, touchMaxY: 4095,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 157, activeHeightMM: 98),
        .init(
            // Same confirmation and touch sources as 0x0026 above.
            productID: 0x0027, name: "Intuos5 M (PTH-650)",
            format: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 16,
            touchMaxX: 4095, touchMaxY: 4095,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 224, activeHeightMM: 140),
        .init(
            // Same sources as 0x0026 above (325.12mm wide).
            //
            // Touch confirmed on this unit: the touch interface's 64-byte
            // report 0x02 is the BPT3 container, which IntuosV1Decoder already
            // dispatches by length. touchMaxX/Y are the format's 12-bit
            // ceiling, as in OTD's PTH-850.json. maxTouchContacts is 16, like
            // CTH-690's: the slot range 2–17 belongs to the protocol.
            productID: 0x0028, name: "Intuos5 L (PTH-850)",
            format: .intuosV1, maxX: 65024, maxY: 40640, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 16,
            touchMaxX: 4095, touchMaxY: 4095,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .verified, activeWidthMM: 325, activeHeightMM: 203),

        // ── Intuos Pro first-gen (PTH-x51, 2013) — intuosV1 parser ───────────
        // Renamed from "Intuos5" to "Intuos Pro"; same HID format.
        .init(
            // 157.48×98.43mm per Wacom's Intuos Pro booklet and OTD's
            // PTH-451.json; touch and 6 ExpressKeys as 0x0026 above.
            productID: 0x0314, name: "Intuos Pro S (PTH-451)",
            format: .intuosV1, maxX: 31496, maxY: 19685, maxPressure: 2047,
            buttonCount: 6, hasTouchRing: true, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 16,
            touchMaxX: 4095, touchMaxY: 4095,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 157, activeHeightMM: 98),
        // 0x0316 is deliberately not a row. No kernel entry or recording
        // knows it; the PTH-651 enumerates as 0x0315.
        .init(
            // Dimensions corrected to kernel wacom_features_0x317 (65024×40640).
            // Previous values (44704×27940) were the PTH-651 M-size by mistake.
            productID: 0x0317, name: "Intuos Pro L (PTH-851)",  // ✓ confirmed live
            format: .intuosV1, maxX: 65024, maxY: 40640, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 16,
            touchMaxX: 4095, touchMaxY: 4095,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .verified,
            activeWidthMM: 325.1, activeHeightMM: 203.2),

        // ── Intuos Pro second-gen (PTH-x60/x80, 2017–present) — intuosV2 ─────
        // 192-byte reports, LE24 coordinates, 8192-level pressure (13-bit).
        // Also BLE (Report IDs 0x01 pen, 0x03 pad). seizeUSB=true.
        //
        //   PTH-460  S   USB 0x0392/0x03DC   BT Classic 0x0393/0x03DD
        //   PTH-660  M   USB 0x0357          BT Classic 0x0360
        //   PTH-860  L   USB 0x0358          BT Classic 0x0361
        //
        // The PTH-460 doesn't follow the others' +9 pattern; 0x0352 is the
        // Cintiq Pro 32.
        .init(
            // Touch wiring and range: vendor model properties. libwacom names
            // 0x0352 the Cintiq Pro 32 pen interface, paired with touch
            // interface 0x0356, which has no row.
            //
            // Dimensions from OTD (701.92 × 396.58 mm at 200 units/mm).
            // libwacom's 686 × 381 is the outlier: Wacom's spec sheet prints
            // 697 × 392. initSteps [0x02, 0x02] is OTD's FeatureInitReport.
            productID: 0x0352, name: "Cintiq Pro 32 (DTH-3220)",  // ⚠ dims OTD + Wacom spec sheet
            format: .intuosV2, maxX: 140384, maxY: 79316, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            touchCompanionPID: 0x0356, confidence: .crossReferenced,
            activeWidthMM: 701.92, activeHeightMM: 396.58),
        .init(
            productID: 0x0357, name: "Intuos Pro M (PTH-660)",  // ✓ confirmed live
            format: .intuosV2, maxX: 44800, maxY: 29600, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            // tiltMaxDegrees 64.0: the PTH-860's descriptor declares tilt as
            // [-64,63] degrees, and this model shares its wire format.
            tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 5,
            // touchMaxX/Y from the touch descriptor (8960 × 5920), which
            // happens to equal pen/5. Sibling rows using pen/5 are still
            // estimates.
            //
            // The PTH-660 presents this PID over Bluetooth too, not 0x0360.
            touchMaxX: 8960, touchMaxY: 5920,
            seizeUSB: true,
            confidence: .verified,
            activeWidthMM: 224.0, activeHeightMM: 148.0),
        .init(
            productID: 0x0358, name: "Intuos Pro L (PTH-860)",  // ✓ confirmed live (USB + BT)
            format: .intuosV2, maxX: 62200, maxY: 43200, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            // tiltMaxDegrees 64.0: the descriptor declares tilt as [-64,63]
            // degrees, logical equal to physical.
            tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 5,
            // USB coordinates and Bluetooth touch confirmed by capture.
            touchMaxX: 12439, touchMaxY: 8639,
            seizeUSB: true,
            confidence: .verified,
            activeWidthMM: 311.0, activeHeightMM: 216.0),

        // ── Bamboo / CTL consumer line — bamboo parser ────────────────────────
        // BAMBOO_PT wire format: pen reports on Report ID 0x02 (9 bytes, LE),
        // per kernel wacom_bpt_pen — but only after the feature-report mode
        // switch [0x02, 0x02]; without it the tablet stays in boot-mouse
        // emulation (4-byte relative packets on report 0x01). Confirmed on a
        // CTL-460 capture.
        .init(
            productID: 0x00D0, name: "Bamboo Touch (CTT-460)",
            // maxPressure 0 is intentional: CTT-460 is finger-touch only, no
            // pen. (Kernel's wacom_features_0xD0 lists the family's pen value.)
            // Coordinates from a CTT-460 recording (bentiss/hid-devices; no
            // license, so it stays out of Samples). The descriptor declares
            // 480×320 over 120×80mm, the touches stay inside it, and the
            // kernel's BBTOUCH_LOWRES quirk only scales this space up to the
            // pen chassis's 14720×9200. Touch decodes through BambooDecoder's
            // 20-byte path (`decodeBPTTouch`).
            format: .bamboo, maxX: 480, maxY: 320, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            hasFingerTouch: true, maxTouchContacts: 2, touchMaxX: 480, touchMaxY: 320,
            seizeUSB: false, confidence: .verified,
            activeWidthMM: 120, activeHeightMM: 80),
        .init(
            // Pen active area 147.2×92.0mm per the CTT/CTL/CTH-460 manual,
            // matching maxX/maxY at 100 lpmm.
            //
            // Touch: the kernel lists this PID as `BAMBOO_PT` with
            // `touch_max = 2`, decoded by `decodeBPTTouch` in the same 480×320
            // space as the CTT-460 (0x00D0). No capture exists.
            productID: 0x00D1, name: "Bamboo Pen & Touch (CTH-460)",
            format: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            hasFingerTouch: true, maxTouchContacts: 2, touchMaxX: 480, touchMaxY: 320,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            // Confirmed by a capture of a unit labeled CTL-460; matches the
            // kernel and linux-hardware. The CTH-470 is 0x00DE. Pen-only: no
            // express keys, and no eraser on the LP-160 pen.
            productID: 0x00D4, name: "Bamboo Pen (CTL-460)",
            format: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            productID: 0x00D5, name: "Bamboo Pen (CTL-660)",  // ⚠ from kernel 0xD5 (Bamboo Pen 6×8, BAMBOO_PEN family); linux-hardware "Bamboo Pen (M)"
            format: .bamboo, maxX: 21648, maxY: 13700, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 217, activeHeightMM: 137),
        .init(
            // Same 147.2×92.0mm chassis as CTH-460 (0x00D1).
            productID: 0x00D6, name: "Bamboo Fun Pen & Touch (CTH-461)",  // dims kernel + OTD; kernel 0xD6 (BambooPT 2FG 4x5); previously misnamed CTL-460 (that's 0x00D4)
            format: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            // Touch: kernel table declares BAMBOO_PT, touch_max = 2 — see 0x00D1's note.
            hasFingerTouch: true, maxTouchContacts: 2, touchMaxX: 480, touchMaxY: 320,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            // Same 147.2×92.0mm chassis as CTH-460 (0x00D1).
            productID: 0x00D7, name: "Bamboo Pen & Touch (small)",  // dims kernel + OTD (kernel 0xD7, BambooPT 2FG Small); ⚠ name attribution still uncertain
            format: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            // Touch: kernel table declares BAMBOO_PT, touch_max = 2 — see 0x00D1's note.
            hasFingerTouch: true, maxTouchContacts: 2, touchMaxX: 480, touchMaxY: 320,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            // Same 147.2×92.0mm chassis as CTH-460 (0x00D1).
            productID: 0x00DA, name: "Bamboo Pen & Touch SE (CTH-461SE)",  // ⚠ from kernel 0xDA (Bamboo 2FG 4x5 SE)
            format: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            // Touch: kernel table declares BAMBOO_PT, touch_max = 2 — see 0x00D1's note.
            hasFingerTouch: true, maxTouchContacts: 2, touchMaxX: 480, touchMaxY: 320,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            productID: 0x00DB, name: "Bamboo Pen & Touch SE (CTH-661SE)",  // dims kernel + OTD (kernel 0xDB, Bamboo 2FG 6x8 SE); ⚠ name attribution still uncertain
            format: .bamboo, maxX: 21648, maxY: 13700, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 217, activeHeightMM: 137),
        .init(
            // libwacom wacom-bamboo-4fg-s-t.tablet: "second generation BambooPT",
            // no stylus, 2FG touch (4FG gesture). maxPressure 0 is intentional —
            // touch-only, same convention as the CTT-460 entry (0x00D0) above.
            // 14720×9200 is suspect, as it proved on the CTT-460: this
            // generation likely uses BBTOUCH3 (4096×4096 in the kernel). No
            // capture exists.
            productID: 0x00D9, name: "Bamboo Touch (CTT-460A)",  // ⚠ from libwacom
            format: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 0,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, activeWidthMM: 127, activeHeightMM: 76),
        .init(
            // libwacom wacom-bamboo-16fg-s-t.tablet: "third generation
            // BambooPT", described as "no stylus; 16FG touch" despite
            // Stylus=true, so touch-only (maxPressure 0). 147.2×92.0mm matches
            // maxX/maxY at 100 lpmm, but 14720×9200 is suspect for the same
            // reason as 0x00D9 above. No capture exists.
            productID: 0x00DC, name: "Bamboo Touch (CTT-470)",  // ⚠ from libwacom
            format: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 0,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, activeWidthMM: 147, activeHeightMM: 92),

        // ── Cintiq pen-display line — cintiqV1 parser ────────────────────────
        // These pen displays expose a mouse-compatible collection whose report
        // 0x01 the OS reads as a click, so every cintiqV1 row with a decoder
        // (maxX > 0) sets seizeUSB=true. Name-only rows don't: seizing a
        // device nothing decodes is worse.
        // All use the WACOM_24HD layout in CintiqV1Decoder:
        //   Report 0x02 — pen (10-byte IntuosV1, WACOM_24HD typeNibble dispatch)
        //   Report 0x0C — express keys + touch rings or strips, in the
        //                 layout `CintiqPadLayout` picks by product ID
        //   Report 0x01 — tip switch
        // 0x00C0 and 0x00C4 aren't the Cintiq 20WSX and 13HD: the kernel names
        // them DTF-720 and DTF-521. The 13HD is 0x0304 and the 20WSX 0x00C5.
        .init(
            // Kernel wacom_features_0xC6: 10 keys. Two strips, seen in a
            // public recording.
            productID: 0x00C6, name: "Cintiq 12WX",  // ⚠ estimated
            format: .cintiqV1, maxX: 53020, maxY: 33440, maxPressure: 1023,
            buttonCount: 10, hasTouchRing: false, hasTouchStrips: true, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 261, activeHeightMM: 163),
        .init(
            // Kernel calls this "Cintiq 21UX2" (DTZ-2100B / second gen).
            // Distinct from the gen-1 21UX at 0x003F.
            // No bezelButtonCount (0 = default): unlike 24HD, this family has
            // no capacitive OSD buttons — bytes 1-4 of the pad report are the
            // two touch strips. Each strip has four modes and its own mode
            // toggle (buttons 16 and 17). See CintiqV1Decoder's pad decode
            // comment.
            productID: 0x00CC, name: "Cintiq 21UX2 (DTK-2100)",  // model per libwacom (DTZ-2100 is the first-gen 21UX, 0x003F); from kernel + OTD
            format: .cintiqV1, maxX: 87200, maxY: 65600, maxPressure: 2047,
            buttonCount: 18, hasTouchRing: false, hasTouchStrips: true, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 432, activeHeightMM: 330),
        .init(
            productID: 0x00F4, name: "Cintiq 24HD (DTK-2400)",  // ✓ confirmed live
            format: .cintiqV1, maxX: 104480, maxY: 65600, maxPressure: 2047,
            buttonCount: 8, bezelButtonCount: 3, hasTouchRing: true, hasDualRings: true, ringSlotCount: 3, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], ledCompanionPID: 0x0056,
            confidence: .verified,
            activeWidthMM: 519.0, activeHeightMM: 324.0),
        .init(
            // Touch init 0x12 = 2: Linux's WACOM_24HDT mode switch
            // (wacom_sys.c). Touch wiring and range: vendor model properties.
            // Active area matches 0x00F4 (Cintiq 24HD): same maxX/maxY and
            // panel, and Wacom's booklets give both 518.4×324.0mm.
            //
            // Finger touch arrives on the separate 0x00F6 interface, decoded by
            // `Wacom24HDTDecoder`. No capture exists for either interface.
            productID: 0x00F8, name: "Cintiq 24HD Touch (DTH-2400)",  // ⚠ estimated
            format: .cintiqV1, maxX: 104480, maxY: 65600, maxPressure: 2047,
            buttonCount: 8, bezelButtonCount: 3, hasTouchRing: true, hasDualRings: true, ringSlotCount: 3, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            touchMaxX: 5184, touchMaxY: 3240,  // 0x00F6 descriptor (linuxwacom)
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], ledCompanionPID: 0x0056, touchCompanionPID: 0x00F6, touchCompanionInitSteps: [.featureReport([0x12, 0x02])], confidence: .crossReferenced, activeWidthMM: 519.0, activeHeightMM: 324.0),
        .init(
            // No bezelButtonCount (0 = default): shares 21UX2's 18-button
            // pad field (byte[6]/byte[8] express keys + byte[5]/byte[7]
            // center toggles), correctly routed by CintiqV1Decoder's
            // bezelButtonCount gate.
            //
            // buttonCount 18: the kernel packs 18 numbered buttons into bytes
            // 5-8 and the three OSD keys into byte 9, which the decoder doesn't
            // read yet; its bit order needs a capture.
            productID: 0x00FA, name: "Cintiq 22HD (DTK-2200)",  // ⚠ from OTD (maxX corrected to kernel wacom_features_0xFA)
            format: .cintiqV1, maxX: 95840, maxY: 54260, maxPressure: 2047,
            buttonCount: 18, hasTouchRing: false, hasTouchStrips: true, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 483, activeHeightMM: 279),
        // 0x00FB is the DTU-1031 (kernel `wacom_features_0xFB`), not a 21UX.

        // ── Intuos5 without touch (PTK-450/650) ──────────────────────────────
        // Kernel INTUOS5S/INTUOS5: no key OLEDs. Active areas match their PTH
        // twins (0x0026, 0x0027), which carry the same maxX/maxY.
        .init(
            productID: 0x0029, name: "Intuos5 S (PTK-450)",  // ⚠ from OTD
            format: .intuosV1, maxX: 31496, maxY: 19685, maxPressure: 2047,
            buttonCount: 6, hasTouchRing: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 157, activeHeightMM: 98),
        .init(
            productID: 0x002A, name: "Intuos5 M (PTK-650)",  // ⚠ from OTD
            format: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 224, activeHeightMM: 140),

        // ── Intuos Pro first-gen additional variant ───────────────────────────
        .init(
            // Confirmed as the PTH-651's PID by a reporter's captures.
            //
            // The ring is the intuosV1 `ring1 = data[2]` layout (bit 7 active,
            // bits 6–0 position), and the keys are
            // `(data[4] << 1) | (data[3] & 0x01)`, per those captures.
            //
            // Active area computed from maxX/maxY at 5080 lpi (223.5×139.7mm),
            // as on its PTH-650 twin (0x0027), not the rounded spec sheet.
            //
            // Touch: the 64-byte report 0x02 on the 0xFF00 interface is the BPT3
            // container, which IntuosV1Decoder already handles.
            //
            // touchMaxX/Y 4095/4095 are reasoned, not measured: the captures
            // reached 4079 on one axis and 3535 on the other. At fixed counts
            // per mm the short axis would top out near 2559, so each axis must
            // scale to the full 12 bits, as on the PTH-850. The axes are
            // assumed untransposed (the captures were mostly vertical
            // scrolling); revisit that first if touch comes out rotated.
            //
            // maxTouchContacts 16: the slot range 2–17 belongs to the protocol,
            // whatever the spec sheet says.
            productID: 0x0315, name: "Intuos Pro M (PTH-651)",
            format: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 16,
            touchMaxX: 4095, touchMaxY: 4095,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .verified, activeWidthMM: 224, activeHeightMM: 140),

        // ── Intuos Pro second-gen Bluetooth Classic PIDs (PTH-460/660/860) ──────
        // These PIDs appear when the tablet connects over BT Classic (transport="Bluetooth").
        // Coordinate ranges match the USB entries; seizeUSB=false (BT Classic needs no seizure).
        .init(
            productID: 0x0360, name: "Wacom PTH-660",  // dims kernel + OTD
            format: .intuosV2, maxX: 44800, maxY: 29600, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            // tiltMaxDegrees 64.0: see the 0x0357/0x0358 USB entries for the
            // descriptor citation. Rarely hit (see note below), kept aligned.
            tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 5,
            // Touch values mirror the USB PTH-660 entry, which the PTH-660
            // presents over Bluetooth instead of this PID; kept as a fallback.
            touchMaxX: 8960, touchMaxY: 5920,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 229, activeHeightMM: 152),
        .init(
            productID: 0x0361, name: "Intuos Pro L (PTH-860) BT",  // ✓ confirmed live (BT Classic)
            format: .intuosV2, maxX: 62200, maxY: 43200, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            // tiltMaxDegrees 64.0: descriptor cited on the USB entries above,
            // and confirmed on Bluetooth captures with three pens.
            tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 5,
            // The PTH-860 does present 0x0361 over Bluetooth Classic. Touch
            // values below are unverified.
            touchMaxX: 12439, touchMaxY: 8639,
            seizeUSB: false,
            confidence: .verified,
            activeWidthMM: 311.0, activeHeightMM: 216.0),
        // No 0x035B: the PTH-460 doesn't follow the +9 pattern (0x0392 USB,
        // 0x0393 Bluetooth).
        .init(
            // Kernel features_0x393 (INTUOSP2S_BT) + OTD PTH-460.json + libwacom
            // wacom-intuos-pro-2-s.tablet all agree on PIDs and coordinates.
            // 6 express keys + touch ring (libwacom's 7th button is the ring
            // center). Touch fields mirror the PTH-660 pattern: kernel reports
            // touch_max=10 but the sibling 0x21 report carries 5 slots;
            // touchMaxX/Y estimated as pen/5 like PTH-660 until captured.
            productID: 0x0392, name: "Intuos Pro S (PTH-460)",  // cross-referenced: kernel + OTD + libwacom
            format: .intuosV2, maxX: 31920, maxY: 19950, maxPressure: 8191,
            buttonCount: 6, hasTouchRing: true, hasEraser: true,
            tiltMaxDegrees: 64.0,  // PTH-x60 family, descriptor-confirmed on PTH-660/860
            hasFingerTouch: true, maxTouchContacts: 5,
            touchMaxX: 6384, touchMaxY: 3990,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 159.6, activeHeightMM: 99.75),
        .init(
            // Hardware-revision PID variant; OTD PTH-460.json ProductID 988 and
            // libwacom DeviceMatch usb|056a|03dc. Same device as 0x0392.
            productID: 0x03DC, name: "Intuos Pro S (PTH-460)",  // cross-referenced: OTD + libwacom
            format: .intuosV2, maxX: 31920, maxY: 19950, maxPressure: 8191,
            buttonCount: 6, hasTouchRing: true, hasEraser: true,
            tiltMaxDegrees: 64.0,  // PTH-x60 family, descriptor-confirmed on PTH-660/860
            hasFingerTouch: true, maxTouchContacts: 5,
            touchMaxX: 6384, touchMaxY: 3990,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 159.6, activeHeightMM: 99.75),

        // ── Bamboo / Graphire-era CTE / CTF consumer line ─────────────────────
        // Graphire-era: graphire 8-byte format.
        .init(
            // Active area as CTE-450 (0x0017), which shares its maxX/maxY.
            productID: 0x006A, name: "Wacom CTE-460",  // ⚠ from kernel; parser per kernel and Wacom family, not OTD
            format: .graphire, maxX: 14760, maxY: 9225, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 148, activeHeightMM: 92),
        .init(
            // Active area as 0x0018 (Bamboo Fun medium, CTE-650), which shares
            // its maxX/maxY.
            productID: 0x006B, name: "Wacom CTE-660",  // ⚠ from kernel; parser per kernel and Wacom family, not OTD
            format: .graphire, maxX: 21648, maxY: 13530, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            // Kernel WACOM_MO "BambooFun 6x8"; libwacom CTE-650 (NumRings=1).
            // Active area 216.5×135.3mm per the Bamboo Fun manual, matching
            // maxX/maxY. Graphire-format reports like its 0x0017/0x0065
            // siblings; `.bamboo` read hover as out of range and the eraser as
            // the tip (issue #20 capture).
            productID: 0x0018, name: "Bamboo Fun medium (CTE-650)",  // ⚠ from kernel/libwacom/OTD
            format: .graphire, maxX: 21648, maxY: 13530, maxPressure: 511,
            buttonCount: 4, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            // Active area inferred from the original Graphire 4×5 chassis
            // (127.6×92.8mm), which shares its maxX/maxY.
            productID: 0x0069, name: "Wacom CTF-430",  // ⚠ from OTD; parser per kernel and Wacom family, not OTD
            format: .graphire, maxX: 5104, maxY: 3712, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 128, activeHeightMM: 93),

        // ── Bamboo CTH (pen + touch) ──────────────────────────────────────────
        .init(
            productID: 0x0319, name: "Wacom CTH-300",  // ⚠ from OTD
            format: .bamboo, maxX: 10690, maxY: 6680, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            // Touch range: kernel wacom_features_0x319.
            hasFingerTouch: true, maxTouchContacts: 4, touchMaxX: 4095, touchMaxY: 4095,
            // dimensions: libwacom wacom-bamboo-pad-wireless.tablet (Width=102, Height=76)
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 102, activeHeightMM: 76),
        .init(
            productID: 0x0318, name: "Wacom CTH-301",  // ⚠ from OTD
            format: .bamboo, maxX: 10690, maxY: 6680, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            // Touch range: kernel wacom_features_0x318.
            hasFingerTouch: true, maxTouchContacts: 4, touchMaxX: 4095, touchMaxY: 4095,
            // dimensions: libwacom wacom-bamboo-pad.tablet (Width=102, Height=76)
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 102, activeHeightMM: 76),
        .init(
            // Same 147.2×92.0mm chassis as 0x00D1.
            //
            // The kernel lists this PID as `BAMBOO_PT` ("Wacom Bamboo Craft"),
            // the little-endian 2009-2011 generation. OTD's CTH-461.json groups
            // it with 0x00D7 and 0x00DA: a 9-byte pen and a 20-byte touch/pad
            // report, as `decodeBPT`/`decodeBPTTouch` split them. Touch uses
            // the 480×320 space of the CTT-460 (0x00D0).
            productID: 0x00D2, name: "Wacom CTH-461",  // ⚠ from OTD
            format: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 2, touchMaxX: 480, touchMaxY: 320,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            // Same chassis as 0x00D2 above. `.bamboo` per OTD's CTH-470.json
            // (little-endian `IntuosReportParser`, same maxima) and libwacom
            // ("third generation BambooPT"). No capture exists.
            productID: 0x00DE, name: "Wacom CTH-470",  // ⚠ from OTD
            format: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            // Touch: kernel touch_max = 16, 64-byte BPT3 container → flat 4096 range.
            hasFingerTouch: true, maxTouchContacts: 16,
            touchMaxX: 4095, touchMaxY: 4095,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            // The INTUOSHT generation (2013): pen report ID 0x02, 10 bytes,
            // little-endian (kernel wacom_bpt_pen). Read as `.intuosV1`, a
            // capture decoded every position to ~130,600; little-endian hits
            // each of these four PIDs' maxX exactly. The INTUOSHT2 successors
            // (0x033B/033C/033D/033E) are `.intuosV1`, as in the kernel.
            // Express keys arrive in the BPT3 container. Active area 152.0 ×
            // 95.0 mm per Wacom's CTL/CTH-480/680 booklet.
            productID: 0x0302, name: "Wacom CTH-480",  // ⚠ from OTD
            format: .bamboo, maxX: 15200, maxY: 9500, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            // Touch: kernel touch_max = 16 + flat 4096 (INTUOSHT); OTD CTH-480.json 4095×4095.
            hasFingerTouch: true, maxTouchContacts: 16,
            touchMaxX: 4095, touchMaxY: 4095,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // Active area 152.0 × 95.0 mm per Wacom's CTL/CTH-490/690 booklet.
            productID: 0x033C, name: "Wacom CTH-490",  // ⚠ from OTD
            format: .intuosV1, maxX: 15200, maxY: 9500, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            // Touch: INTUOSHT2 range is pen max / 10, same rule as the verified CTH-690.
            hasFingerTouch: true, maxTouchContacts: 16,
            touchMaxX: 1520, touchMaxY: 950,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // The kernel lists this PID as `BAMBOO_PT` ("Wacom Bamboo 2FG 6x8"),
            // like 0x00D2 above; OTD's CTH-661.json groups it with 0x00D8 and
            // 0x00DB. No touch: the 480×320 space belongs to the 4x5 chassis,
            // and nothing has captured this size's touch.
            productID: 0x00D3, name: "Wacom CTH-661",  // ⚠ from OTD
            format: .bamboo, maxX: 21648, maxY: 13700, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 217, activeHeightMM: 137),
        .init(
            // As 0x00D3 above (kernel: "Wacom Bamboo Comic 2FG"), also
            // without touch.
            productID: 0x00D8, name: "Wacom CTH-661",  // ⚠ from OTD
            format: .bamboo, maxX: 21648, maxY: 13700, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 217, activeHeightMM: 137),
        .init(
            // The kernel lists this PID as `BAMBOO_PT` with `touch_max = 16`
            // ("Wacom Bamboo 16FG 6x8"). OTD's CTH-670.json pairs a
            // little-endian pen with a 64-byte BPT3 container for touch.
            // Active area 216.48 × 137 mm per that config, matching maxX/maxY.
            productID: 0x00DF, name: "Wacom CTH-670",  // ⚠ from OTD
            format: .bamboo, maxX: 21648, maxY: 13700, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            // Touch: same as 0x00DE.
            hasFingerTouch: true, maxTouchContacts: 16,
            touchMaxX: 4095, touchMaxY: 4095,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216.48, activeHeightMM: 137),
        .init(
            // INTUOSHT; see the note on 0x0302 (CTH-480) above.
            productID: 0x0303, name: "Wacom CTH-680",  // ⚠ from OTD
            format: .bamboo, maxX: 21600, maxY: 13500, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            // Touch: same as 0x0302.
            hasFingerTouch: true, maxTouchContacts: 16,
            touchMaxX: 4095, touchMaxY: 4095,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x033E, name: "Wacom CTH-690",  // ✓ format confirmed via user discovery capture
            format: .intuosV1, maxX: 21600, maxY: 13500, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: false, tiltMaxDegrees: 64.0,
            // Capture confirmed classic Intuos pen packets on report 0x10
            // (tool-change 0xC2, exit 0x80, pen 0xE0/0xE1) and the 64-byte
            // BPT3 container on 0x02 carrying 16-finger touch (12-bit coords)
            // plus the four express keys. Coordinate/pressure maxima are from
            // the kernel (wacom_features_0x33E); capture ranges consistent.
            // LP-190K pen has no eraser end.
            hasFingerTouch: true, maxTouchContacts: 16,
            // not the 12-bit ceiling, despite the 12-bit field. The kernel
            // hardcodes touch ranges for this whole protocol family because
            // the touch descriptor declares nothing usable, and it splits by
            // generation (`wacom_wac.c`, the WACOM_PKGLEN_BBTOUCH3 block):
            // INTUOSHT2 — this device — gets pen max / 10, while Intuos5/Pro
            // gets a flat 4096. The capture agrees: its Y high byte tops out
            // at 84, i.e. 1350 >> 4. A 4095 ceiling shrank every gesture to a
            // third of the screen.
            touchMaxX: 2160, touchMaxY: 1350,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .verified, activeWidthMM: 216, activeHeightMM: 135),

        // ── Wacom One / Intuos (CTL) pen-only line ────────────────────────────
        .init(
            // Same 147.2×92.0mm chassis as the CTH-460 group (0x00D1).
            productID: 0x00DD, name: "Wacom CTL-470",  // ⚠ from OTD; parser per kernel and Wacom family, not OTD
            format: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 147, activeHeightMM: 92),
        .init(
            // `.bamboo`: libwacom calls the CTL-471 "third generation
            // BambooPT", and OTD's CTL-471.json uses the little-endian
            // `IntuosTabletReport` that `decodeBPT` matches, with 10-byte
            // reports. No capture exists. 152×95mm per OTD and the manual;
            // libwacom's 152×102 contradicts its own "5.8 x 3.63in". Dims
            // match vendor model properties and OTD; the kernel's 14720×9225
            // is the CTE-460's range.
            productID: 0x0300, name: "Wacom CTL-471",  // ⚠ from OTD + vendor model properties
            format: .bamboo, maxX: 15200, maxY: 9500, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // Active area 152 × 95 mm per Wacom's CTL-472/672 booklet,
            // matching maxY at 100 lpmm.
            productID: 0x037A, name: "Wacom CTL-472",  // ⚠ from OTD; parser per kernel and Wacom family, not OTD
            format: .bamboo, maxX: 15200, maxY: 9500, maxPressure: 2047,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // INTUOSHT; see the note on 0x0302 (CTH-480) above.
            productID: 0x030E, name: "Wacom CTL-480",  // ⚠ from OTD
            format: .bamboo, maxX: 15200, maxY: 9500, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // Active area as 0x033C (CTH-490) above.
            productID: 0x033B, name: "Wacom CTL-490",  // ⚠ from OTD
            format: .intuosV1, maxX: 15200, maxY: 9500, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // Kernel wacom_features_0x301 names this "Bamboo One M" (BAMBOO_PEN
            // family), hence `.bamboo`.
            // Dims are 21600×13500 per vendor model properties and OTD,
            // matching 216×135 mm at 100 lines/mm. The kernel's 21648×13530 is
            // the CTE-660's range. Not hardware-tested.
            productID: 0x0301, name: "Bamboo One M (CTL-671)",  // ⚠ from OTD + vendor model properties
            format: .bamboo, maxX: 21600, maxY: 13500, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x037B, name: "Wacom CTL-672",  // ⚠ from OTD; parser per kernel and Wacom family, not OTD
            format: .bamboo, maxX: 21600, maxY: 13500, maxPressure: 2047,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            // INTUOSHT; see the note on 0x0302 (CTH-480) above.
            productID: 0x0323, name: "Wacom CTL-680",  // ⚠ from OTD
            format: .bamboo, maxX: 21600, maxY: 13500, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x033D, name: "Wacom CTL-690",  // ⚠ from OTD
            format: .intuosV1, maxX: 21600, maxY: 13500, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            // Active area 152 × 95 mm per Wacom's CTL-4100 family booklet,
            // matching maxY at 100 lpmm.
            productID: 0x0374, name: "Wacom CTL-4100",  // ⚠ from OTD
            format: .intuosV2, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, confidence: .crossReferenced,
            activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // Active area as 0x0374 above.
            productID: 0x0376, name: "Wacom CTL-4100WL",  // ⚠ from OTD
            format: .intuosV2, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // Active area as 0x0374 above.
            productID: 0x0377, name: "Wacom CTL-4100WL",  // ⚠ from OTD
            format: .intuosV2, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // Active area as 0x0374 above.
            productID: 0x03C5, name: "Wacom CTL-4100WL",  // ⚠ from OTD
            format: .intuosV2, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // Bluetooth PID of the later-generation CTL-4100WL (USB side is
            // 0x03C5 above). The `0x81` capture behind
            // `decodeIntuosHT3BTFrames` came from this PID. No feature init:
            // Bluetooth doesn't take the `02 02` mode select.
            productID: 0x03C6, name: "Wacom CTL-4100WL",
            format: .intuosV2, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 95),
        .init(
            productID: 0x0375, name: "Wacom CTL-6100",  // ⚠ from OTD
            format: .intuosV2, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x0378, name: "Wacom CTL-6100WL",  // ⚠ from OTD
            format: .intuosV2, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x03C7, name: "Wacom CTL-6100WL",  // ⚠ from OTD
            format: .intuosV2, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            // Bluetooth PID of the later-generation CTL-6100WL (USB side is
            // 0x03C7 above). Bluetooth decode is verified on the CTL-4100WL,
            // which shares the protocol but not these dimensions.
            productID: 0x03C8, name: "Wacom CTL-6100WL",
            format: .intuosV2, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),

        // ── Wacom One CTC (IntuosV3) consumer line ────────────────────────────
        // CTC-4110WL / CTC-6110WL use the IntuosV3 report parser (same as
        // PTK-470/670/870), not the IntuosV2 used by CTL-4100/6100.
        // Confirmed from OTD Configurations/Wacom/CTC-4110WL.json and
        // CTC-6110WL.json (FeatureInitReport "AgI=" = [0x02, 0x02]).
        // No touch ring or express keys: pen-only AES devices.
        //
        // VID 0x0531 (Wacom Technology Corp.) is real: input-wacom's device-ID
        // table and libwacom both list 0x0531:0x0100/0x0101/0x0104 for the
        // CTC-4110WL. See `vendorIDs`.
        //
        // Dimensions keep OTD's figures over libwacom's, which look like outer
        // body size rather than active area: libwacom gives the S 152×102 while
        // its own comment states a 5.98×3.74in active area — that is 152×95,
        // ours. For the M it gives 229×127 against our 216×135, and 21600×13500
        // at 2540 LPI is exactly 216×135. Do not "fix" toward libwacom.
        //
        // The kernel knows no 0x0531 device, so don't cite it here. Its
        // wacom_features_0x37A "One by Wacom S" shares 15200×9500 but is a
        // different tablet on 0x056A.
        //
        // The pen (CP92303B2Z) has no physical tail eraser, but its upper
        // side switch reports as a logical eraser tool (byte 2 bit 5 on both
        // the 0x1F vendor report and the 0x06 HID-standard report) — hence
        // hasEraser: true despite the device having no rear-eraser hardware.
        // buttonCount is 0 because that field tracks tablet/pad buttons, not
        // pen side switches (the pen has 2, decoded independent of this).
        .init(
            // PID collision: kernel wacom_features_0x100 is "ISDv4 100", a
            // built-in tablet-PC digitizer that can never appear standalone on
            // macOS — the modern CTC-4110WL (Wacom One S) reuses the PID and
            // is the only device this entry can match in practice.
            productID: 0x0100, name: "Wacom One S (CTC-4110WL)",
            format: .intuosV3, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .verified, activeWidthMM: 152, activeHeightMM: 95)
            // Report 0x06 is this family's real pen report, not an idle frame.
            .withQuirks { $0.usbIdleReport = nil },
        .init(
            // Bluetooth LE personality. Raw vendor report 0x1F is 19 bytes
            // here (one trailing vendor byte) vs. 18 on USB — same parser,
            // decoder must branch on transport for that byte, not just PID.
            productID: 0x0101, name: "Wacom One S (CTC-4110WL, Bluetooth)",
            format: .intuosV3, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 152, activeHeightMM: 95),
        .init(
            // USB Android-mode personality: shorter descriptor, no 0xAC
            // container, but same 18-byte 0x06/0x1F pen reports as USB PC.
            productID: 0x0104, name: "Wacom One S (CTC-4110WL, Android)",
            format: .intuosV3, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .experimental, activeWidthMM: 152, activeHeightMM: 95)
            // Report 0x06 is this family's real pen report, not an idle frame.
            .withQuirks { $0.usbIdleReport = nil },
        // The M's three PIDs mirror the S's: USB PC, Bluetooth, USB Android.
        // Transport roles come from libwacom's wacom-one-pen-m.tablet
        // (`usb|0531|0102;bluetooth|0531|0103;usb|0531|0105`); OTD carries
        // 0x0102/0x0103 unlabeled and lacks 0x0105 entirely.
        .init(
            productID: 0x0102, name: "Wacom One M (CTC-6110WL)",  // ⚠ from OTD + libwacom
            format: .intuosV3, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135)
            // Report 0x06 is this family's real pen report, not an idle frame.
            .withQuirks { $0.usbIdleReport = nil },
        .init(
            productID: 0x0103, name: "Wacom One M (CTC-6110WL, Bluetooth)",  // ⚠ from OTD + libwacom
            format: .intuosV3, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            // libwacom-only; absent from OTD and from the kernel, which knows
            // no 0x0531 device at all. Inferred to behave like the S's 0x0104
            // since that pairing is confirmed on real hardware — no CTC-6110WL
            // has been seen here, so all three M rows remain unverified.
            productID: 0x0105, name: "Wacom One M (CTC-6110WL, Android)",  // ⚠ from libwacom
            format: .intuosV3, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .experimental, activeWidthMM: 216, activeHeightMM: 135),

        // ── Cintiq pen-display additional models ──────────────────────────────
        .init(
            // Dimensions match the kernel and vendor model properties. maxPressure 2047
            // per vendor model properties and OTD; the kernel's 1023
            // disagrees with its own 13HD Touch (0x0333) on the same panel.
            // Parser .intuosV1 like 0x0333: the kernel (WACOM_13HD) treats
            // both as one model. Not hardware-tested.
            productID: 0x0304, name: "Wacom Cintiq 13HD (DTK-1300)",  // ⚠ from kernel, OTD + vendor model properties
            format: .intuosV1, maxX: 59552, maxY: 33848, maxPressure: 2047,
            buttonCount: 9, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            // Active area 298.74×171.35mm per Wacom's DTK/DTH-1300 booklet.
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 299, activeHeightMM: 171),
        .init(
            // Second interface of the DTK-2200 at 0x00FA, not a separate
            // tablet. OTD carries both under one config, split by report
            // length: 10-byte pen there, 5-byte reports here, whose contents
            // are unknown and dropped. Neither kernel nor libwacom lists it.
            productID: 0x00F9, name: "Cintiq 22HD secondary interface (pairs 0x00FA)",  // ⚠ name-only, 5-byte reports undecoded
            format: .cintiqV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            isPenDisplay: false,
            seizeUSB: false),
        // ── IntuosV2 / IntuosV3 pen displays — seizeUSB policy ───────────────
        // Same policy as the cintiqV1 displays: seizeUSB=true wherever a
        // decoder exists (maxX > 0), false on name-only rows.
        .init(
            // Touch wiring and range: vendor model properties.
            productID: 0x034F, name: "Wacom DTH-1320",  // ⚠ from OTD
            format: .intuosV2, maxX: 59552, maxY: 33848, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            touchMaxX: 11752, touchMaxY: 6608, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], touchCompanionPID: 0x0353, confidence: .crossReferenced, activeWidthMM: 294, activeHeightMM: 166),
        .init(
            // Active area 348.16×197.59mm per OTD's DTK-1660.json, whose
            // maxima match; Wacom's booklet rounds it to 344×194mm.
            productID: 0x0390, name: "Wacom Cintiq 16 (DTK-1660)",  // ⚠ from OTD
            format: .intuosV2, maxX: 69632, maxY: 39518, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 348, activeHeightMM: 198),
        .init(
            // Same panel as 0x0390 above.
            productID: 0x03AE, name: "Wacom Cintiq 16 (DTK-1660)",  // ⚠ from OTD
            format: .intuosV2, maxX: 69632, maxY: 39518, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 348, activeHeightMM: 198),
        .init(
            productID: 0x03A6, name: "Wacom DTC-133",  // ⚠ from OTD
            format: .intuosV2, maxX: 29434, maxY: 16556, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            tiltMaxDegrees: 64.0,  // descriptor: vendor 0x10 tilt [-64,63] degrees
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 279, activeHeightMM: 152),
        .init(
            // Touch wiring and range: vendor model properties.
            productID: 0x03C0, name: "Wacom Cintiq Pro 27 (DTH-271)",  // cross-referenced: linuxwacom + libwacom + OTD
            format: .intuosV2, maxX: 120032, maxY: 67868, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 10,
            // touchMaxX/Y from this PID's touch descriptor
            // (linuxwacom/wacom-hid-descriptors): 23848 x 13412 on report 0x0C.
            touchMaxX: 23848, touchMaxY: 13412,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 610, activeHeightMM: 330),
        .init(
            // Touch wiring and range: vendor model properties.
            productID: 0x03F0, name: "Wacom Movink 13 (DTH-135)",  // cross-referenced: OTD (real pen capture, PR #3679) + libwacom; buttonCount 3
            format: .intuosV3, maxX: 59552, maxY: 33848, maxPressure: 8191,
            buttonCount: 3, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            touchMaxX: 29375, touchMaxY: 16523, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 294.6, activeHeightMM: 165.1),

        // ── Cintiq Pro / DTK / DTH current-gen pen displays — groundwork only ──
        // Wacom's own driver supports every model here; these rows keep their
        // PIDs and dimensions ready in case it stops. Parser by similarity to
        // the Cintiq Pro 32 (0x0352): .intuosV2, seizeUSB, [0x02,0x02] init.
        // Unless noted, dimensions are libwacom's mm × 200 units/mm, and none
        // is hardware-verified.
        .init(
            // Touch wiring and range: vendor model properties.
            // Pen range and pressure: vendor model properties.
            // Cintiq Pro 16 (2021), DTH-167. Pen interface; finger touch
            // arrives on the separate 0x03B3 product. 0x03B4 is its internal
            // USB hub and needs no row.
            //
            // "Cintiq Pro 16" also names the 2016 DTH-1620, at the same 344.2 x
            // 193.6 mm. The touch maxima tell them apart: 13768 x 7744 here,
            // 13824 x 7776 on the DTH-1620 (0x0354), differing in aspect past
            // rounding.
            //
            // 344.2 x 193.6 is the descriptor's Physical Maximum; libwacom's
            // 356 x 203 is the outer body. maxX/maxY keep this block's 200
            // units/mm convention.
            //
            // Touch is standard HID, reached through the companion PID as on
            // the 27QHD (0x032B).
            //
            // A public 0x03B2 descriptor (libwacom issue 512) declares X 69644,
            // Y 39524, and pressure 8191 at the `.intuosV2` offsets, eight key
            // bits in report 0x11, and tilt [-64, 63] degrees. Pen, keys, and
            // tilt confirmed live (issue #19).
            productID: 0x03B2, name: "Cintiq Pro 16 (DTH-167)",  // ✓ confirmed live
            format: .intuosV2, maxX: 69644, maxY: 39524, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            touchMaxX: 13768, touchMaxY: 7744,
            isPenDisplay: true,
            // Startup sequence: enable pen scan, then DATAMODE. The payload is
            // inverted, so enable sends 0x00. The descriptor declares both
            // reports. It doesn't declare 0x0E, so the touch-scan write from
            // Wacom's family sequence is left out; the touch interface gets
            // its own 0x0E (Input Mode) below. Both writes confirmed accepted
            // (issue #19).
            seizeUSB: true,
            initSteps: [
                .featureReport([0x0D, 0x00]),
                .featureReport([0x02, 0x02]),
            ],
            touchCompanionPID: 0x03B3,
            // Standard HID Device Mode write, Inputmode = 2, index 0. This
            // descriptor puts Inputmode (usage 0x52) and Device Index (0x53) on
            // `feature:0x0E`, not 0x0C — which carries Contact Count Maximum
            // and is read-only. Confirmed accepted, with multi-touch streaming
            // (issue #19).
            touchCompanionInitSteps: [.featureReport([0x0E, 0x02, 0x00])],
            confidence: .verified, activeWidthMM: 348, activeHeightMM: 198),
        .init(
            // Pen range and pressure: vendor model properties.
            // libwacom wacom-cintiq-pro-24-p.tablet: Width=508 Height=305mm,
            // Touch=false, no [Buttons] section (pen-only variant, no keys).
            //
            // Dimensions are likely wrong, as 0x0351's were: libwacom's 508x305
            // isn't 16:9, and the shared panel suggests 105286 x 59574 over
            // 526.43 x 297.87 mm. Unchanged until a DTK-2420 descriptor confirms
            // the pen-only unit reports the same maxima.
            productID: 0x037C, name: "Cintiq Pro 24 (DTK-2420, pen only)",  // ⚠ groundwork only
            format: .intuosV2, maxX: 105286, maxY: 59574, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 526, activeHeightMM: 298),
        .init(
            // Touch wiring and range: vendor model properties.
            // Dimensions from this unit's HID descriptor (a capture published
            // by another macOS driver project): Logical Maximum 105286 x 59574
            // over 526.43 x 297.87 mm, 200 units/mm and 16:9. libwacom's
            // 508×305mm isn't 16:9 and was about 4% off at the edges. The same
            // descriptor confirms `.intuosV2`, pressure 8191, and the
            // [0x02, 0x02] DATAMODE write.
            //
            // buttonCount 0: this display has no express keys; Wacom ships them
            // on a detachable ExpressKey Remote (0x0331).
            //
            // Report 0x11's four declared bits (usages 0x0981–0x0983, 0x0986)
            // are the lit Touch Keys along the top edge: input source, Wacom
            // Center, on-screen keyboard, display settings, and touch on/off.
            // Five keys, four bits, consistent with firmware handling touch
            // on/off. They aren't express keys and Wacom offers no way to
            // reassign them. `bezelButtonCount` fits by intent but caps at
            // three, and only CintiqV1Decoder emits those buttons, so wiring
            // them is a feature, not a registry value. Without Wacom's driver
            // they do nothing, so binding them would conflict with nothing.
            productID: 0x0351, name: "Cintiq Pro 24 (DTH-2420, touch)",
            format: .intuosV2, maxX: 105286, maxY: 59574, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            touchCompanionPID: 0x0355, confidence: .experimental, activeWidthMM: 526.43, activeHeightMM: 297.87),
        .init(
            // Pen range and pressure: vendor model properties.
            // libwacom wacom-cintiq-22.tablet: Width=483 Height=254mm,
            // Touch=false, no [Buttons] section (pen-only, non-Pro Cintiq 22).
            productID: 0x0391, name: "Cintiq 22 (DTK-2260)",  // ⚠ groundwork only
            format: .intuosV2, maxX: 96012, maxY: 54358, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 480, activeHeightMM: 272),
        .init(
            // Pen range and pressure: vendor model properties.
            // libwacom wacom-dtk-1660e.tablet: Width=356 Height=203mm, no touch,
            // no buttons. First-revision PID; 0x03B0 below is a hardware-revision
            // sibling with identical dimensions (same pattern as Cintiq 16's
            // 0x0390/0x03AE pair already in this registry).
            productID: 0x0396, name: "DTK-1660E",  // ⚠ groundwork only
            format: .intuosV2, maxX: 69632, maxY: 39518, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 348, activeHeightMM: 198),
        .init(
            // Pen range and pressure: vendor model properties.
            // libwacom wacom-dtk-1660e-2.tablet: hardware-revision sibling of
            // 0x0396, identical dimensions.
            productID: 0x03B0, name: "DTK-1660E",  // ⚠ groundwork only
            format: .intuosV2, maxX: 69632, maxY: 39518, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 348, activeHeightMM: 198),
        .init(
            // Pen range and pressure: vendor model properties.
            // libwacom wacom-dtk-168e.tablet: Width=356 Height=203mm, no touch,
            // no buttons.
            productID: 0x03EE, name: "DTK-168E",  // ⚠ groundwork only
            format: .intuosV2, maxX: 69736, maxY: 43884, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 349, activeHeightMM: 219),
        .init(
            // Pen range and pressure: vendor model properties.
            // libwacom wacom-dtk-246e.tablet: Width=533 Height=305mm, no touch,
            // no buttons.
            productID: 0x03EF, name: "DTK-246E",  // ⚠ groundwork only
            format: .intuosV2, maxX: 106170, maxY: 60070, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 531, activeHeightMM: 300),
        .init(
            // Touch wiring and range: vendor model properties.
            // Pen range and pressure: vendor model properties.
            // libwacom wacom-dth-1152.tablet: Width=229 Height=127mm, Touch=true,
            // no [Buttons] section, header note "Stylus does not have an
            // eraser".
            productID: 0x035A, name: "DTH-1152",  // ⚠ groundwork only
            format: .intuosV2, maxX: 22320, maxY: 12555, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: false, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            touchMaxX: 8928, touchMaxY: 5024, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], touchCompanionPID: 0x0368, activeWidthMM: 223, activeHeightMM: 126),
        .init(
            // Touch wiring and range: vendor model properties.
            // Pen range and pressure: vendor model properties.
            // libwacom wacom-dth-2452.tablet: Width=508 Height=305mm, Touch=true,
            // Buttons Right=A;B;C;D (4 express keys).
            productID: 0x037D, name: "DTH-2452",  // ⚠ groundwork only
            format: .intuosV2, maxX: 53104, maxY: 30046, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            touchMaxX: 17568, touchMaxY: 9882, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], touchCompanionPID: 0x037E, activeWidthMM: 531, activeHeightMM: 300),
        .init(
            // Touch wiring and range: vendor model properties.
            // Pen range and pressure: vendor model properties.
            // libwacom wacom-dth-246e.tablet: Width=533 Height=305mm, Touch=true,
            // no [Buttons] section.
            productID: 0x03FF, name: "DTH-246E",  // ⚠ groundwork only
            format: .intuosV2, maxX: 106170, maxY: 60070, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            touchMaxX: 21076, touchMaxY: 11856, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 531, activeHeightMM: 300),
        .init(
            // Pen range and pressure: vendor model properties.
            // libwacom wacom-dtu-1141b.tablet: Width=229 Height=127mm,
            // Touch=false, Buttons Top=A;B;C;D (4 express keys).
            productID: 0x0359, name: "DTU-1141B",  // ⚠ groundwork only
            format: .intuosV2, maxX: 22320, maxY: 12555, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 223, activeHeightMM: 126),
        .init(
            // Pen range and pressure: vendor model properties.
            // libwacom wacom-one.tablet: DeviceMatch usb|056a|03a6;usb|056a|03bd,
            // Width=279 Height=152mm — same physical panel already registered
            // as 0x03A6 "Wacom DTC-133" above (identical dims). 0x03BD is a
            // second PID for the same hardware sold under the "Wacom One"
            // branding; added as its own entry rather than folded into the
            // 0x03A6 spec since productID is this table's primary key.
            productID: 0x03BD, name: "Wacom One (DTC-133)",  // ⚠ groundwork only
            format: .intuosV2, maxX: 29376, maxY: 16524, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 294, activeHeightMM: 165),

        // ── Cintiq Companion / Companion 2 / Companion Hybrid — not added ──────
        // Standalone Windows tablet-PCs (libwacom IntegratedIn=Display;System
        // for 0x030A/0x0325, Display for the Hybrid at 0x0307): a Mac can't
        // attach to one, like the excluded ISDV4 digitizers. That covers their
        // `WACOM_24HDT` touch PIDs too, 0x0309 and 0x030C: reachability, not
        // protocol kinship, decides.

        // ── Wireless dongle ───────────────────────────────────────────────────
        // ACK-40401 RF dongle (PID 0x0084) presents the same HID interfaces as
        // the paired tablet. Report 0x80 carries wireless status (byte[1]
        // bit 0 set while the tablet is linked, clear while it sleeps) and
        // names the paired tablet, whose row then supplies the ranges, so
        // maxX/maxY/maxPressure are 0 here. Report 0x03 holds the receiver's
        // settings: sleep timer in byte 1, ring LED in byte 4.
        .init(
            productID: 0x0084, name: "ACK-40401 Wireless Dongle",
            format: .intuosV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false
        ).withQuirks { $0.answersSerialQuery = false },

        // ── Wireless receiver dongles (HID-based) ─────────────────────────────
        // WL tablets (Intuos4 WL, Intuos5 WL, Intuos Pro gen1 WL) can pair with
        // a USB receiver that presents the paired tablet's report format.
        .init(
            productID: 0x009D, name: "Wireless Receiver (Intuos4/5 WL)",  // ⚠ experimental
            format: .intuosV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])]),
        .init(
            // The kernel names this "ISDv4 9A", a built-in tablet-PC digitizer,
            // not a wireless receiver (that's 0x0084). maxX 0 keeps it
            // name-only.
            productID: 0x009A, name: "Wacom ISDv4 9A (built-in digitizer)",  // ⚠ from kernel
            format: .intuosV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false),

        // ── From OpenTabletDriver ─────────────────────────────────────────────
        // Imported from OTD, absent from input-wacom 4.18. Pen-only;
        // coordinates and pressure from OTD's configs, unverified on hardware.
        .init(
            productID: 0x03CE, name: "Wacom One Pen Display 12 (DTC-121)",  // ⚠ from OTD; name per libwacom
            format: .intuosV2, maxX: 25632, maxY: 14418, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            tiltMaxDegrees: 64.0,  // descriptor: vendor 0x1E tilt [-64,63] degrees
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 279, activeHeightMM: 152),
        .init(
            // Touch init 0x12 = 2: Linux's WACOM_24HDT mode switch
            // (wacom_sys.c). Touch wiring and range: vendor model properties.
            // Finger touch arrives on the separate 0x005E interface, decoded
            // by `Wacom24HDTDecoder`. No capture exists for either interface.
            // buttonCount 18, as on its pen-only sibling 0x00FA above.
            productID: 0x005B, name: "Wacom Cintiq 22HD Touch (DTH-2200)",  // ⚠ from OTD (dims corrected to kernel wacom_features_0x5B)
            format: .cintiqV1, maxX: 95840, maxY: 54260, maxPressure: 2047,
            buttonCount: 18, hasTouchRing: false, hasTouchStrips: true, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            touchMaxX: 4752, touchMaxY: 2673,  // 0x005E descriptor (hid-devices recording)
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], touchCompanionPID: 0x005E, touchCompanionInitSteps: [.featureReport([0x12, 0x02])], confidence: .crossReferenced, activeWidthMM: 483, activeHeightMM: 279),
        // 0x03CF and 0x03F2 are deliberately not rows. They are the USB-C
        // Billboard devices of the DTC121 and Movink 13, which announce
        // DisplayPort Alt Mode and carry no HID interface. Do not re-add
        // from a PID-only sweep.
        .init(
            // Touch wiring and range: vendor model properties.
            productID: 0x03D0, name: "Wacom Cintiq Pro 22 (DTH-227)",  // cross-referenced: linuxwacom + libwacom + OTD
            format: .intuosV2, maxX: 96012, maxY: 54356, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 10, touchMaxX: 19044, touchMaxY: 10712, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 457, activeHeightMM: 254),
        .init(
            // 37400/187 and 21000/105 are both exactly 200 units/mm; see the
            // density note on the M size below.
            //
            // Wacom's pages and a real PTK-470 show 5 ExpressKeys (4 outer + 1
            // center, default "Dial toggle") and one non-pressing dial. M and L
            // double that; libwacom's "8 + 2 dial-press" relabels the same keys.
            //
            // Still open: whether the S's center key is byte 3 bit 0 of the aux
            // report, as on the PTK-870. Only a PTK-470 capture can say.
            productID: 0x03F5, name: "Intuos Pro S gen 3 (PTK-470)",  // cross-referenced: OTD + libwacom (2025 model)
            format: .intuosV3, maxX: 37400, maxY: 21000, maxPressure: 8191,
            buttonCount: 5, hasTouchRing: true, hasDualRings: false, hasMechanicalDial: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 187, activeHeightMM: 105),
        .init(
            // A PTK-870 capture shows 8 express keys and two dials, which the
            // descriptor names "Wacom TouchRing" (see
            // IntuosV3Decoder.decodeAuxReport). The two bits in aux byte [3]
            // are each cluster's center key, not dial presses: the dials only
            // rotate.
            //
            // Dimensions: this family runs at exactly 200 units/mm, so the
            // maxima give 187 x 105 (S), 263 x 148 (M), and 349 x 195 (L). A
            // third-party catalog lists the same, except 264 for M's width;
            // which of that and maxX 52600 is off needs a PTK-670 descriptor.
            // libwacom's advertised areas gave uneven densities on every size.
            productID: 0x03F7, name: "Intuos Pro M gen 3 (PTK-670)",  // cross-referenced: OTD + libwacom (2025 model)
            format: .intuosV3, maxX: 52600, maxY: 29600, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasDualRings: true, hasMechanicalDial: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 263, activeHeightMM: 148),
        .init(
            // 69800/349 and 39000/195 are both exactly 200 units/mm. See the
            // density note on the M size above.
            productID: 0x03F9, name: "Intuos Pro L gen 3 (PTK-870)",  // hardware-verified over USB and Bluetooth
            format: .intuosV3, maxX: 69800, maxY: 39000, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasDualRings: true, hasMechanicalDial: true, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .verified, activeWidthMM: 349, activeHeightMM: 195),
        .init(
            // Pen range and pressure: vendor model properties.
            productID: 0x03E6, name: "Wacom Cintiq 16 gen 3 (DTK-168)",  // ⚠ pen range from vendor model properties only
            format: .intuosV2, maxX: 69736, maxY: 43884, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 349, activeHeightMM: 219),
        .init(
            // Pen range and pressure: vendor model properties.
            productID: 0x040F, name: "Wacom One 14 (DTC-141)",  // ⚠ pen range from vendor model properties only
            format: .intuosV2, maxX: 30931, maxY: 17399, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 309, activeHeightMM: 174),
        // Rows below exist only in vendor model properties:
        // pen range, pressure, and touch range are Wacom's, the rest copies
        // the sibling row above that shares the panel.
        .init(
            productID: 0x03E7, name: "Wacom Cintiq 24 (DTK246)",
            format: .intuosV2, maxX: 106170, maxY: 60070, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 531, activeHeightMM: 300),
        .init(
            productID: 0x03FD, name: "Wacom Cintiq 24 Touch (DTH246)",
            format: .intuosV2, maxX: 106170, maxY: 60070, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            touchMaxX: 21076, touchMaxY: 11856, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 531, activeHeightMM: 300),
        .init(
            productID: 0x0423, name: "Wacom One 14 Touch (DTH142)",
            format: .intuosV2, maxX: 30931, maxY: 17399, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            touchMaxX: 12372, touchMaxY: 6960, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 309, activeHeightMM: 174),
        .init(
            productID: 0x0428, name: "Wacom One 14 Touch (DTH142)",
            format: .intuosV2, maxX: 30931, maxY: 17399, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            touchMaxX: 12372, touchMaxY: 6960, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 309, activeHeightMM: 174),

        // ── Business and signature displays — out of scope ───────────────────
        // The DTU, DTI, and DTK-1651 rows below, plus DTH-1152 (0x035A),
        // DTH-2452 (0x037D), DTU-1141B (0x0359), and DTU-710/1931 in the PL
        // group, are Wacom's business line. They stay recognized and decode
        // where a format is known, but they are not a drawing focus: no
        // further research, testing, or promotion is planned.

        // ── DTUS family (Linux input-wacom DTUS / DTUSX) ──────────────────────
        // Small entry-level pen displays sharing wacom_dtus_irq.  Dimensions
        // and button counts from input-wacom 4.18, decoded by DTUSDecoder.
        // Unverified on hardware. The kernel sends no feature init; [0x02,
        // 0x02] goes out in case some firmware wants it.
        .init(
            productID: 0x0343, name: "Wacom DTK1651",  // ⚠ from kernel
            format: .dtus, maxX: 34816, maxY: 19759, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 356, activeHeightMM: 203),
        .init(
            productID: 0x00FB, name: "Wacom DTU-1031",  // ⚠ from kernel
            format: .dtus, maxX: 22096, maxY: 13960, maxPressure: 511,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            // dimensions: libwacom wacom-dtu-1031.tablet (Width=229, Height=127).
            // Kernel math (22096/100 × 13960/100) gives 221×140 — height is
            // wrong (digitiser maxY over-ranges past the bezel).
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 229, activeHeightMM: 127),
        .init(
            productID: 0x032F, name: "Wacom DTU-1031X",  // ⚠ from kernel
            format: .dtus, maxX: 22672, maxY: 12928, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 229, activeHeightMM: 127),
        .init(
            productID: 0x0336, name: "Wacom DTU-1141",  // ⚠ from kernel
            format: .dtus, maxX: 23672, maxY: 13403, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 229, activeHeightMM: 127),

        // ── DTU family (Linux input-wacom DTU type, wacom_dtu_irq) ────────────
        // Older entry-level pen displays. Single pen report 0x02 (LE16 X/Y,
        // 9-bit pressure). No pad buttons.  Decoded by DTUDecoder.swift.
        // Dimensions and pressure from input-wacom 4.18. Unverified on
        // hardware.
        .init(
            productID: 0x00CE, name: "Wacom DTU-2231",  // ⚠ from kernel
            format: .dtu, maxX: 47864, maxY: 27011, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 483, activeHeightMM: 279),
        .init(
            productID: 0x00F0, name: "Wacom DTU-1631",  // ⚠ from kernel
            format: .dtu, maxX: 34623, maxY: 19553, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 356, activeHeightMM: 203),
        .init(
            // Pen range and pressure: vendor model properties.
            // DTI-520: old fiber-optic interactive pen display (~2001), the
            // oldest Wacom pen display in this registry. libwacom
            // wacom-dti-520.tablet: Width=356 Height=305mm, 10 usable buttons
            // (Top=F;G;H;I;J, Bottom=B;A;D;E;C — libwacom notes an 11th button
            // exists but the two Ctrl keys share one scancode), and "does not
            // appear to support erasers on styli". `.dtu` is a guess, the
            // closest-generation sibling. maxX is the DTU-1631's (0x00F0, same
            // 356mm width), and maxY scales it to 305mm.
            productID: 0x003A, name: "DTI-520",  // ⚠ recognition-only, parser unverified
            format: .dtu, maxX: 6281, maxY: 4761, maxPressure: 511,
            buttonCount: 10, hasTouchRing: false, hasEraser: false,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 314, activeHeightMM: 238),

        // ── Tablet-PC ISDV4 PIDs 0x0090/0x0093 — deliberately not added ────────
        // Built into laptops (libwacom IntegratedIn=Display;System): the ASUS
        // R1E/R1F and the HP Pavilion TX2000/TX2500.

        // ── From wacom-hid-descriptors ────────────────────────────────────────
        // Devices seen in linuxwacom sysinfo dumps
        // (https://github.com/linuxwacom/wacom-hid-descriptors). Parser,
        // maxX/maxY, and pressure depth are guesses from the closest relative,
        // with libwacom dimensions, unless a row says otherwise. Each is
        // `.experimental` until a capture replays cleanly.
        //
        // 21 of the 27 modern pen-display rows match libwacom exactly. The
        // three 13.3" units below (0x0325, 0x034D, 0x0398) don't, and ours are
        // right:
        //
        //   ours      294.6 x 165.1 mm -> 13.30" diagonal, aspect 1.784
        //   libwacom  305   x 178   mm -> 13.90" diagonal, aspect 1.713
        //
        // A 13.3" 16:9 active area computes to 294.4 x 165.6 mm (16:9 = 1.778),
        // so libwacom's figures are rounded outer-case/marketing numbers, not
        // the digitizer's extent — the same trap documented for Wacom's own
        // printed specs. Do not "fix" these rows toward libwacom.
        .init(
            // Touch wiring and range: vendor model properties.
            productID: 0x0325, name: "Wacom Cintiq Companion 2 (DTH-W1310)",  // ⚠ recognition-only (dims from kernel wacom_features_0x325)
            format: .cintiqV1, maxX: 59552, maxY: 33848, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            touchMaxX: 2934, touchMaxY: 1650,  // 0x0326 descriptor (linuxwacom)
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            touchCompanionPID: 0x0326, confidence: .crossReferenced, activeWidthMM: 294, activeHeightMM: 166),
        .init(
            // The Companion 2's touch interface, not a second pen PID: the
            // kernel types it `HID_GENERIC` with `oPid: 0x325`. Name-only. The
            // Companion family is otherwise excluded; 0x0325/0x0326 predate
            // that policy.
            productID: 0x0326, name: "Cintiq Companion 2 touch sensor (pairs 0x0325)",  // ⚠ name-only, no decoder routing
            format: .cintiqV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            hasFingerTouch: false, maxTouchContacts: 0,
            isPenDisplay: false,
            seizeUSB: false),
        .init(
            // Touch wiring and range: vendor model properties.
            // Pen range and pressure: vendor model properties.
            productID: 0x034D, name: "Wacom MobileStudio Pro 13 (DTH-W1320)",  // ⚠ recognition-only; touch is a separate USB device (0x034A)
            format: .intuosV2, maxX: 59552, maxY: 33848, maxPressure: 8191,
            buttonCount: 6, hasTouchRing: true, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10, touchMaxX: 11752, touchMaxY: 6608, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            touchCompanionPID: 0x034A, activeWidthMM: 298, activeHeightMM: 169),
        .init(
            // Touch wiring and range: vendor model properties.
            // Pen range and pressure: vendor model properties.
            productID: 0x034E, name: "Wacom MobileStudio Pro 16 (DTH-W1620)",  // ⚠ recognition-only; touch is a separate USB device (0x034B)
            format: .intuosV2, maxX: 69920, maxY: 39680, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10, touchMaxX: 13824, touchMaxY: 7776, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            touchCompanionPID: 0x034B, activeWidthMM: 350, activeHeightMM: 198),
        .init(
            // Touch wiring and range: vendor model properties.
            // Pen range and pressure: vendor model properties.
            // Matches the vendor pen report 0x10 in linuxwacom/wacom-hid-descriptors.
            productID: 0x0350, name: "Wacom Cintiq Pro 16 (DTH-1620)",
            format: .intuosV2, maxX: 69920, maxY: 39680, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            // touchMaxX/Y from the paired 0x0354 interface's touch descriptor
            // (linuxwacom/wacom-hid-descriptors): 13824 x 7776 on report 0x0C.
            touchMaxX: 13824, touchMaxY: 7776,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            touchCompanionPID: 0x0354, confidence: .experimental, activeWidthMM: 350, activeHeightMM: 198),
        .init(
            // Touch interface of 0x0350, per vendor model properties; routed as its companion.
            // Pen range and pressure: vendor model properties.
            productID: 0x0354, name: "Cintiq Pro 16 Touch sensor (pairs 0x0350)",  // ⚠ recognition-only
            format: .intuosV2, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: false, maxTouchContacts: 0,
            // This PID's touch descriptor (linuxwacom/wacom-hid-descriptors)
            // declares 13824 x 7776 on report 0x0C. Those maxima are all that
            // separate it from the 2021 DTH-167 (0x03B2/0x03B3), at 13768 x
            // 7744; don't "tidy" the two toward a common value.
            touchMaxX: 0, touchMaxY: 0,
            isPenDisplay: false,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 350, activeHeightMM: 198),
        .init(
            // Bluetooth PID of the CTL-6100WL, whose USB side is 0x0378 (and
            // 0x03C7 on the later revision); libwacom groups all four. 216x135
            // mm matches the USB twin and the kernel's units at 100/mm;
            // libwacom's 229x127 is the outer body. Bluetooth decode (report
            // 0x81) is verified on the CTL-4100WL, not this model.
            productID: 0x0379, name: "Wacom Intuos BT M (CTL-6100WL)",
            format: .intuosV2, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            // Touch wiring and range: vendor model properties.
            // Pen range and pressure: vendor model properties.
            productID: 0x0398, name: "Wacom MobileStudio Pro 13 (DTH-W1321)",  // ⚠ recognition-only; touch is a separate USB device (0x039A)
            format: .intuosV2, maxX: 59552, maxY: 33848, maxPressure: 8191,
            buttonCount: 6, hasTouchRing: true, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10, touchMaxX: 11752, touchMaxY: 6608, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            touchCompanionPID: 0x039A, activeWidthMM: 298, activeHeightMM: 169),
        .init(
            // Touch wiring and range: vendor model properties.
            // Pen range and pressure: vendor model properties.
            productID: 0x0399, name: "Wacom MobileStudio Pro 16 (DTH-W1621)",  // ⚠ recognition-only; touch is a separate USB device (0x039B)
            format: .intuosV2, maxX: 69920, maxY: 39680, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10, touchMaxX: 13824, touchMaxY: 7776, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            touchCompanionPID: 0x039B, activeWidthMM: 350, activeHeightMM: 198),
        .init(
            // Touch wiring and range: vendor model properties.
            // Pen range and pressure: vendor model properties.
            productID: 0x03AA, name: "Wacom MobileStudio Pro 16 (DTH-W1620, alt)",  // ⚠ recognition-only; touch is a separate USB device (0x03AC)
            format: .intuosV2, maxX: 69920, maxY: 39680, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10, touchMaxX: 13824, touchMaxY: 7776, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            touchCompanionPID: 0x03AC, activeWidthMM: 350, activeHeightMM: 198),
        .init(
            // Touch wiring and range: vendor model properties.
            // `.intuosV2` and 8191 pressure per the linuxwacom descriptor
            // corpus and a diagnostics dump on OTD PR #4751 (interface 0 sends
            // 1E/11/13). Maxima from the descriptor (77178 x 43762, 5080
            // counts/inch) against Wacom's published 381 x 215.9 mm, which the
            // descriptor's physical maxima match; libwacom's 203 mm height is
            // the outlier.
            productID: 0x03C4, name: "Wacom Cintiq Pro 17 (DTH172)",  // buttonCount 8 per libwacom
            format: .intuosV2, maxX: 77178, maxY: 43762, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 10,
            // touchMaxX/Y from this PID's touch descriptor
            // (linuxwacom/wacom-hid-descriptors): 15276 x 8592 on report 0x0C.
            touchMaxX: 15276, touchMaxY: 8592,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .experimental, activeWidthMM: 381, activeHeightMM: 215.9),
        .init(
            // Touch wiring and range: vendor model properties.
            // Pen range and pressure: vendor model properties.
            // Matches the vendor pen report 0x1E in linuxwacom/wacom-hid-descriptors.
            productID: 0x03CB, name: "Wacom One Pen Display 13 (DTH134)",
            format: .intuosV2, maxX: 29376, maxY: 16524, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            touchMaxX: 11752, touchMaxY: 6608, isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 294, activeHeightMM: 165),
        .init(
            // Touch wiring and range: vendor model properties.
            // Pen range and pressure: vendor model properties.
            // Matches the vendor pen report 0x1E in linuxwacom/wacom-hid-descriptors.
            productID: 0x03EC, name: "Wacom DTH134",
            format: .intuosV2, maxX: 29376, maxY: 16524, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            // touchMaxX/Y from this PID's touch descriptor
            // (linuxwacom/wacom-hid-descriptors): 11752 x 6608 on report 0x0C.
            touchMaxX: 11752, touchMaxY: 6608,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 294, activeHeightMM: 165),
        .init(
            // Pen range and pressure: vendor model properties.
            // Matches the vendor pen report 0x1E in linuxwacom/wacom-hid-descriptors.
            productID: 0x03ED, name: "Wacom DTC121",
            format: .intuosV2, maxX: 25632, maxY: 14418, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            tiltMaxDegrees: 64.0,  // descriptor: vendor 0x1E tilt [-64,63] degrees
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 256, activeHeightMM: 144),
        // ── 0x4900 — deliberately not a row ───────────────────────────────────
        // Its sysinfo dump's device path, `0018:056A:4900`, is BUS_I2C: a
        // laptop's built-in digitizer, not a DTC121 (that's 0x03ED on
        // BUS_USB). Out of scope like the ISDV4 entries. Do not re-add from a
        // PID-only sweep.

        // ── From the kernel's device table ────────────────────────────────────
        // Dimensions and button counts from the wacom_features_0xXX structs.
        // Rows with maxX 0 only name the device: no decoder handles their
        // family, or they aren't digitizers.

        // Decoder-family matches (full entries, ⚠ from kernel unless noted):
        .init(
            // Active area as the Graphire4 6×8 (CTE-640), which shares its
            // maxX/maxY.
            productID: 0x0019, name: "Bamboo1 Medium",  // ⚠ from kernel (graphire family)
            format: .graphire, maxX: 16704, maxY: 12064, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 209, activeHeightMM: 151),
        .init(
            productID: 0x0047, name: "Intuos 2 (6×8, alt)",  // ⚠ from kernel — second XD-0608-U PID
            // Same 6×8 active area as 0x0021 (GD-0608-U) — see the Intuos 1
            // family note for why the coordinate range is doubled.
            format: .intuosV1, maxX: 40640, maxY: 32480, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 203, activeHeightMM: 162),
        .init(
            productID: 0x0063, name: "Volito 2 (2×3)",  // ⚠ from kernel
            format: .graphire, maxX: 3248, maxY: 2320, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced),
        .init(
            productID: 0x0064, name: "PenPartner2",  // ⚠ from kernel — sibling of PenStation2 0x0061
            format: .graphire, maxX: 3250, maxY: 2320, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced),
        .init(
            // Active area 479.2×271.3mm per Wacom's DTK-2241/DTH-2242 booklet,
            // matching the kernel's maxX/maxY at 200 lpmm.
            productID: 0x0057, name: "Cintiq 22 (DTK-2241)",  // ⚠ from kernel (DTK type, 6 keys)
            format: .cintiqV1, maxX: 95840, maxY: 54260, maxPressure: 2047,
            buttonCount: 6, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 479, activeHeightMM: 271),
        .init(
            // Touch init 0x12 = 2: Linux's WACOM_24HDT mode switch (wacom_sys.c).
            // Touch wiring and range: vendor model properties.
            // Active area as 0x0057 above (same panel).
            //
            // Finger touch arrives on the separate 0x005D interface, decoded
            // by `Wacom24HDTDecoder`. No capture exists for either interface.
            productID: 0x0059, name: "Cintiq 22 Touch (DTH-2242)",  // ⚠ from kernel (DTK type, 6 keys)
            format: .cintiqV1, maxX: 95840, maxY: 54260, maxPressure: 2047,
            buttonCount: 6, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], touchCompanionPID: 0x005D, touchCompanionInitSteps: [.featureReport([0x12, 0x02])], confidence: .crossReferenced, activeWidthMM: 479, activeHeightMM: 271),
        .init(
            // Active area 433.4×270.9mm per the Cintiq 20WSX manual, matching
            // the kernel's maxX/maxY at 200 lpmm; its 1024 pressure levels
            // match too.
            productID: 0x00C5, name: "Cintiq 20WSX (DTZ-2000W)",  // ⚠ from kernel (WACOM_BEE type)
            format: .cintiqV1, maxX: 86680, maxY: 54180, maxPressure: 1023,
            buttonCount: 10, hasTouchRing: false, hasTouchStrips: true, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 433, activeHeightMM: 271),
        .init(
            // Onboard bezel panel has its own 3 buttons, separate from the
            // ExpressKey Remote accessory (0x0331) — decoded by
            // `CintiqV1Decoder.decodeCintiqPad` (byte[2] bits 0-2, confirmed by
            // capture). Active area 596.7×335.6mm per Wacom's DTK/DTH-2700
            // booklet, for pen and touch alike.
            //
            // Don't "fix" toward libwacom's 610x305 (aspect 2.00, impossible
            // for 16:9) or OTD's config's 600.7x339; OTD's own runtime log on
            // real hardware reports 596.7x335.6.
            productID: 0x032A, name: "Cintiq 27QHD (DTK-2700)",  // ⚠ from kernel (WACOM_27QHD type)
            format: .cintiqV1, maxX: 120140, maxY: 67920, maxPressure: 2047,
            buttonCount: 3, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced, activeWidthMM: 597, activeHeightMM: 336),
        .init(
            // Pen interface of the touch model; finger touch arrives on the
            // separate 0x032C interface.
            //
            // 0x032C sends report 0x88, a standard HID Digitizer touch screen
            // collection, decoded from its descriptor by `PrecisionTouchDecoder`,
            // not the kernel's WACOM_27QHDT layout. maxTouchContacts
            // 10 is an upper bound: 0x88 carries one contact, but the same
            // descriptor declares a 10-contact report 0x81. Active area as
            // 0x032A above.
            //
            // `touchCompanionPID` joins the 0x032C sensor to this spec; on its
            // own name-only row it decoded nothing. touchMaxX/Y come from the
            // sensor's descriptor in a submitted capture, exactly 16:9.
            productID: 0x032B, name: "Cintiq 27QHD Touch (DTH-2700)",  // ⚠ from kernel
            format: .cintiqV1, maxX: 120140, maxY: 67920, maxPressure: 2047,
            buttonCount: 3, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            touchMaxX: 15360, touchMaxY: 8640,
            isPenDisplay: true,
            // Pen report 0x10 is declared here and has never once arrived, in
            // any of seven captures, while report 0x11 (express keys) decodes
            // fine and DATAMODE itself reports success. The cause is still
            // unknown. The scan-enable startup sequence was *ruled out* here:
            // this pen interface declares neither 0x14 nor 0x0E, which that
            // sequence writes. The DTH-167 (0x03B2) does carry it — that row
            // is not a precedent for this one.
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            touchCompanionPID: 0x032C,
            // Standard HID digitizer Device Mode write: report 0x83 declares
            // Inputmode (Digitizer usage 0x52) then Device Index (0x53), so
            // this is Inputmode = 2, index 0. Matches Linux's dedicated
            // WACOM_27QHDT branch in `wacom_query_tablet_data`, which calls
            // `wacom_set_device_mode(hdev, 131, 3, 2)` — report 131 = 0x83,
            // 3-byte buffer, mode 2.
            //
            // The sensor talks without it, single-contact on 0x88; the write
            // unlocks the 10-contact 0x81 report. Wacom's manual describes the
            // same split: without the driver, "basic touch movement will be
            // recognized, but other actions and gestures will not".
            touchCompanionInitSteps: [.featureReport([0x83, 0x02, 0x00])],
            confidence: .verified, activeWidthMM: 597, activeHeightMM: 336),
        .init(
            // Touch init 0x12 = 2: Linux's WACOM_24HDT mode switch (wacom_sys.c).
            // Touch wiring and range: vendor model properties.
            // Pen interface; finger touch arrives on the separate 0x0335
            // interface, decoded by `Wacom24HDTDecoder`; touchMaxX/Y come from a
            // field capture of that sensor's descriptor. Same pen active area
            // as 0x0304 (DTK-1300) per Wacom's booklet.
            // `.intuosV1`, not `.cintiqV1`: a diagnostics dump on OTD PR #4822
            // lists report IDs 01/10/11/C0, and only IntuosV1Decoder reads
            // express keys from 0x11.
            productID: 0x0333, name: "Cintiq 13HD Touch (DTH-1300)",  // dims kernel (WACOM_13HD type) + OTD
            format: .intuosV1, maxX: 59552, maxY: 33848, maxPressure: 2047,
            buttonCount: 9, hasTouchRing: false, hasEraser: true, tiltMaxDegrees: 64.0,
            hasFingerTouch: true, maxTouchContacts: 10,
            touchMaxX: 2937, touchMaxY: 1652,  // 0x0335 descriptor (field capture)
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])],
            touchCompanionPID: 0x0335, touchCompanionInitSteps: [.featureReport([0x12, 0x02])], confidence: .crossReferenced, activeWidthMM: 299, activeHeightMM: 171),

        // PL report family (wacom_pl_irq), decoded by WacomPLDecoder; see its
        // header for the pressure arithmetic. No mode-switch handshake.
        //
        // The PL-800 (0x0035) is `.crossReferenced`: OpenTabletDriver supports
        // it, with a published diagnostic confirming the `[0x02, 0x02]` init.
        // The other seven share the kernel type but no tested implementation,
        // so they stay `.experimental`.
        //
        // hasEraser on all eight: the kernel's eraser logic doesn't vary by
        // model.
        //
        // The DTU-710 and DTU-1931 are business displays, left name-only
        // below.
        .init(
            productID: 0x0030, name: "PL400",
            format: .pl, maxX: 5408, maxY: 4056, maxPressure: 255,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true, seizeUSB: true,
            initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced),
        .init(
            productID: 0x0031, name: "PL500",
            format: .pl, maxX: 6144, maxY: 4608, maxPressure: 255,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true, seizeUSB: true,
            initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced),
        .init(
            productID: 0x0032, name: "PL600",
            format: .pl, maxX: 6126, maxY: 4604, maxPressure: 255,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true, seizeUSB: true,
            initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced),
        .init(
            productID: 0x0033, name: "PL600SX",
            format: .pl, maxX: 6260, maxY: 5016, maxPressure: 255,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true, seizeUSB: true,
            initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced),
        .init(
            // PL-550 = Cintiq 15X. A capture here would show whether the
            // PL-800's init and eraser logic carry over to a sibling.
            productID: 0x0034, name: "PL550 (Cintiq 15X)",
            format: .pl, maxX: 6144, maxY: 4608, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true, seizeUSB: true,
            initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced),
        .init(
            // PL-800 = Cintiq 18SX. OpenTabletDriver supports it on hardware
            // (dimensions, pressure, and eraser/button 2), agreeing with the
            // kernel; its published diagnostic shows 8-byte input report 0x02
            // and feature init "02 02". Not verified here.
            productID: 0x0035, name: "PL800 (Cintiq 18SX)",
            format: .pl, maxX: 7220, maxY: 5780, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true, seizeUSB: true,
            initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced),
        .init(
            productID: 0x0037, name: "PL700",
            format: .pl, maxX: 6758, maxY: 5406, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true, seizeUSB: true,
            initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced),
        .init(
            productID: 0x0038, name: "PL510",
            format: .pl, maxX: 6282, maxY: 4762, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true, seizeUSB: true,
            initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced),
        .init(
            // Pen range and pressure: vendor model properties.
            productID: 0x0039, name: "DTU-710",  // ⚠ name-only; kernel: 34080×27660×511 (PL)
            format: .pl, maxX: 34080, maxY: 27660, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true, seizeUSB: false),
        .init(
            // The PL family, like the eight rows above. Per the kernel's
            // wacom_features_0xC0/0xC2/0xC4, 0x00C0 is the DTF-720 and 0x00C4
            // the DTF-521, despite some `usb.ids` editions. `.experimental`:
            // nothing has tested this trio.
            productID: 0x00C0, name: "DTF-720",
            format: .pl, maxX: 6858, maxY: 5506, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true, seizeUSB: true,
            initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced),
        .init(
            // Same protocol and kernel dimensions as 0x00C0 (DTF-720);
            // presumably a regional revision.
            productID: 0x00C2, name: "DTF-720a",
            format: .pl, maxX: 6858, maxY: 5506, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true, seizeUSB: true,
            initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced),
        .init(
            productID: 0x00C4, name: "DTF-521",
            format: .pl, maxX: 6282, maxY: 4762, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true, seizeUSB: true,
            initSteps: [.featureReport([0x02, 0x02])], confidence: .crossReferenced),
        .init(
            // Pen range and pressure: vendor model properties.
            productID: 0x00C7, name: "DTU-1931",  // ⚠ name-only; kernel: 37832×30305×511 (PL)
            format: .pl, maxX: 37832, maxY: 30305, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true, seizeUSB: false),

        // Touch interfaces of pen displays listed above.
        //
        // No touch reports have been captured from these sensors. 0x00F6, 0x005E,
        // 0x005D, and 0x0335 route to `Wacom24HDTDecoder` by product ID (see
        // `DeviceDecoder.fixedLayoutTouch`), ported from the kernel and tested
        // only on synthetic bytes. Keep them `.experimental`, and add no PID
        // to that list without a capture. The rest decode from their own
        // descriptors. `touchMaxX`/`touchMaxY` stay 0: a sensor's coordinate
        // space needn't match its panel's pen space, as the CTH-690 showed.
        .init(
            // An independent study of this PID (M. McGuffin,
            // michaelmcguffin.com/code/cintiq/) found the same layout in real
            // traffic and reports maxima of 5184 x 3240. Not a replayable
            // capture, so touchMaxX/Y stay 0; a future capture can check it.
            productID: 0x00F6, name: "Cintiq 24HD Touch sensor (pairs 0x00F8)",  // ⚠ name-only, decoder routed by PID, unverified
            format: .cintiqV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false, tiltMaxDegrees: 64.0,
            seizeUSB: false),
        .init(
            productID: 0x005E, name: "Cintiq 22HD Touch sensor (pairs 0x005B)",  // ⚠ name-only, decoder routed by PID, unverified
            format: .cintiqV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false, tiltMaxDegrees: 64.0,
            seizeUSB: false),
        .init(
            // Sends report 0x88, a standard HID Digitizer touch screen
            // collection, decoded from its descriptor by
            // `PrecisionTouchDecoder`; see the 0x032B row above.
            productID: 0x032C, name: "Cintiq 27QHD Touch sensor (pairs 0x032B)",  // ⚠ name-only, decoder routed generically from its own descriptor
            format: .cintiqV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false, tiltMaxDegrees: 64.0,
            seizeUSB: false, confidence: .verified),
        .init(
            // Emits report 0x0C: a Digitizer Touch Screen collection with five
            // finger slots, plus Contact Count and Scan Time, decoded by
            // `PrecisionTouchDecoder`. `PrecisionTouchLayout.derive` on this
            // capture's descriptor yields the 5-slot 0x0C layout at 13768 x
            // 7744 and rejects report 0x1F as single-contact.
            productID: 0x03B3, name: "Cintiq Pro 16 Touch sensor (pairs 0x03B2)",  // ⚠ name-only, decoder routed generically from its own descriptor
            format: .intuosV2, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, confidence: .verified),
        .init(
            productID: 0x005D, name: "Cintiq 22 Touch sensor (pairs 0x0059)",  // ⚠ name-only, decoder routed by PID, unverified
            format: .cintiqV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false, tiltMaxDegrees: 64.0,
            seizeUSB: false),
        .init(
            productID: 0x0335, name: "Cintiq 13HD Touch sensor (pairs 0x0333)",  // ⚠ name-only, decoder routed by PID, unverified
            format: .cintiqV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false, tiltMaxDegrees: 64.0,
            seizeUSB: false),

        // Name-only: accessories and special modes.
        .init(
            // Standalone wireless button/ring accessory, no digitizer, decoded
            // by `ExpressKeyRemoteDecoder`. The kernel's `wacom_remote_irq`
            // agrees with a bit mapping worked out from five labelled
            // recordings in the MIT-licensed `whot/wacom-recordings` (facts
            // recorded, no fixtures committed). Byte 11 bits 6–7 follow the
            // kernel: the active ring mode. `.crossReferenced`: no hardware
            // here.
            // buttonCount 17 counts keys only; the ring's center button is
            // its mode switch. ringSlotCount 3 matches the remote's three
            // mode LEDs.
            productID: 0x0331, name: "ExpressKey Remote (EKR-100)",
            format: .expressKeyRemote, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 17, hasTouchRing: true, ringSlotCount: 3, hasEraser: false, tiltMaxDegrees: 64.0,
            seizeUSB: false, confidence: .verified),
        .init(
            // Firmware-update (DFU) mode. Never attach a driver to this.
            productID: 0x0094, name: "Wacom Bootloader (DFU mode)",  // ⚠ name-only
            format: .intuosV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false, tiltMaxDegrees: 64.0,
            seizeUSB: false),

        // ── Legacy Bluetooth devices (serial-port based, out-of-scope) ─────────
        // CTE-630BT (Graphire4 Bluetooth, PID 0x0081) and XD-0608-BT (Intuos2
        // Bluetooth, PID 0x0CA) use RFCOMM/SPP (serial port over Bluetooth)
        // instead of the HID Profile. They do not enumerate as IOHIDDevices;
        // instead they appear as /dev/cu.* serial ports. These require a
        // completely different driver architecture (serial I/O, not IOHIDManager).
        // Not implemented.
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
        0x0393: 0x0392,  // BT Classic
        0x03DD: 0x03DC,  // BT Classic (hardware-revision variant)
        0x03F6: 0x03F5,  // Intuos Pro S gen 3 Bluetooth (libwacom DeviceMatch)
        0x03F8: 0x03F7,  // Intuos Pro M gen 3 Bluetooth (libwacom DeviceMatch)
        0x03FA: 0x03F9,  // Intuos Pro L gen 3 Bluetooth (libwacom DeviceMatch)
        0x0401: 0x03F9,  // Intuos Pro L gen 3 USB hardware-revision variant (libwacom DeviceMatch)
        0x042D: 0x03F5,  // Intuos Pro S gen 3 USB revision (vendor model properties)
        0x042E: 0x03F7,  // Intuos Pro M gen 3 USB revision (vendor model properties)
        0x042F: 0x03F9,  // Intuos Pro L gen 3 USB revision (vendor model properties)

        // Intuos Pro M (PTH-660 family)
        0x0360: 0x0357,  // BT Classic

        // Intuos Pro L (PTH-860 family)
        0x0361: 0x0358,  // BT Classic

        // No 0x0359/0x035A: libwacom assigns them to the DTU-1141B and
        // DTH-1152. PTH-660/860 wireless is Bluetooth Classic, not a dongle.

        // Intuos4 WL (PTK-540WL): kernel BT_DEVICE_WACOM(0xBD) is the
        // Bluetooth PID of the USB 0x00BC entry. Decode over BT untested.
        0x00BD: 0x00BC,

        // Intuos BT S/M (CTL-4100WL/6100WL), two hardware generations, each
        // pairing its own USB and Bluetooth PIDs (libwacom DeviceMatch):
        // 0x0376/0x0377 and 0x03C5/0x03C6 (S), 0x0378/0x0379 and
        // 0x03C7/0x03C8 (M). Pairing across generations gave one tablet a
        // second identity, window, and settings over Bluetooth.
        //
        // All four of 0x377/0x379/0x3C6/0x3C8 are kernel type `INTUOSHT3_BT`
        // and send report `0x81`, decoded by `decodeIntuosHT3BTFrames`.
        0x0377: 0x0376,
        0x0379: 0x0378,
        0x03C6: 0x03C5,
        0x03C8: 0x03C7,
    ]

    // MARK: Lookups

    /// PID-keyed index over `knownDevices`, in declaration order within each
    /// PID, so the first match wins.
    private static let specsByPID: [Int: [TabletSpec]] =
        Dictionary(grouping: knownDevices, by: \.productID)

    /// PIDs some other row claims as its touch sensor (`touchCompanionPID`).
    /// Lets the routing layer recognise a sensor interface before the tablet
    /// that claims it has enumerated — arrival order between the two is not
    /// guaranteed.
    public static let touchCompanionPIDs: Set<Int> =
        Set(knownDevices.compactMap(\.touchCompanionPID))

    /// Returns the spec for `productID`, or nil if unrecognised.
    public static func spec(for productID: Int) -> TabletSpec? {
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
    /// Wacom has no PID collisions, so this matches `spec(for:)` for every
    /// current device.
    public static func spec(forProductID productID: Int, productString: String?) -> TabletSpec? {
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

    /// True when a real decoder exists for this device. Every parser family
    /// has one, so this is true for every registry row.
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

extension TabletSpec {
    /// The decoder's view of this device: ranges and capabilities copied into
    /// the ``DigitizerSpec`` a decoder reads against. Use this rather
    /// than building one field by field, so a new capability can't be missed.
    public var digitizerSpec: DigitizerSpec {
        var spec = DigitizerSpec(
            maxX: maxX,
            maxY: maxY,
            maxPressure: maxPressure,
            buttonCount: buttonCount,
            hasTilt: hasTilt,
            hasDualRings: hasDualRings,
            bezelButtonCount: bezelButtonCount,
            isPenDisplay: isPenDisplay,
            ringSlotCount: ringSlotCount,
            hasFingerTouch: hasFingerTouch,
            maxTouchContacts: maxTouchContacts,
            tiltMaxDegrees: tiltMaxDegrees)
        spec.hasTouchStrips = hasTouchStrips
        if format == .cintiqV1 { spec.cintiqPadLayout = CintiqPadLayout(productID: productID) }
        return spec
    }
}
