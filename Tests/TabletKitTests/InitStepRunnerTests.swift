// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import Foundation
import IOKit
import XCTest
@testable import TabletKit

/// Records writes and reads; answers string reads from a table and feature
/// reads from a queue of replies.
final class RecordingHIDInterface: HIDInterface, @unchecked Sendable {
    let vendorID = 0x056A, productID = 0x0001, usagePage = 0xFF00, usage = 0x01
    var maxOutputReportSize = 0
    var strings: [UInt8: [UInt8]] = [:]
    var featureReplies: [(IOReturn, [UInt8])] = []
    private let lock = NSLock()
    private var _log: [String] = []
    var log: [String] { lock.withLock { _log } }

    private func record(_ s: String) { lock.withLock { _log.append(s) } }

    func setReport(_ kind: HIDReportKind, bytes: [UInt8]) -> IOReturn {
        record("\(kind) \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        return kIOReturnSuccess
    }
    func getReport(_ kind: HIDReportKind, id: UInt8, length: Int) -> (IOReturn, [UInt8]) {
        record("get \(kind) \(String(format: "%02X", id))")
        return lock.withLock { featureReplies.isEmpty ? (kIOReturnUnsupported, []) : featureReplies.removeFirst() }
    }
    func readString(index: UInt8) -> [UInt8]? {
        record("string \(index)")
        return strings[index]
    }
}

final class InitStepRunnerTests: XCTestCase {

    func testRunsStepsInOrderAndPadsOutputReports() {
        let iface = RecordingHIDInterface()
        iface.maxOutputReportSize = 5
        iface.strings[200] = [4, 3, 0x41, 0]
        let recorded = Recorded<InitStepOutcome>()
        InitStepRunner.run(
            [.featureReport([0x02, 0x02]), .outputReport([0x02, 0xB0, 0x04]), .stringDescriptor(200)],
            on: iface
        ) { recorded.append($0) }
        let outcomes = recorded.values

        XCTAssertEqual(iface.log, ["feature 02 02", "output 02 B0 04 00 00", "string 200"])
        XCTAssertEqual(outcomes.map(\.index), [0, 1, 2])
        XCTAssertEqual(outcomes[1].sentLength, 5)
        XCTAssertEqual(outcomes[2].reply, [4, 3, 0x41, 0])
    }

    func testContinuesOnTheQueueAfterADelay() {
        let iface = RecordingHIDInterface()
        let queue = DispatchQueue(label: "init-test")
        let done = expectation(description: "last step")
        InitStepRunner.run(
            [.featureReport([0x02, 0x02]), .delay(0.01), .featureReport([0x03, 0x01])],
            on: iface, queue: queue
        ) { o in
            if o.index == 2 {
                dispatchPrecondition(condition: .onQueue(queue))
                done.fulfill()
            }
        }
        // Only the step before the delay has run synchronously.
        XCTAssertEqual(iface.log, ["feature 02 02"])
        wait(for: [done], timeout: 2)
        XCTAssertEqual(iface.log, ["feature 02 02", "feature 03 01"])
    }

    func testStartsMidSequence() {
        let iface = RecordingHIDInterface()
        InitStepRunner.run(
            [.featureReport([0x02, 0x02]), .featureReport([0x03, 0x01])], on: iface, from: 1
        ) { _ in }
        XCTAssertEqual(iface.log, ["feature 03 01"])
    }
}

final class ModeReadBackTests: XCTestCase {
    private let rule = TabletQuirks.ModeReadBack(report: [0x02, 0x02], resendAfter: [0.01, 0.03])

    private func run(_ replies: [(IOReturn, [UInt8])]) -> (RecordingHIDInterface, [ModeReadBackOutcome]) {
        let iface = RecordingHIDInterface()
        iface.featureReplies = replies
        let outcomes = Recorded<ModeReadBackOutcome>()
        let done = expectation(description: "last attempt")
        InitStepRunner.confirmMode(rule, on: iface, queue: DispatchQueue(label: "mode-test")) { o in
            outcomes.append(o)
            if o.isLast { done.fulfill() }
        }
        wait(for: [done], timeout: 2)
        return (iface, outcomes.values)
    }

    func testStopsWhenTheFirstReadMatches() {
        let (iface, outcomes) = run([(kIOReturnSuccess, [0x02, 0x02])])
        XCTAssertEqual(iface.log, ["get feature 02"])
        XCTAssertEqual(outcomes.map(\.matched), [true])
    }

    func testResendsUntilTheModeTakes() {
        let (iface, outcomes) = run([(kIOReturnSuccess, [0x02, 0x01]), (kIOReturnSuccess, [0x02, 0x02])])
        XCTAssertEqual(iface.log, ["get feature 02", "feature 02 02", "get feature 02"])
        XCTAssertEqual(outcomes.map(\.matched), [false, true])
        XCTAssertEqual(outcomes.last?.writeResult, kIOReturnSuccess)
    }

    func testGivesUpAfterTheLastResend() {
        let stuck = (kIOReturnSuccess, [UInt8]([0x02, 0x01]))
        let (iface, outcomes) = run([stuck, stuck, stuck])
        XCTAssertEqual(iface.log.filter { $0 == "feature 02 02" }.count, 2)
        XCTAssertEqual(outcomes.map(\.attempt), [0, 1, 2])
        XCTAssertEqual(outcomes.map(\.isLast), [false, false, true])
        XCTAssertFalse(outcomes.contains { $0.matched })
    }

    func testAFailedReadCountsAsNotTaken() {
        let (_, outcomes) = run([(kIOReturnNotResponding, []), (kIOReturnSuccess, [0x02, 0x02])])
        XCTAssertEqual(outcomes.map(\.matched), [false, true])
    }
}

/// Collects values from a `@Sendable` callback.
final class Recorded<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [T] = []
    var values: [T] { lock.withLock { _values } }
    func append(_ v: T) { lock.withLock { _values.append(v) } }
}
