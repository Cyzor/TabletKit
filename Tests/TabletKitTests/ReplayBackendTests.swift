// SPDX-License-Identifier: MPL-2.0
//
// Replay recordings and the backend that plays them. Real captures live
// outside the repo, so those checks skip when the files are absent.
import Foundation
import IOKit
import XCTest
@testable import TabletKit

@MainActor
final class ReplayBackendTests: XCTestCase {

    private let trace = """
        {"kind":"initRead","ns":1,"purpose":"mode read-back","reportID":2,"ioReturn":0,"reply":"0202","usagePage":65293}
        {"kind":"attach","iface":1,"ns":2,"vendorID":1386,"productID":855,"usagePage":65293,"usage":1,"usagePairs":[[65293,1],[13,2]],"transport":"USB","product":"PTH-660","serial":"X1","locationID":7,"maxInput":192,"maxOutput":10,"descriptor":"0601ff"}
        {"kind":"attach","iface":2,"ns":3,"vendorID":1386,"productID":855,"usagePage":13,"usage":4,"usagePairs":[],"transport":"USB","product":"PTH-660","serial":"","locationID":7,"maxInput":64,"maxOutput":0,"descriptor":""}
        {"kind":"report","iface":1,"ns":100,"bytes":"10e0","events":["pen 1 2"]}
        {"kind":"report","iface":2,"ns":200,"bytes":"0c00","events":[]}
        {"kind":"detach","iface":2,"ns":300}
        """

    func testTraceLoadsInterfacesEventsAndReplies() throws {
        let r = try ReplayRecording(trace: trace)
        XCTAssertEqual(r.interfaces.count, 2)
        let pen = r.interfaces[0]
        XCTAssertEqual(pen.productID, 855)
        XCTAssertEqual(pen.usagePairs, [HIDUsagePair(page: 0xFF0D, usage: 1), HIDUsagePair(page: 0x0D, usage: 2)])
        XCTAssertEqual(pen.serialNumber, "X1")
        XCTAssertNil(r.interfaces[1].serialNumber, "an empty serial reads as none")
        XCTAssertEqual(pen.reportDescriptor, [0x06, 0x01, 0xFF])
        XCTAssertEqual(pen.featureReplies[2], [ReplayRecording.Reply(result: 0, bytes: [0x02, 0x02])])
        XCTAssertNil(r.interfaces[1].featureReplies[2], "a read attaches to its own usage page only")
        XCTAssertEqual(r.events.count, 5)
        guard case .report(let i, let bytes, let ns, let decoded) = r.events[2] else { return XCTFail() }
        XCTAssertEqual(i, 0)
        XCTAssertEqual(bytes, [0x10, 0xE0])
        XCTAssertEqual(ns, 100)
        XCTAssertEqual(decoded, ["pen 1 2"])
        guard case .detach(1) = r.events[4] else { return XCTFail() }
    }

    /// Captures lack usage pairs, so they're read off the descriptor. Traces
    /// have both, the pairs from IOKit, to check against.
    func testUsagePairsFromDescriptorMatchIOKit() throws {
        XCTAssertEqual(collectionUsages([0x05, 0x0D, 0x09, 0x02, 0xA1, 0x01, 0xA1, 0x00, 0xC0, 0xC0,
                                            0x06, 0x00, 0xFF, 0x09, 0x01, 0xA1, 0x01, 0x09, 0x02, 0xA1, 0x02, 0xC0, 0xC0]),
                       [HIDUsagePair(page: 0x0D, usage: 0x02), HIDUsagePair(page: 0xFF00, usage: 0x01)])
        let traces = PrivateRecordings.traces
        guard !traces.isEmpty else { throw XCTSkip("No report traces outside the repo") }
        for trace in traces {
            for i in try ReplayRecording(trace: String(contentsOf: trace, encoding: .utf8)).interfaces
            where !i.reportDescriptor.isEmpty {
                // IOKit lists a few more, never fewer, and agrees on the pen
                // collection, which is what routing reads.
                let derived = collectionUsages(i.reportDescriptor)
                XCTAssertTrue(Set(derived.map { [$0.page, $0.usage] }).isSubset(of: Set(i.usagePairs.map { [$0.page, $0.usage] })))
                XCTAssertEqual(InterfaceRouting.isPenCollection(in: derived.map { ($0.page, $0.usage) }),
                               InterfaceRouting.isPenCollection(in: i.usagePairs.map { ($0.page, $0.usage) }),
                               "\(trace.lastPathComponent) 0x\(String(i.productID, radix: 16)) page 0x\(String(i.usagePage, radix: 16))")
            }
        }
    }

    func testMalformedTraceLineThrows() {
        XCTAssertThrowsError(try ReplayRecording(trace: "not json"))
    }

