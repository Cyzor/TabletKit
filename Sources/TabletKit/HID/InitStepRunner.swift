// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import IOKit

/// What one init step did.
public struct InitStepOutcome: Sendable {
    public let index: Int
    public let step: InitStep
    /// The write's result; `nil` for delays and string reads.
    public let result: IOReturn?
    /// Bytes actually sent, after padding.
    public let sentLength: Int
    /// A string read's reply.
    public let reply: [UInt8]?
}

/// Runs a tablet's ``InitStep``s in order against one interface.
///
/// Output reports are padded to the interface's declared size. Steps run on
/// the caller's thread until a delay; after one, the rest run on `queue`.
public enum InitStepRunner {
    public static func run(
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
}
