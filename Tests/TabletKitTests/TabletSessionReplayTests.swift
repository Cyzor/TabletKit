// SPDX-License-Identifier: MPL-2.0
//
// Whole recordings through TabletSession: report traces must decode event
// for event as MockTab's driver did, captures must route and group, and
// every registered device in the routing corpus must get a transport.
// Traces and captures live outside the repo, so those checks skip without them.
import Foundation
import XCTest
@testable import TabletKit

@MainActor
final class TabletSessionReplayTests: XCTestCase {

    func testTracesReplayThroughTheSession() throws {
        let traces = PrivateRecordings.traces
        guard !traces.isEmpty else { throw XCTSkip("No report traces outside the repo") }
        for trace in traces {
            let recording = try ReplayRecording(trace: String(contentsOf: trace, encoding: .utf8))
            let backend = ReplayBackend(recording)
            let delegate = RecordingDelegate()
            let session = TabletSession(backend: backend, delegate: delegate)
            session.start()
            var recorded = 0
            var mismatches: [String] = []
            for (n, event) in recording.events.enumerated() {
                delegate.lastBatch = []
                backend.play(through: n + 1)
                guard case .report(let i, _, let ns, let decoded?) = event else { continue }
                recorded += 1
                let got = delegate.lastBatch.map { goldenDescription($0).text }
                if got != decoded { mismatches.append("interface \(i) at \(ns): got \(got) recorded \(decoded)") }
            }
            session.stop()
            let name = trace.lastPathComponent
            print("session replay \(name): \(recorded) reports, \(delegate.reports) delivered, \(mismatches.count) mismatches")
            XCTAssertEqual(delegate.reports, recorded, "\(name): every report the driver saw reaches the session")
            let sidecar = trace.appendingPathExtension("mismatches")
            if let note = try? String(contentsOf: sidecar, encoding: .utf8),
               let expected = Int(note.split(separator: "\n").first ?? "") {
                XCTAssertEqual(mismatches.count, expected, "\(name): \(note)")
                continue
            }
            for m in mismatches.prefix(5) { XCTFail("\(name): \(m)") }
        }
    }

    /// Every capture of a registered tablet connects it as exactly one tablet.
    func testCapturesRouteAndGroup() throws {
        let zips = PrivateRecordings.captures
        guard !zips.isEmpty else { throw XCTSkip("No captures outside the repo") }
        var checked = 0
        var failures: [String] = []
        for zip in zips {
            let members = unzip(["-Z1", zip.path]).map { String(decoding: $0, as: UTF8.self) } ?? ""
            for member in members.split(separator: "\n")
            where member.hasSuffix("/summary.json") || member == "summary.json" {
                guard let summary = unzip(["-p", zip.path, String(member)]), !summary.isEmpty,
                      let recording = try? ReplayRecording(captureSummary: summary),
                      let first = recording.interfaces.first
                else { continue }
                let pid = WacomDeviceRegistry.vendorIDs.contains(first.vendorID)
                    ? WacomDeviceRegistry.canonicalProductID(for: first.productID) : first.productID
                guard first.vendorID == 0x056A, let spec = WacomDeviceRegistry.spec(for: pid),
                      spec.maxX > 0 || spec.buttonCount > 0,
                      !WacomDeviceRegistry.touchCompanionPIDs.contains(pid)
                else { continue }
                let backend = ReplayBackend(recording)
                let delegate = RecordingDelegate()
                let session = TabletSession(backend: backend, delegate: delegate)
                session.start()
                backend.play()
                checked += 1
                let label = "\(zip.lastPathComponent) \(spec.name)"
                // A capture can hold other devices' interfaces too.
                let own = session.tablets.filter { $0.productID == pid }
                if own.count != 1 { failures.append("\(label): \(own.count) tablets") }
                session.stop()
            }
        }
        print("session routed \(checked) captures")
        XCTAssertGreaterThan(checked, 0)
        XCTAssertEqual(failures, [])
    }

    private struct CorpusDevice: Decodable {
        let productID: String
        let transport: String
        let interfaces: [[[Int]]]
    }

    /// The routing corpus through the session, interfaces in listed order:
    /// every registered device gets exactly one tablet with a transport.
    func testRoutingCorpusThroughTheSession() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/InterfaceRouting")
        var checked = 0
        var failures: [String] = []
        for name in ["corpus.json", "corpus-linuxwacom.json"] {
            let devices = try JSONDecoder().decode(
                [CorpusDevice].self, from: Data(contentsOf: fixtures.appendingPathComponent(name)))
            for d in devices {
                let pid = Int(d.productID.dropFirst(2), radix: 16)!
                guard pid != 0x0084, !WacomDeviceRegistry.touchCompanionPIDs.contains(pid),
                      let spec = WacomDeviceRegistry.spec(for: WacomDeviceRegistry.canonicalProductID(for: pid)),
                      spec.maxX > 0 || spec.buttonCount > 0
                else { continue }
                let interfaces = d.interfaces.map { tops -> ReplayRecording.Interface in
                    var r = ReplayRecording.Interface()
                    r.vendorID = 0x056A
                    r.productID = pid
                    r.usagePairs = tops.map { HIDUsagePair(page: $0[0], usage: $0[1]) }
                    r.usagePage = tops.first?[0] ?? 0
                    r.usage = tops.first?[1] ?? 0
                    r.transport = d.transport
                    return r
                }
                let recording = ReplayRecording(interfaces: interfaces, events: interfaces.indices.map { .attach($0) })
                let backend = ReplayBackend(recording)
                let delegate = RecordingDelegate()
                let session = TabletSession(backend: backend, delegate: delegate)
                session.start()
                backend.play()
                checked += 1
                // A Bluetooth device whose only interface is the ghost mouse has nothing to drive.
                let onlyGhost = d.transport.hasPrefix("Bluetooth")
                    && interfaces.allSatisfy { $0.usagePage == 0x01 && $0.usage == 0x02 }
                if session.tablets.count != 1 && !onlyGhost {
                    failures.append("\(spec.name) (\(d.productID) \(d.transport)): \(session.tablets.count) tablets")
                }
                session.stop()
            }
        }
        XCTAssertGreaterThan(checked, 70)
        XCTAssertEqual(failures, [])
    }

    private func unzip(_ arguments: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
