// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 TabletKit contributors
// SPDX-License-Identifier: MPL-2.0

import Foundation

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
///     millimeters. Ours match the kernel.
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
    /// True if this model has capacitive touch strips (Intuos3, older Cintiqs).
    public let hasTouchStrips: Bool
    /// How many touch strips the model has: two on most, one on the small
    /// Intuos3 models.
    public internal(set) var touchStripCount: Int
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
    /// Active-area width in millimeters, or nil if unknown. Lets the mapping
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
    /// Active-area height in millimeters.  See `activeWidthMM`.
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
        self.touchStripCount = hasTouchStrips ? 2 : 0
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
        if format == .intuosV2 { spec.intuosV2PadLayout = IntuosV2PadLayout(productID: productID) }
        spec.isGraphireBluetooth = format == .graphire && productID == 0x0081
        spec.penEdgeInsets = PenEdgeInsets(productID: productID)
        return spec
    }

    /// A copy with a single touch strip, read as the first.
    func withOneTouchStrip() -> TabletSpec {
        var spec = self
        spec.touchStripCount = 1
        return spec
    }
}
