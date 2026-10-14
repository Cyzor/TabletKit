// SPDX-License-Identifier: MPL-2.0
//
// Replays report traces recorded from MockTab's own driver through
// TabletInput, and checks every report's events against the ones the driver
// produced. Traces hold pen and hardware serials, so they live outside the
// repo and this test skips without them.
import Foundation
import XCTest
@testable import TabletKit

final class TabletInputReplayTests: XCTestCase {

    private var traceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Notes/Scratch/Device-Diagnostics/Traces")
    }

    func testTracesReplayEventForEvent() throws {
        let traces = (try? FileManager.default.contentsOfDirectory(at: traceDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path } ?? []
        guard !traces.isEmpty else { throw XCTSkip("No report traces outside the repo") }
        for trace in traces {
            let recording = try ReplayRecording(trace: String(contentsOf: trace, encoding: .utf8))
            let result = replay(recording)
            print("replay \(trace.lastPathComponent): \(result.reports) reports, \(result.mismatches.count) mismatches")
            XCTAssertGreaterThan(result.reports, 0, trace.lastPathComponent)
            // A trace recorded before a deliberate decoder change carries the
            // number of reports that change makes differ, first line of a
            // sidecar file, with the reason after it.
            let sidecar = trace.appendingPathExtension("mismatches")
            if let note = try? String(contentsOf: sidecar, encoding: .utf8),
               let expected = Int(note.split(separator: "\n").first ?? "") {
                XCTAssertEqual(result.mismatches.count, expected, "\(trace.lastPathComponent): \(note)")
                continue
            }
            for m in result.mismatches.prefix(5) { XCTFail("\(trace.lastPathComponent): \(m)") }
        }
    }

    /// One `TabletInput` per tablet and transport, as the driver has one per
    /// connection; interfaces of the same product fold onto it.
    private func replay(_ recording: ReplayRecording) -> (reports: Int, mismatches: [String]) {
        var inputs: [String: TabletInput] = [:]
        var keyOf: [Int: String] = [:]
        var open: [String: Set<Int>] = [:]
        var reports = 0
        var mismatches: [String] = []
        for event in recording.events {
            switch event {
            case .attach(let i):
                let iface = ReplayInterface(recording.interfaces[i])
                let pid = WacomDeviceRegistry.canonicalProductID(for: iface.productID)
                guard let spec = WacomDeviceRegistry.spec(for: pid) else { continue }
                let bluetooth = iface.transport.lowercased().contains("bluetooth")
                let key = "\(pid) \(bluetooth)"
                if inputs[key] == nil {
                    inputs[key] = TabletInput(spec: spec, isBluetooth: bluetooth, isWireless: false)
                }
                inputs[key]!.register(iface)
                keyOf[i] = key
                open[key, default: []].insert(i)
            case .detach(let i):
                guard let key = keyOf[i] else { continue }
                open[key]?.remove(i)
                if open[key]?.isEmpty == true { inputs[key] = nil }
            case .report(let i, let bytes, let ns, let decoded):
                guard let key = keyOf[i], var input = inputs[key], let decoded else { continue }
                let output = HIDReport.withReport(bytes) { input.handle($0, at: ns) }
                inputs[key] = input
                reports += 1
                let got = output.events.map { goldenDescription($0).text }
                if got != decoded {
                    mismatches.append("interface \(i) at \(ns): got \(got) recorded \(decoded)")
                }
            }
        }
        return (reports, mismatches)
    }
}
