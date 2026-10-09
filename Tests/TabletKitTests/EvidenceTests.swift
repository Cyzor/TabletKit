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

    /// A kernel or OpenTabletDriver citation for the pen must match the
    /// committed audit exactly, so an edit can't cite a source that disagrees.
    /// `tools/verify_registry.py` regenerates the audit.
    func testPenCitationsMatchTheAudit() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("registry_audit.csv")
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
        let header = csvFields(lines[0])
        var audit: [Int: [String: String]] = [:]
        for line in lines.dropFirst() {
            let row = Dictionary(zip(header, csvFields(line)), uniquingKeysWith: { first, _ in first })
            if let pid = row["pid"].flatMap({ Int($0.dropFirst(2), radix: 16) }) { audit[pid] = row }
        }
        for row in rows {
            let audited = audit[row.productID] ?? [:]
            let label = String(format: "0x%04X %@", row.productID, row.name)
            for (source, prefix) in [(EvidenceSource.linuxKernel, "kernel"), (.openTabletDriver, "otd")] {
                func value(_ field: String) -> Int? {
                    audited["\(prefix)_\(field)"].flatMap(Double.init).map { Int($0) }
                }
                if row.evidence[.penPosition]?.sources.contains(source) == true {
                    XCTAssertEqual(value("maxX"), row.maxX, "\(label): \(source) position")
                    XCTAssertEqual(value("maxY"), row.maxY, "\(label): \(source) position")
                }
                if row.evidence[.pressure]?.sources.contains(source) == true {
                    XCTAssertEqual(value("maxP"), row.maxPressure, "\(label): \(source) pressure")
                }
            }
        }
    }

    private func csvFields(_ line: Substring) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        for character in line {
            switch character {
            case "\"": quoted.toggle()
            case "," where !quoted:
                fields.append(field)
                field = ""
            default: field.append(character)
            }
        }
        fields.append(field)
        return fields
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
