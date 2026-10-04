// SPDX-License-Identifier: MPL-2.0
//
// Cost budget for the per-report hot path. Replays the conformance fixtures
// through their decoders many times and fails if a report costs far more than
// it does today, or if memory held after the run keeps growing.
//
// The ceilings sit well above measured cost so CI noise can't trip them. They
// exist to catch an order-of-magnitude regression, not to track small drift.
import CoreGraphics
import Darwin
import XCTest
@testable import TabletKit

final class HotPathBudgetTests: XCTestCase {

    private let iterations = 200_000

    /// Measured 0.1–0.5 µs per report on an M-series Mac in a debug build.
    /// A 1 kHz pen leaves 1,000 µs per report for the whole pipeline.
    private let decodeCeilingNanos: Double = 5_000

    /// Allowed growth in bytes still allocated after the full run.
    private let retainedGrowthCeiling = 256 * 1024

    func testDecodersStayWithinPerReportBudget() throws {
        for fixture in ConformanceHarnessTests.fixtures {
            guard var decoder = ConformanceDecoderFactory.make(for: fixture.parser) else {
                XCTFail("\(fixture.device): unknown parser '\(fixture.parser)'")
                continue
            }
            let records = try CaptureLogParser.parse(fixture.captureLog, requireHeader: false)
            var state = DecoderState()
            var sink = 0

            let before = bytesInUse()
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for i in 0..<iterations {
                let record = records[i % records.count]
                let results = HIDReport.withReport(record.bytes) { report in
                    decoder.decode(
                        report: report, spec: fixture.spec, state: &state,
                        deviceFamily: fixture.deviceFamily)
                }
                sink &+= results.count
            }
            let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
            let growth = bytesInUse() - before

            let perReport = Double(elapsed) / Double(iterations)
            print("hot-path \(fixture.parser) \(String(format: "%.0f", perReport)) ns/report, retained \(growth) B")
            XCTAssertGreaterThan(sink, 0)
            XCTAssertLessThan(perReport, decodeCeilingNanos, "\(fixture.device): decode cost regressed")
            XCTAssertLessThan(growth, retainedGrowthCeiling, "\(fixture.device): decode retains memory")
        }
    }

    func testCursorSmootherStaysWithinPerReportBudget() {
        var smoother = CursorSmoother()
        smoother.smoothingStrength = 0.3
        var sink: CGFloat = 0

        let before = bytesInUse()
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for i in 0..<iterations {
            let p = CGPoint(x: CGFloat(i % 4000), y: CGFloat(i % 3000))
            sink += smoother.applySmoothing(rawPoint: p, enteringProximity: i == 0, dt: 1.0 / 200.0).x
        }
        let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
        let growth = bytesInUse() - before

        let perReport = Double(elapsed) / Double(iterations)
        print("hot-path cursorSmoother \(String(format: "%.0f", perReport)) ns/report, retained \(growth) B")
        XCTAssertFalse(sink.isNaN)
        XCTAssertLessThan(perReport, decodeCeilingNanos, "cursor smoothing cost regressed")
        XCTAssertLessThan(growth, retainedGrowthCeiling, "cursor smoothing retains memory")
    }

    private func bytesInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }
}
