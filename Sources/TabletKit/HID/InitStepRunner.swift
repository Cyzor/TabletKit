// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import IOKit

/// What one init step did.
package struct InitStepOutcome: Sendable {
    package let index: Int
    package let step: InitStep
    /// The write's result; `nil` for delays and string reads.
    package let result: IOReturn?
    /// Bytes actually sent, after padding.
    package let sentLength: Int
    /// A string read's reply.
    package let reply: [UInt8]?
}

/// One read-back of a mode switch.
package struct ModeReadBackOutcome: Sendable {
    /// 0 for the read right after init, then one per resend.
    package let attempt: Int
    /// The resend's result; `nil` on attempt 0.
    package let writeResult: IOReturn?
    package let readResult: IOReturn
    package let reply: [UInt8]
    package let matched: Bool
    /// Nothing follows this outcome.
    package let isLast: Bool
}

/// Runs a tablet's ``InitStep``s in order against one interface.
///
/// Output reports are padded to the interface's declared size. Steps run on
/// the caller's thread until a delay; after one, the rest run on `queue`.
package enum InitStepRunner {
    package static func run(
        _ steps: [InitStep], on interface: any HIDInterface,
        queue: DispatchQueue = .main, from index: Int = 0,
        onStep: @escaping @Sendable (InitStepOutcome) -> Void
    ) {
        var i = index
        while i < steps.count {
            let step = steps[i]
            switch step {
            case .featureReport(let bytes):
                let ret = interface.setReport(.feature, bytes: bytes)
                onStep(InitStepOutcome(index: i, step: step, result: ret, sentLength: bytes.count, reply: nil))
            case .outputReport(let bytes):
                let report = padded(bytes, toSize: interface.maxOutputReportSize)
                let ret = interface.setReport(.output, bytes: report)
                onStep(InitStepOutcome(index: i, step: step, result: ret, sentLength: report.count, reply: nil))
            case .stringDescriptor(let descriptor):
                let reply = interface.readString(index: UInt8(truncatingIfNeeded: descriptor))
                onStep(InitStepOutcome(index: i, step: step, result: nil, sentLength: 0, reply: reply))
            case .delay(let seconds):
                onStep(InitStepOutcome(index: i, step: step, result: nil, sentLength: 0, reply: nil))
                let next = i + 1
                queue.asyncAfter(deadline: .now() + seconds) {
                    run(steps, on: interface, queue: queue, from: next, onStep: onStep)
                }
                return
            }
            i += 1
        }
    }

    /// Reads back a mode switch that init already sent, and resends it on
    /// the rule's schedule until the tablet reports the mode. The first read
    /// runs on the caller's thread, the rest on `queue`.
    package static func confirmMode(
        _ rule: TabletQuirks.ModeReadBack, on interface: any HIDInterface,
        queue: DispatchQueue = .main,
        onAttempt: @escaping @Sendable (ModeReadBackOutcome) -> Void
    ) {
        confirmMode(rule, on: interface, queue: queue, attempt: 0, writeResult: nil, onAttempt: onAttempt)
    }

    private static func confirmMode(
        _ rule: TabletQuirks.ModeReadBack, on interface: any HIDInterface,
        queue: DispatchQueue, attempt: Int, writeResult: IOReturn?,
        onAttempt: @escaping @Sendable (ModeReadBackOutcome) -> Void
    ) {
        guard let id = rule.report.first else { return }
        let (readResult, reply) = interface.getReport(.feature, id: id, length: 16)
        let matched = readResult == kIOReturnSuccess && rule.matches(reply)
        let isLast = matched || attempt >= rule.resendAfter.count
        onAttempt(ModeReadBackOutcome(
            attempt: attempt, writeResult: writeResult, readResult: readResult,
            reply: reply, matched: matched, isLast: isLast))
        guard !isLast else { return }
        let previous = attempt == 0 ? 0 : rule.resendAfter[attempt - 1]
        queue.asyncAfter(deadline: .now() + max(0, rule.resendAfter[attempt] - previous)) {
            let written = interface.setReport(.feature, bytes: rule.report)
            confirmMode(rule, on: interface, queue: queue, attempt: attempt + 1,
                        writeResult: written, onAttempt: onAttempt)
        }
    }
}
