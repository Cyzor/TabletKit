// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import TabletKit

final class EvidenceTests: XCTestCase {

    private let rows = WacomDeviceRegistry.knownDevices

    func testEveryListedProductIDHasARegistryRow() {
        let known = Set(rows.map(\.productID))
        let listed = Set(WacomEvidence.table.keys)
            .union(WacomEvidence.outOfScope.keys)
            .union(WacomEvidence.bluetoothModels)
            .union(WacomEvidence.receiverModels)
        XCTAssertEqual(listed.subtracting(known), [], "evidence names product IDs the registry lacks")
    }

    func testNoProductIDAppearsInTwoFamilies() {
        var seen: [Int: Int] = [:]
        for family in WacomEvidence.families {
            for pid in family.keys { seen[pid, default: 0] += 1 }
        }
        XCTAssertEqual(seen.filter { $0.value > 1 }.keys.sorted(), [])
    }

    /// Evidence may only add features the flags can't express.
    func testListedFeaturesMatchTheRowsFlags() {
        for row in rows {
            guard let listed = WacomEvidence.table[row.productID] else { continue }
            let extra = Set(listed.keys).subtracting(row.flagFeatures).subtracting([.displayControls])
            XCTAssertEqual(extra, [], "\(row.name) lists features its flags don't claim")
        }
    }

    /// Notes are public: one sentence, no private paths or capture files.
    func testNotesArePublicSafe() {
        let banned = ["Scratch", ".hid", ".json", ".txt", "driver", "serial", "\n"]
        for (pid, features) in WacomEvidence.table {
            for (feature, evidence) in features {
                guard let note = evidence.note else { continue }
                for word in banned {
                    XCTAssertFalse(
                        note.localizedCaseInsensitiveContains(word),
                        String(format: "0x%04X %@: note contains \"%@\"", pid, feature.rawValue, word))
                }
            }
        }
    }

    func testEveryClaimedFeatureHasEvidence() {
        for row in rows {
            XCTAssertEqual(Set(row.evidence.keys), row.claimedFeatures, row.name)
        }
    }

    func testRecordingAloneDoesNotRaiseTheTier() {
        XCTAssertFalse(FeatureEvidence(.recorded, [.publicRecording]).hasNonRecordingSource)
        XCTAssertTrue(FeatureEvidence(.recorded, [.publicRecording, .linuxKernel]).hasNonRecordingSource)
        XCTAssertFalse(FeatureEvidence(.claimed, [.linuxKernel]).hasNonRecordingSource)
    }

    func testBusinessDisplaysAreOutOfScopeAndDrawingDisplaysAreNot() {
        XCTAssertEqual(WacomDeviceRegistry.spec(for: 0x035A)?.scope, .outOfScope("Business display"))
        XCTAssertEqual(WacomDeviceRegistry.spec(for: 0x00C0)?.scope, .inScope)  // DTF-720
    }

    /// Lists in-scope rows whose stored tier the evidence doesn't yet support.
    /// Informational until every family is backfilled; it never fails.
    func testReportTierMismatches() {
        let mismatched = rows.filter { $0.scope == .inScope && $0.evidenceTier != $0.confidence }
        let byStored = Dictionary(grouping: mismatched, by: { "\($0.confidence)" })
        let summary = byStored.keys.sorted()
            .map { "\($0) \(byStored[$0]!.count)" }.joined(separator: ", ")
        print("Evidence tier mismatches: \(mismatched.count) of \(rows.count) rows (\(summary))")
    }
}