    func testBackendPlaysInOrderAndAnswersReads() throws {
        let backend = ReplayBackend(try ReplayRecording(trace: trace))
        var log: [String] = []
        var received: [[UInt8]] = []
        _ = backend.start(
            attached: { iface in
                log.append("attach \(iface.usagePage)")
                if iface.usagePage == 0xFF0D {
                    _ = iface.open(seize: true) { report, ns in
                        let bytes = Array(UnsafeBufferPointer(start: report.pointer, count: report.count))
                        MainActor.assumeIsolated {
                            received.append(bytes)
                            log.append("report \(ns)")
                        }
                    }
                }
            },
            detached: { iface in log.append("detach \(iface.usagePage)") })

        XCTAssertEqual(backend.play(through: 3), 3)
        XCTAssertEqual(log, ["attach 65293", "attach 13", "report 100"])
        XCTAssertEqual(backend.play(), 5)
        XCTAssertEqual(log, ["attach 65293", "attach 13", "report 100", "detach 13"],
                       "an interface nobody opened gets no reports")
        XCTAssertEqual(received, [[0x10, 0xE0]])

        let pen = backend.interfaces[0]
        XCTAssertTrue(pen.seized)
        XCTAssertEqual(pen.getReport(.feature, id: 2, length: 16).1, [0x02, 0x02])
        XCTAssertEqual(pen.getReport(.feature, id: 2, length: 16).0, kIOReturnUnsupported, "replies run out")
        _ = pen.setReport(.feature, bytes: [0x02, 0x02])
        XCTAssertEqual(pen.writes, ["feature 02 02"])
    }

    func testCaptureLoadsVerbatimLinesOnly() throws {
        let summary = """
            {"deviceInfo":{"vendorID":"0x056A","productID":"0x0374","name":"Wacom CTL-4100","transport":"USB"},
             "interfaces":[
               {"usagePage":"0xFF0D","usage":"0x0001","productID":"0x0374","isPrimary":true,"sampleCount":3,
                "reports":{"0x10":{}},"hidReportDescriptor":{"rawHex":"0601ff","rawLength":3,"reports":{}}},
               {"usagePage":"0x0001","usage":"0x0002","productID":"0x0374","isPrimary":false,"sampleCount":0,
                "reports":{"0x01":{}},"hidReportDescriptor":{"rawHex":"","rawLength":0,"reports":{}}}],
             "initReads":[{"purpose":"hardware serial","reportID":3,"reply":"0331320000000000","interfaceUsagePage":"0xFF0D"}]}
            """
        let log = """
            MockTab HID Capture
            [00:04.051] Wacom CTL-4100       ID=10 len=4    10 60 31 13  → toolEnter serial=1
            [00:04.063] Wacom CTL-4100       ID=10 len=4  ×396 steady-state  →  x:3821-5209
            [00:07.015] Wacom CTL-4100       ID=01 len=2    01 01
            """
        let r = try ReplayRecording(captureSummary: Data(summary.utf8), log: log)
        XCTAssertEqual(r.interfaces.map(\.usagePage), [0xFF0D, 0x0001])
        XCTAssertEqual(r.interfaces[0].vendorID, 0x056A)
        XCTAssertEqual(r.interfaces[0].reportDescriptor, [0x06, 0x01, 0xFF])
        XCTAssertEqual(r.interfaces[0].featureReplies[3]?.first?.bytes.count, 8)
        let reports = r.events.compactMap { e -> (Int, [UInt8], UInt64)? in
            if case .report(let i, let b, let ns, _) = e { return (i, b, ns) } else { return nil }
        }
        XCTAssertEqual(reports.count, 2, "the steady-state run doesn't replay")
        XCTAssertEqual(reports[0].1, [0x10, 0x60, 0x31, 0x13])
        XCTAssertEqual(reports[0].2, 4_051_000_000)
        XCTAssertEqual(reports[1].0, 1, "a report goes to the interface that declares its ID")
    }

    /// Our own and submitted captures, kept outside the repo.
    func testRealCapturesLoad() throws {
        let zips = PrivateRecordings.captures
        guard !zips.isEmpty else { throw XCTSkip("No captures outside the repo") }
        var loaded = 0
        for zip in zips {
            let members = unzip(zip, ["-Z1"]).map { String(decoding: $0, as: UTF8.self) } ?? ""
            for member in members.split(separator: "\n")
            where member.hasSuffix("/summary.json") || member == "summary.json" {
                guard let summary = unzip(zip, ["-p", zip.path, String(member)]), !summary.isEmpty else { continue }
                let logMember = member.dropLast("summary.json".count) + "full-log.txt"
                let log = unzip(zip, ["-p", zip.path, String(logMember)]).map { String(decoding: $0, as: UTF8.self) }
                let r = try ReplayRecording(captureSummary: summary, log: log)
                XCTAssertFalse(r.interfaces.isEmpty, "\(zip.lastPathComponent) \(member)")
                let expected = r.events.filter { if case .report = $0 { true } else { false } }.count
                let backend = ReplayBackend(r)
                let delivered = Counter()
                _ = backend.start(attached: { iface in
                    _ = iface.open(seize: false) { _, _ in delivered.add() }
                }, detached: { _ in })
                backend.play()
                XCTAssertEqual(delivered.value, expected, "\(zip.lastPathComponent) \(member)")
                loaded += 1
            }
        }
        XCTAssertGreaterThan(loaded, 0)
        print("replayed \(loaded) captures")
    }

    private final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func add() { value += 1 }
    }

    private func unzip(_ zip: URL, _ arguments: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = arguments == ["-Z1"] ? ["-Z1", zip.path] : arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
