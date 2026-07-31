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
}
