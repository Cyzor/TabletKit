// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import IOKit

/// Sends one tablet's control writes in order, off the input thread.
///
/// A `SetReport` can take milliseconds, and some firmware needs writes
/// spaced apart. Neither belongs on the thread that delivers pen reports,
/// so callers enqueue writes here and get each result in a completion.
///
/// `@unchecked Sendable`: `lastPacedWrite` is touched only on `queue`.
public final class HIDOutputQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    private let minimumGapNanos: UInt64
    private var lastPacedWrite: UInt64 = 0

    /// - Parameter minimumGap: the least time between two paced writes.
    public init(label: String, minimumGap: TimeInterval = 0) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        minimumGapNanos = UInt64(max(0, minimumGap) * 1_000_000_000)
    }

    /// Enqueues a report. `bytes` starts with the report ID. `completion`
    /// runs on the queue.
    public func send(
        _ kind: HIDReportKind, _ bytes: [UInt8], to interface: any HIDInterface,
        paced: Bool = false, completion: (@Sendable (IOReturn) -> Void)? = nil
    ) {
        queue.async { [self] in
            if paced { waitForGap() }
            let ret = interface.setReport(kind, bytes: bytes)
            completion?(ret)
        }
    }

    /// Blocks until every write enqueued so far has been sent.
    public func drain() {
        queue.sync {}
    }

    private func waitForGap() {
        let now = DispatchTime.now().uptimeNanoseconds
        if lastPacedWrite != 0, minimumGapNanos > 0 {
            let elapsed = now &- lastPacedWrite
            if elapsed < minimumGapNanos {
                usleep(UInt32((minimumGapNanos - elapsed) / 1_000))
            }
        }
        lastPacedWrite = DispatchTime.now().uptimeNanoseconds
    }
}
