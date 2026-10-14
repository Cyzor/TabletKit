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

    /// The input path does about twice the decoder's work: 1 µs here, and
    /// 3 to 5.5 µs on CI's shared runners.
    private let inputCeilingNanos: Double = 10_000

    /// Allowed growth in bytes still allocated after the full run.
    private let retainedGrowthCeiling = 256 * 1024

    func testDecodersStayWithinPerReportBudget() throws {
        for fixture in ConformanceHarnessTests.fixtures {
            guard let made = ConformanceDecoderFactory.make(for: fixture.parser) else {
                XCTFail("\(fixture.device): unknown parser '\(fixture.parser)'")
                continue
            }
            let records = try CaptureLogParser.parse(fixture.captureLog, requireHeader: false)
            var decoder = DeviceDecoder(made, digitizer: fixture.spec, family: fixture.deviceFamily)
            var sink = 0

            let before = bytesInUse()
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for i in 0..<iterations {
                let record = records[i % records.count]
                let results = HIDReport.withReport(record.bytes) { decoder.decode($0) }
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

    /// The whole input path a session runs per report: the pre-decode
    /// checks, decoding, and the gates. Prints its cost next to the decoder's
    /// alone, on the same reports.
    func testTabletInputStaysWithinPerReportBudget() throws {
        // The fixtures' devices, by registry row.
        let rows: [String: Int] = ["bamboo": 0x00D4, "intuosV2": 0x03D0]
        for fixture in ConformanceHarnessTests.fixtures {
            let pid = fixture.device.contains("PTK-870") ? 0x03F9
                : fixture.device.contains("DTH-135") ? 0x03F0 : rows[fixture.parser]
            guard let pid, let spec = WacomDeviceRegistry.spec(for: pid) else { continue }
            let records = try CaptureLogParser.parse(fixture.captureLog, requireHeader: false)
            var input = TabletInput(spec: spec, isBluetooth: false, isWireless: false)
            var decoder = spec.makeDecoder()
            var sink = 0

            let before = bytesInUse()
            var start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for i in 0..<iterations {
                let record = records[i % records.count]
                let out = HIDReport.withReport(record.bytes) { input.handle($0, at: UInt64(i) * 1_000_000 + 1) }
                sink &+= out.events.count
            }
            let inputNanos = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(iterations)
            let growth = bytesInUse() - before

            start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for i in 0..<iterations {
                let record = records[i % records.count]
                sink &+= HIDReport.withReport(record.bytes) { decoder.events($0) }.count
            }
            let decodeNanos = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(iterations)

            print("hot-path input \(spec.name) \(String(format: "%.0f", inputNanos)) ns/report, decoder alone \(String(format: "%.0f", decodeNanos)) ns, retained \(growth) B")
            XCTAssertGreaterThan(sink, 0)
            XCTAssertLessThan(inputNanos, inputCeilingNanos, "\(fixture.device): input path cost regressed")
            XCTAssertLessThan(growth, retainedGrowthCeiling, "\(fixture.device): input path retains memory")
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
