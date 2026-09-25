import XCTest
@testable import TabletKit

final class WacomDeviceRegistryTests: XCTestCase {

    // MARK: - spec(forProductID:productString:) precedence

    func testStringMatchWinsOverCatchAll() {
        let spec = WacomDeviceRegistry.spec(
            forProductID: 0x0357, productString: "Intuos Pro M (PTH-660)")
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.productID, 0x0357)
    }

    func testFallsBackToCatchAllWhenStringDoesNotMatch() {
        // No real Wacom spec uses productStringMatch today, so any productString
        // should still resolve to the same catch-all entry.
        let withString = WacomDeviceRegistry.spec(
            forProductID: 0x0357, productString: "totally unrelated")
        let bare = WacomDeviceRegistry.spec(for: 0x0357)
        XCTAssertEqual(withString?.productID, bare?.productID)
        XCTAssertEqual(withString?.name, bare?.name)
    }

    func testReturnsNilForUnknownPID() {
        XCTAssertNil(WacomDeviceRegistry.spec(forProductID: 0xFFFF, productString: nil))
        XCTAssertNil(WacomDeviceRegistry.spec(forProductID: 0xFFFF, productString: "anything"))
    }

    func testNilProductStringBehavesLikeLegacyLookup() {
        let viaOverload = WacomDeviceRegistry.spec(forProductID: 0x0358, productString: nil)
        let viaLegacy = WacomDeviceRegistry.spec(for: 0x0358)
        XCTAssertEqual(viaOverload?.productID, viaLegacy?.productID)
    }

    // MARK: - lpi derivation

    func testLPIIsNilWhenDimensionsMissing() {
        // PenPartner (0x0003) is one of the older entries we don't have
        // confident mm dimensions for — the LPI standard for the PenPartner
        // era isn't documented and our maxX/maxY come from kernel sources
        // without a paired physical-dimension reference.  Keep this canary
        // pointed at an entry that's intentionally nil so a future backfill
        // pass that touches it has to think about it.
        let s = WacomDeviceRegistry.spec(for: 0x0003)
        XCTAssertNotNil(s)
        XCTAssertNil(s?.activeWidthMM,
                     "If you just backfilled 0x0003, point this canary at "
                     + "another intentionally-nil PID (or delete the test).")
        XCTAssertNil(s?.lpi)
    }

    func testLPIDerivesFromVerifiedHardware() {
        // PTH-860: 62200 / 311.0 mm × 25.4 ≈ 5080 LPI on both axes —
        // matches the published Wacom Pro 2 sensor spec.
        guard let spec = WacomDeviceRegistry.spec(for: 0x0358),
              let lpi = spec.lpi else {
            return XCTFail("PTH-860 spec missing mm dimensions")
        }
        XCTAssertEqual(lpi.x, 5080, accuracy: 5)
        XCTAssertEqual(lpi.y, 5080, accuracy: 5)
    }

    func testLPIDerivesForCintiq24HD() {
        // DTK-2400: active area 519×324 mm; LPI lands in the Wacom Pro sensor
        // range (~5000–5200) on both axes.  Looser tolerance than PTH-860
        // because the Cintiq sensor is not exactly 5080 LPI.
        guard let spec = WacomDeviceRegistry.spec(for: 0x00F4),
              let lpi = spec.lpi else {
            return XCTFail("DTK-2400 spec missing mm dimensions")
        }
        XCTAssertEqual(lpi.x, 5113, accuracy: 25)
        XCTAssertEqual(lpi.y, 5143, accuracy: 25)
    }

    // MARK: - canonical PID normalization (sanity check on the file)

    /// PTH-660's touch maxima are descriptor-confirmed, not estimated: the
    /// device's own touch report declares Logical Maximum 8960 on X and 5920
    /// on Y. Pinned because the numbers originally came from a pen/5 estimate
    /// that happened to be exactly right, and nothing in the values themselves
    /// distinguishes a confirmed figure from a guess.
    func testPTH660TouchMaximaMatchDeviceDescriptor() throws {
        let spec = try XCTUnwrap(WacomDeviceRegistry.spec(for: 0x0357))

        XCTAssertEqual(spec.touchMaxX, 8960)
        XCTAssertEqual(spec.touchMaxY, 5920)
        XCTAssertTrue(spec.hasFingerTouch)
        XCTAssertEqual(spec.maxTouchContacts, 5)
    }

    func testCanonicalPIDCollapsesBTToUSBForPTH660() {
        XCTAssertEqual(WacomDeviceRegistry.canonicalProductID(for: 0x0360), 0x0357)
        // 0x0359 is NOT a PTH-660 transport variant: it previously appeared
        // here as an unsourced "wireless dongle" guess, unlike every other
        // canonicalPIDMap entry, which cites a kernel macro or libwacom
        // DeviceMatch. Removed 2026-07-17 in favor of libwacom's own,
        // specifically-sourced identification of 0x0359 as the DTU-1141B.
        XCTAssertEqual(WacomDeviceRegistry.canonicalProductID(for: 0x0359), 0x0359)
    }

    /// Every canonical-map target must resolve to a registry entry; a dangling
    /// target silently routes that transport variant to the fallback driver.
    /// (Regression guard for the former 0x035F → 0x0356 mapping, whose target
    /// never existed.)
    func testCanonicalPIDMapTargetsExist() {
        for (variant, canonical) in WacomDeviceRegistry.canonicalPIDMap {
            XCTAssertNotNil(
                WacomDeviceRegistry.spec(for: canonical),
                "canonicalPIDMap[0x\(String(variant, radix: 16))] → 0x\(String(canonical, radix: 16)) has no registry entry")
        }
    }

    // MARK: - registry structural invariants

    /// A PID may appear more than once only when `productStringMatch`
    /// disambiguates the entries: distinct non-nil match strings, and at most
    /// one catch-all (nil) entry. Any other repeat is a shadowed duplicate —
    /// `spec(forProductID:productString:)` silently returns just one of them,
    /// so the others are dead weight that drifts out of sync. (Regression guard
    /// for the two 0x00D5 "Bamboo Pen" entries, both catch-alls, one of which
    /// was never reachable.)
    func testNoShadowedDuplicateProductIDs() {
        let byPID = Dictionary(grouping: WacomDeviceRegistry.knownDevices, by: \.productID)
        for (pid, group) in byPID where group.count > 1 {
            let catchAlls = group.filter { $0.productStringMatch == nil }
            let named = group.compactMap { $0.productStringMatch }
            XCTAssertLessThanOrEqual(
                catchAlls.count, 1,
                "PID 0x\(String(pid, radix: 16)) has \(catchAlls.count) catch-all entries; "
                + "only one entry per PID may omit productStringMatch")
            XCTAssertEqual(
                named.count, Set(named).count,
                "PID 0x\(String(pid, radix: 16)) has duplicate productStringMatch values; "
                + "each disambiguated entry needs a distinct match string")
        }
    }

    /// Hardware whose dimensions we claim to have confirmed (`.verified`) must
    /// imply the same LPI on both axes to within the auto-fill tolerance — a
    /// verified entry disagreeing with itself means the coordinate range and
    /// the mm size describe different devices. Older, non-verified entries
    /// (Graphire/Volito) are legitimately anisotropic and only guarded against
    /// gross error. Mirrors the 8% / 25% thresholds tools/registry_lib.py uses.
    func testDimensionsImplyConsistentLPI() {
        let verifiedTolerance = 0.08
        let grossTolerance = 0.25
        for spec in WacomDeviceRegistry.knownDevices {
            guard let lpi = spec.lpi, min(lpi.x, lpi.y) > 0 else { continue }
            let disagreement = abs(lpi.x - lpi.y) / min(lpi.x, lpi.y)
            let label = "0x\(String(spec.productID, radix: 16)) \(spec.name): "
                + "X \(Int(lpi.x)) lpi vs Y \(Int(lpi.y)) lpi"
            XCTAssertLessThan(disagreement, grossTolerance,
                              "\(label) — grossly inconsistent, likely a data error")
            if spec.confidence == .verified {
                XCTAssertLessThan(disagreement, verifiedTolerance,
                                  "\(label) — verified entry should be near-isotropic")
            }
        }
    }

    // MARK: - DeviceFamily classification

    /// Intuos 1/2 get their own family. Until 2026-09-22 `family` sniffed the
    /// name string, and these nine names match none of its tokens, so they
    /// fell through to `.intuosProGen1` — hardware two generations later.
    func testIntuos1And2ClassifyAsOwnFamily() {
        for pid in Array(0x0020...0x0024) + Array(0x0041...0x0045) {
            let spec = WacomDeviceRegistry.spec(for: pid)!
            XCTAssertEqual(spec.family, .intuos1And2,
                           "0x\(String(pid, radix: 16)) \(spec.name) misfiled")
        }
    }

    /// `IntuosV1Decoder` synthesizes a tool code when a device enters
    /// proximity without a 0xC2 tool-change packet, and those codes hit
    /// `emitToolCompatibility` like real ones. Each must therefore be
    /// compatible with every family that can synthesize it, or working
    /// hardware logs "not fully supported" on every pen entry — the way
    /// adding a family case without updating these lists regresses.
    func testSynthesizedFallbackToolCodesAreSupportedOnTheirFamilies() {
        // The intuosV1 parser's fallback codes, from decodeUSBPen.
        let fallbackCodes: [UInt16] = [0x0802, 0x080A, 0x0016, 0x0806]
        let intuosV1Families = Set(
            WacomDeviceRegistry.knownDevices
                .filter { $0.parser == .intuosV1 }
                .map(\.family))

        for code in fallbackCodes {
            guard let spec = WacomToolCatalog.spec(forToolCodeRaw: code) else {
                XCTFail("fallback code 0x\(String(code, radix: 16)) is not catalogued")
                continue
            }
            // Pen codes are synthesized for every device the parser serves,
            // so they must cover all of its families. The mouse codes are
            // narrower: 0x0016 comes from subtype 0x08 (the "Intuos 1–3
            // cursor" path, so the Intuos 1/2 puck lands there), while
            // 0x0806 is subtype 0x06 — the KC-100 cordless mouse, an
            // Intuos 3-and-later accessory that no Intuos 1/2 ever shipped
            // with. Asserting 0x0806 on `.intuos1And2` would be asserting
            // hardware that doesn't exist.
            let required: Set<DeviceFamily>
            switch code {
            case 0x0802, 0x080A: required = intuosV1Families
            case 0x0016: required = [.intuos1And2, .intuos3]
            default: required = []
            }
            for family in required {
                XCTAssertTrue(
                    spec.isSupported(onFamily: family),
                    "0x\(String(code, radix: 16)) \(spec.name) is synthesized on "
                        + "\(family.rawValue) but reports unsupported there")
            }
        }
    }

    /// The Intuos4/5 accessory line carries forward to every Intuos Pro
    /// generation — a PTH-850 ships with the 0x1802 Grip Pen. These codes
    /// arrive in a real 0xC2 tool-change packet rather than being synthesized,
    /// so the fallback test above never covered them: a stock pen reported
    /// "not fully supported on intuosProGen1. Missing: pressure, tilt" in
    /// every capture, and `capabilities` zeroed its maxPressure.
    func testIntuos4AccessoriesAreSupportedOnIntuosProGenerations() {
        let accessories: [UInt16] = [
            0x1802, 0x180A,  // Grip Pen + eraser
            0x1804, 0x180C,  // Art Pen + eraser
            0x0812, 0x081A,  // Inking Pen + eraser
            0x0902, 0x090A,  // Airbrush + eraser
            0x0806,  // Intuos Mouse
        ]
        let proFamilies: [DeviceFamily] = [.intuosProGen1, .intuosProGen2, .intuosProGen3]
        for code in accessories {
            guard let spec = WacomToolCatalog.spec(forToolCodeRaw: code) else {
                XCTFail("0x\(String(code, radix: 16)) is not catalogued")
                continue
            }
            for family in proFamilies {
                XCTAssertTrue(
                    spec.isSupported(onFamily: family),
                    "0x\(String(code, radix: 16)) \(spec.name) reports unsupported on "
                        + family.rawValue)
                // Unsupported clears every capability flag, which is the
                // damaging part — the warning string is only the symptom.
                let caps = spec.capabilities(forFamily: family)
                XCTAssertEqual(
                    caps.hasTilt, spec.hasTilt,
                    "0x\(String(code, radix: 16)) \(spec.name) loses tilt on " + family.rawValue)
                if let declared = spec.maxPressure {
                    XCTAssertEqual(
                        caps.maxPressure, declared,
                        "0x\(String(code, radix: 16)) \(spec.name) loses pressure on "
                            + family.rawValue)
                }
            }
        }
    }

    // MARK: - defaultPressureThreshold

    /// The Intuos 1/2 family carries a non-zero factory dead zone because its
    /// hover baseline sits above the shared hardware-noise floor. Values are
    /// from a GD-0608-U capture 2026-09-22 (Cyzor/tablet-driver#4).
    func testIntuos1And2CarryPressureDeadZone() {
        let family = Array(0x0020...0x0024) + Array(0x0041...0x0045)
        for pid in family {
            guard let spec = WacomDeviceRegistry.spec(for: pid) else {
                XCTFail("0x\(String(pid, radix: 16)) missing from registry")
                continue
            }
            XCTAssertEqual(spec.defaultPressureThreshold, 0.015, accuracy: 1e-9,
                           "\(spec.name) should carry the family dead zone")
        }
    }

    /// The dead zone has to clear the measured hover noise (10/1023) while
    /// staying well under a deliberate light touch — a threshold that swallowed
    /// real strokes would trade one bug for a worse one.
    func testIntuos1DeadZoneClearsMeasuredHoverNoise() {
        let spec = WacomDeviceRegistry.spec(for: 0x0021)!
        let measuredHoverNoise = 10.0 / 1023.0  // ≈ 0.0098, capture maximum
        XCTAssertGreaterThan(spec.defaultPressureThreshold, measuredHoverNoise,
                             "dead zone must sit above the noise it exists to reject")
        XCTAssertLessThan(spec.defaultPressureThreshold, 0.05,
                          "dead zone must stay far below a deliberate touch")
    }

    /// Every other device keeps 0 — the shared floor already covers them, and
    /// a blanket dead zone would quietly reduce everyone's pressure range.
    func testOtherDevicesHaveNoPressureDeadZone() {
        for spec in WacomDeviceRegistry.knownDevices {
            let isIntuos1Or2 =
                (0x0020...0x0024).contains(spec.productID)
                || (0x0041...0x0045).contains(spec.productID)
            guard !isIntuos1Or2 else { continue }
            XCTAssertEqual(spec.defaultPressureThreshold, 0.0,
                           "0x\(String(spec.productID, radix: 16)) \(spec.name) "
                               + "should not carry a dead zone")
        }
    }

    /// The CTC line ships on a second VID. A caller testing `== 0x056A`
    /// instead of this set skips the registry entirely for those PIDs, which
    /// is how the Wacom One S lost its `initSteps` (Cyzor/tablet-driver#16).
    func testVendorIDsCoverBothWacomVendors() {
        XCTAssertTrue(WacomDeviceRegistry.vendorIDs.contains(0x056A))
        XCTAssertTrue(WacomDeviceRegistry.vendorIDs.contains(0x0531))
    }

    /// The four CTC rows are reachable and carry the DATAMODE-2 write that
    /// promotes the tablet out of reduced HID-standard mode — without it the
    /// device streams only report 0x06, which has no second barrel switch.
    func testWacomOneCTCRowsCarryDataModeInit() {
        for pid in [0x0100, 0x0101, 0x0102, 0x0104] {
            guard let spec = WacomDeviceRegistry.spec(for: pid) else {
                return XCTFail("0x\(String(pid, radix: 16)) missing from registry")
            }
            XCTAssertTrue(
                spec.initSteps.contains { step in
                    if case .featureReport(let bytes) = step { return bytes == [0x02, 0x02] }
                    return false
                },
                "0x\(String(pid, radix: 16)) \(spec.name) must send DATAMODE-2")
        }
    }

    /// The Cintiq 27QHD Touch's finger sensor enumerates as its own product
    /// (0x032C), not as a second interface of the pen (0x032B). Its own row is
    /// name-only — maxX and buttonCount both 0 — so routing can only reach it
    /// through the pen row's claim. A reporter saw touch reports land in
    /// diagnostics while macOS got no touch events at all
    /// (Cyzor/tablet-driver#14); the sensor was falling through to the
    /// observe-only fallback because nothing tied the two PIDs together.
    func testCintiq27QHDTouchClaimsItsSensorPID() {
        guard let pen = WacomDeviceRegistry.spec(for: 0x032B) else {
            return XCTFail("0x032B missing from registry")
        }
        XCTAssertEqual(pen.touchCompanionPID, 0x032C)
        XCTAssertTrue(pen.hasFingerTouch,
                      "the claim is only useful if the claiming spec gates touch decode on")
    }

    /// `touchCompanionPIDs` is what routing consults before the claiming
    /// tablet has enumerated — arrival order between sensor and pen is not
    /// guaranteed, and a sensor that arrives first must be held rather than
    /// handed to the fallback.
    func testTouchCompanionPIDsIndexesEveryClaim() {
        for spec in WacomDeviceRegistry.knownDevices {
            guard let companion = spec.touchCompanionPID else { continue }
            XCTAssertTrue(
                WacomDeviceRegistry.touchCompanionPIDs.contains(companion),
                "0x\(String(companion, radix: 16)) claimed by \(spec.name) but not indexed")
        }
    }

    /// The sensor streams a single-contact report with no init at all (a
    /// 2026-09-17 capture collected 2186 frames with `initReports: null`), so
    /// this write is what buys the 10-contact report the same descriptor
    /// declares. Report 0x83 is the standard HID digitizer Device Mode control
    /// — Inputmode then Device Index — and Linux sends exactly this for
    /// WACOM_27QHDT via `wacom_set_device_mode(hdev, 131, 3, 2)`.
    func testCintiq27QHDTouchSensorGetsMultitouchDeviceModeInit() {
        guard let pen = WacomDeviceRegistry.spec(for: 0x032B) else {
            return XCTFail("0x032B missing from registry")
        }
        XCTAssertEqual(pen.touchCompanionInitSteps, [.featureReport([0x83, 0x02, 0x00])])
    }

    /// Init steps aimed at a sensor are useless without a sensor to aim them
    /// at, and would silently be sent nowhere.
    func testTouchCompanionInitStepsRequireACompanion() {
        for spec in WacomDeviceRegistry.knownDevices where !spec.touchCompanionInitSteps.isEmpty {
            XCTAssertNotNil(
                spec.touchCompanionPID,
                "\(spec.name) declares touch-sensor init steps but names no sensor")
        }
    }

    /// The Cintiq Pro 16 (DTH-167) splits the same way the 27QHD does: pen on
    /// 0x03B2, finger sensor on 0x03B3, and an internal hub on 0x03B4 that must
    /// stay out of the registry. Reported 2026-09-25 as working as a display
    /// only, with 0x03B3 the sole product the capture ever saw.
    ///
    /// Touch dimensions come from the sensor's own descriptor rather than
    /// libwacom, whose 356 x 203 mm is an outer-body figure. Leaving
    /// touchMaxX/Y at 0 would collapse every contact into one corner, as the
    /// 0x032B row's comment records.
    func testCintiqPro16DTH167ClaimsItsSensorPID() {
        guard let pen = WacomDeviceRegistry.spec(for: 0x03B2) else {
            return XCTFail("0x03B2 missing from registry")
        }
        XCTAssertEqual(pen.touchCompanionPID, 0x03B3)
        XCTAssertTrue(pen.hasFingerTouch)
        XCTAssertEqual(pen.touchMaxX, 13768)
        XCTAssertEqual(pen.touchMaxY, 7744)
        // Device Mode sits on report 0x0E here, not the 0x032B row's 0x83:
        // 0x0C carries Contact Count Maximum and is read-only.
        XCTAssertEqual(pen.touchCompanionInitSteps, [.featureReport([0x0E, 0x02, 0x00])])
        XCTAssertNil(WacomDeviceRegistry.spec(for: 0x03B4),
                     "0x03B4 is this unit's USB hub, not a digitizer")
    }

    /// "Cintiq Pro 16" names two generations — the 2016/2017 DTH-1620 and the
    /// 2021 DTH-167 — with the same 15.6" 16:9 panel, the same touch report ID
    /// and the same 5-slot layout. Physical size cannot tell them apart; the
    /// touch maxima are the only discriminator, so a well-meaning cleanup that
    /// unified them would silently misplace every contact on one of the two.
    func testCintiqPro16GenerationsKeepDistinctTouchMaxima() {
        guard let old = WacomDeviceRegistry.spec(for: 0x0354),
            let new = WacomDeviceRegistry.spec(for: 0x03B2)
        else { return XCTFail("a Cintiq Pro 16 generation is missing") }
        XCTAssertEqual(old.touchMaxX, 13824)
        XCTAssertEqual(old.touchMaxY, 7776)
        XCTAssertEqual(new.touchMaxX, 13768)
        XCTAssertEqual(new.touchMaxY, 7744)
        XCTAssertNotEqual(old.touchMaxX, new.touchMaxX,
                          "the generations are distinguished by touch maxima alone")
    }

    /// The 27QHD keeps DATAMODE alone. Its pen interface declares 0x0D but not
    /// 0x14 or 0x0E, so the GD16 sequence recovered from Wacom's driver is not
    /// this tablet's bring-up, and its express keys and touch already work —
    /// nothing here is worth risking on a guess.
    /// See Wacom-GD16-GD20-Startup-Findings.md.
    func testCintiq27QHDSendsDataModeOnly() {
        guard let spec = WacomDeviceRegistry.spec(for: 0x032B) else {
            return XCTFail("0x032B missing from registry")
        }
        XCTAssertEqual(
            spec.initSteps, [.featureReport([0x02, 0x02])],
            "0x032B gained an init step. Its pen interface declares neither 0x14 "
                + "nor 0x0E across seven captures, so the GD16 sequence is not "
                + "this tablet's bring-up. Its express keys and touch work today "
                + "— do not add speculative writes here")
    }

    /// The DTH-167 carries the GD16 scan enables as a deliberate guess, safe
    /// only because nothing on that device works yet. Pinned so the ordering
    /// survives: DATAMODE must stay last.
    func testCintiqPro16SendsScanEnablesBeforeDataMode() {
        guard let spec = WacomDeviceRegistry.spec(for: 0x03B2) else {
            return XCTFail("0x03B2 missing from registry")
        }
        XCTAssertEqual(
            spec.initSteps,
            [
                .featureReport([0x0E, 0x00]),
                .featureReport([0x0D, 0x00]),
                .featureReport([0x02, 0x02]),
            ],
            "0x03B2 init changed; DATAMODE must stay last so it lands even when "
                + "the scan enables fail")
    }

    /// A claimed sensor must not also be a drivable tablet in its own right:
    /// routing checks the companion claim first, so a PID that was both would
    /// lose its own driver.
    func testClaimedTouchSensorsAreNotDrivableThemselves() {
        for pid in WacomDeviceRegistry.touchCompanionPIDs {
            guard let spec = WacomDeviceRegistry.spec(for: pid) else { continue }
            XCTAssertEqual(spec.maxX, 0,
                           "0x\(String(pid, radix: 16)) \(spec.name) is claimed as a touch "
                               + "sensor but also declares a digitizer")
            XCTAssertEqual(spec.buttonCount, 0,
                           "0x\(String(pid, radix: 16)) \(spec.name) is claimed as a touch "
                               + "sensor but also declares buttons")
        }
    }
}
