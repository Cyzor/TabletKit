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
}

/// An ``HIDInterface`` backed by an `IOHIDDevice`.
///
/// `@unchecked Sendable`: it holds only the device reference, and IOKit's
/// report calls are safe from any thread.
public final class IOKitHIDInterface: HIDInterface, @unchecked Sendable {
    public let device: IOHIDDevice

    public init(_ device: IOHIDDevice) { self.device = device }

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
