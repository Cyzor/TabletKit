// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import IOKit.hid

public enum HIDReportKind: Sendable {
    case input, output, feature
}

/// One HID interface of a tablet, as the code that drives it sees it.
///
/// The seam between TabletKit's device logic and the system's HID stack:
/// ``IOKitHIDInterface`` is the system implementation, and tests supply
/// their own.
public protocol HIDInterface: AnyObject, Sendable {
    var vendorID: Int { get }
    var productID: Int { get }
    var usagePage: Int { get }
    var usage: Int { get }
    /// The longest output report the interface declares, or 0.
    var maxOutputReportSize: Int { get }

    /// Sends a report. `bytes` starts with the report ID.
    func setReport(_ kind: HIDReportKind, bytes: [UInt8]) -> IOReturn
    /// Reads a report into a buffer of `length` bytes.
    func getReport(_ kind: HIDReportKind, id: UInt8, length: Int) -> (IOReturn, [UInt8])
    /// A USB string descriptor, header included, or `nil`.
    func readString(index: UInt8) -> [UInt8]?

    /// How the interface is connected, as the system names it, such as
    /// "USB" or "Bluetooth Low Energy".
    var transport: String { get }
    var productName: String? { get }
    var serialNumber: String? { get }
    var locationID: Int { get }
    /// The longest input report the interface declares, or 0.
    var maxInputReportSize: Int { get }
    /// Every usage page and usage its top-level collections declare.
    var usagePairs: [HIDUsagePair] { get }
    /// The raw report descriptor, or empty when the system doesn't expose one.
    var reportDescriptor: [UInt8] { get }

    /// Opens the interface and starts delivering its input reports on
    /// ``HIDThread``, each with the time it arrived, in nanoseconds of system
    /// uptime. The report's storage is valid only during the call.
    func open(seize: Bool, onReport: @escaping @Sendable (HIDReport, UInt64) -> Void) -> IOReturn
    /// Stops delivery and closes the interface.
    func close()
}

/// One usage page and usage a top-level collection declares.
public struct HIDUsagePair: Sendable, Equatable {
    public var page: Int
    public var usage: Int

    public init(page: Int, usage: Int) {
        self.page = page
        self.usage = usage
    }
}

extension HIDInterface {
    public var transport: String { "" }
    public var productName: String? { nil }
    public var serialNumber: String? { nil }
    public var locationID: Int { 0 }
    public var maxInputReportSize: Int { 0 }
    public var usagePairs: [HIDUsagePair] { [] }
    public var reportDescriptor: [UInt8] { [] }
    public func open(seize: Bool, onReport: @escaping @Sendable (HIDReport, UInt64) -> Void) -> IOReturn {
        kIOReturnUnsupported
    }
    public func close() {}
}

/// An ``HIDInterface`` backed by an `IOHIDDevice`.
///
/// `@unchecked Sendable`: IOKit's report calls are safe from any thread, and
/// the open state is touched only by `open` and `close`, which callers run
/// on one thread.
public final class IOKitHIDInterface: HIDInterface, @unchecked Sendable {
    public let device: IOHIDDevice
    private var buffer: UnsafeMutablePointer<UInt8>?
    private var bufferSize = 0
    private var onReport: (@Sendable (HIDReport, UInt64) -> Void)?

    public init(_ device: IOHIDDevice) { self.device = device }

    deinit { buffer?.deallocate() }

    public var vendorID: Int { hidIntProperty(device, kIOHIDVendorIDKey) }
    public var productID: Int { hidIntProperty(device, kIOHIDProductIDKey) }
    public var usagePage: Int { hidIntProperty(device, kIOHIDPrimaryUsagePageKey) }
    public var usage: Int { hidIntProperty(device, kIOHIDPrimaryUsageKey) }
    public var maxOutputReportSize: Int { hidIntProperty(device, kIOHIDMaxOutputReportSizeKey) }

    public func setReport(_ kind: HIDReportKind, bytes: [UInt8]) -> IOReturn {
        guard let id = bytes.first else { return kIOReturnBadArgument }
        return IOHIDDeviceSetReport(device, kind.ioKit, CFIndex(id), bytes, bytes.count)
    }

    public func getReport(_ kind: HIDReportKind, id: UInt8, length: Int) -> (IOReturn, [UInt8]) {
        var buffer = [UInt8](repeating: 0, count: length)
        buffer[0] = id
        var count = CFIndex(length)
        let ret = IOHIDDeviceGetReport(device, kind.ioKit, CFIndex(id), &buffer, &count)
        return (ret, Array(buffer.prefix(max(0, count))))
    }

    public func readString(index: UInt8) -> [UInt8]? {
        readStringDescriptor(device, index: index)
    }

    public var transport: String { stringProperty(kIOHIDTransportKey) ?? "" }
    public var productName: String? { stringProperty(kIOHIDProductKey) }
    public var serialNumber: String? { stringProperty(kIOHIDSerialNumberKey) }
    public var locationID: Int { hidIntProperty(device, kIOHIDLocationIDKey) }
    public var maxInputReportSize: Int { hidIntProperty(device, kIOHIDMaxInputReportSizeKey) }

    public var usagePairs: [HIDUsagePair] {
        let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? []
        return pairs.compactMap { pair in
            guard let page = pair[kIOHIDDeviceUsagePageKey] as? Int,
                let usage = pair[kIOHIDDeviceUsageKey] as? Int
            else { return nil }
            return HIDUsagePair(page: page, usage: usage)
        }
    }

    public var reportDescriptor: [UInt8] {
        (IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data).map { Array($0) } ?? []
    }

    public func open(seize: Bool, onReport: @escaping @Sendable (HIDReport, UInt64) -> Void) -> IOReturn {
        let options = IOOptionBits(seize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone)
        let ret = IOHIDDeviceOpen(device, options)
        guard ret == kIOReturnSuccess else { return ret }
        self.onReport = onReport
        if buffer == nil {
            bufferSize = max(maxInputReportSize, 192)
            buffer = .allocate(capacity: bufferSize)
        }
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(
            device, buffer!, bufferSize, Self.reportCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
        return ret
    }

    public func close() {
        guard onReport != nil else { return }
        if let buffer {
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, bufferSize, nil, nil)
        }
        IOHIDDeviceUnscheduleFromRunLoop(device, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        onReport = nil
    }

    private static let reportCallback: IOHIDReportWithTimeStampCallback = {
        context, _, _, _, _, report, length, timestamp in
        guard let context else { return }
        let interface = Unmanaged<IOKitHIDInterface>.fromOpaque(context).takeUnretainedValue()
        let ns = timestamp == 0 ? 0 : UInt64(Double(timestamp) * LatencyProbe.timebaseFactor)
        interface.onReport?(HIDReport(pointer: report, count: length), ns)
    }

    private func stringProperty(_ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}

extension HIDReportKind {
    var ioKit: IOHIDReportType {
        switch self {
        case .input: kIOHIDReportTypeInput
        case .output: kIOHIDReportTypeOutput
        case .feature: kIOHIDReportTypeFeature
        }
    }
}
