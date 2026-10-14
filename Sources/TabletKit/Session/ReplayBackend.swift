// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import IOKit

/// Plays a ``ReplayRecording`` to a session, with no hardware.
///
/// Nothing happens until ``play(through:)``, which attaches, delivers, and
/// detaches in the recording's order, synchronously on the caller's thread.
/// Writes are logged on each ``ReplayInterface``.
package final class ReplayBackend: HIDBackend, @unchecked Sendable {
    package let recording: ReplayRecording
    package private(set) var interfaces: [ReplayInterface] = []
    private var attached: (@MainActor (any HIDInterface) -> Void)?
    private var detached: (@MainActor (any HIDInterface) -> Void)?
    private var next = 0

    package init(_ recording: ReplayRecording) {
        self.recording = recording
    }

    @MainActor package func start(
        attached: @escaping @MainActor (any HIDInterface) -> Void,
        detached: @escaping @MainActor (any HIDInterface) -> Void
    ) -> IOReturn {
        self.attached = attached
        self.detached = detached
        interfaces = recording.interfaces.map(ReplayInterface.init)
        next = 0
        return kIOReturnSuccess
    }

    @MainActor package func stop() {
        attached = nil
        detached = nil
    }

    /// Plays events up to, but not including, `end`, or to the end of the
    /// recording. Returns how many events have been played in all.
    @MainActor @discardableResult
    package func play(through end: Int? = nil) -> Int {
        let stop = min(end ?? recording.events.count, recording.events.count)
        while next < stop {
            switch recording.events[next] {
            case .attach(let i): attached?(interfaces[i])
            case .detach(let i): detached?(interfaces[i])
            case .report(let i, let bytes, let ns, _): interfaces[i].deliver(bytes, ns: ns)
            }
            next += 1
        }
        return next
    }
}

/// One recorded interface. Answers feature reads from the recording and
/// logs every write.
///
/// `@unchecked Sendable`: a lock guards the replies and the write log,
/// which an output queue touches. Opening and delivery stay on one thread.
package final class ReplayInterface: HIDInterface, @unchecked Sendable {
    package let recorded: ReplayRecording.Interface
    private let lock = NSLock()
    private var replies: [UInt8: [ReplayRecording.Reply]]
    private var onReport: (@Sendable (HIDReport, UInt64) -> Void)?
    package private(set) var isOpen = false
    package private(set) var seized = false
    private var log: [String] = []
    /// Every write, as "feature 02 02" or "output 02 b0 04".
    package var writes: [String] { lock.withLock { log } }

    package init(_ recorded: ReplayRecording.Interface) {
        self.recorded = recorded
        replies = recorded.featureReplies
    }

    package var vendorID: Int { recorded.vendorID }
    package var productID: Int { recorded.productID }
    package var usagePage: Int { recorded.usagePage }
    package var usage: Int { recorded.usage }
    package var maxOutputReportSize: Int { recorded.maxOutputReportSize }
    package var transport: String { recorded.transport }
    package var productName: String? { recorded.productName }
    package var serialNumber: String? { recorded.serialNumber }
    package var locationID: Int { recorded.locationID }
    package var maxInputReportSize: Int { recorded.maxInputReportSize }
    package var usagePairs: [HIDUsagePair] { recorded.usagePairs }
    package var reportDescriptor: [UInt8] { recorded.reportDescriptor }

    package func setReport(_ kind: HIDReportKind, bytes: [UInt8]) -> IOReturn {
        let line = "\(kind) " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        lock.withLock { log.append(line) }
        return kIOReturnSuccess
    }

    /// The next recorded reply for `id`, or unsupported once they run out.
    package func getReport(_ kind: HIDReportKind, id: UInt8, length: Int) -> (IOReturn, [UInt8]) {
        guard kind == .feature else { return (kIOReturnUnsupported, []) }
        let reply: ReplayRecording.Reply? = lock.withLock {
            guard var queue = replies[id], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            replies[id] = queue
            return next
        }
        guard let reply else { return (kIOReturnUnsupported, []) }
        return (reply.result, Array(reply.bytes.prefix(length)))
    }

    package func readString(index: UInt8) -> [UInt8]? { nil }

    /// Logs the HID Digitizer Input Mode switch, which IOKit builds from the
    /// descriptor's element rather than a raw report.
    package func noteInputMode() { lock.withLock { log.append("inputMode") } }

    package func open(seize: Bool, onReport: @escaping @Sendable (HIDReport, UInt64) -> Void) -> IOReturn {
        isOpen = true
        seized = seize
        self.onReport = onReport
        return kIOReturnSuccess
    }

    package func close() {
        isOpen = false
        onReport = nil
    }

    /// Hands `bytes` to the open callback, in storage exactly that long, as
    /// IOKit would.
    func deliver(_ bytes: [UInt8], ns: UInt64) {
        guard let onReport, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { buffer in
            onReport(HIDReport(pointer: buffer.baseAddress!, count: buffer.count), ns)
        }
    }
}
