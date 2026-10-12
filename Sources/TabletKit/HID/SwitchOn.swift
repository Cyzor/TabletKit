// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import IOKit.hid
import IOKit.usb.IOUSBLib

// MARK: - Output reports

/// `bytes` zero-padded to the interface's declared output-report size.
///
/// Firmware that declares a longer report ignores a short write while still
/// reporting success, so pad before sending. Unchanged when the interface
/// declares nothing longer.
public func paddedOutputReport(_ bytes: [UInt8], for device: IOHIDDevice) -> [UInt8] {
    padded(bytes, toSize: hidIntProperty(device, kIOHIDMaxOutputReportSizeKey))
}

func padded(_ bytes: [UInt8], toSize size: Int) -> [UInt8] {
    size > bytes.count ? bytes + [UInt8](repeating: 0, count: size - bytes.count) : bytes
}

/// Sends an output report, padded as ``paddedOutputReport(_:for:)`` does.
/// The first byte is the report ID.
@discardableResult
public func hidSetOutputReport(_ device: IOHIDDevice, bytes: [UInt8]) -> IOReturn {
    guard let reportID = bytes.first else { return kIOReturnBadArgument }
    let report = paddedOutputReport(bytes, for: device)
    return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), report, report.count)
}

// MARK: - String descriptors

/// Reads a USB string descriptor, header included, without opening the
/// device, so it works alongside an open HID connection. `nil` when the
/// device isn't on USB or doesn't answer.
///
/// Some tablets switch on when a particular descriptor is read, and some
/// answer with a description of themselves; see ``UCLogicTabletInfo``.
public func readStringDescriptor(_ device: IOHIDDevice, index: UInt8) -> [UInt8]? {
    // String descriptors belong to the USB device, a few levels above the
    // HID interface.
    var entry = IOHIDDeviceGetService(device)
    IOObjectRetain(entry)
    while entry != 0, IOObjectConformsTo(entry, "IOUSBHostDevice") == 0 {
        var parent: io_registry_entry_t = 0
        let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
        IOObjectRelease(entry)
        entry = kr == KERN_SUCCESS ? parent : 0
    }
    guard entry != 0 else { return nil }
    defer { IOObjectRelease(entry) }

    // IOUSBLib's IDs are C macros Swift can't import.
    let userClientType = CFUUIDGetConstantUUIDWithBytes(
        nil, 0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4, 0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
    let plugInInterface = CFUUIDGetConstantUUIDWithBytes(
        nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    let deviceInterface = CFUUIDGetConstantUUIDWithBytes(
        nil, 0x5C, 0x81, 0x87, 0xD0, 0x9E, 0xF3, 0x11, 0xD4, 0x8B, 0x45, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)

    var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    var score: Int32 = 0
    guard IOCreatePlugInInterfaceForService(entry, userClientType, plugInInterface, &plugIn, &score)
        == kIOReturnSuccess, let plugIn, let plugInTable = plugIn.pointee?.pointee
    else { return nil }
    defer { _ = plugInTable.Release(plugIn) }

    var raw: LPVOID?
    guard plugInTable.QueryInterface(plugIn, CFUUIDGetUUIDBytes(deviceInterface), &raw) == S_OK, let raw
    else { return nil }
    let usb = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface100>.self).pointee.pointee
    defer { _ = usb.Release(raw) }

    var buffer = [UInt8](repeating: 0, count: 255)
    var length = 0
    let result = buffer.withUnsafeMutableBytes { bytes -> IOReturn in
        var request = IOUSBDevRequest(
            bmRequestType: 0x80,  // device to host, standard, device
            bRequest: 6,  // GET_DESCRIPTOR
            wValue: 0x0300 | UInt16(index),  // string descriptor
            wIndex: 0x0409,  // US English
            wLength: UInt16(bytes.count), pData: bytes.baseAddress, wLenDone: 0)
        let kr = usb.DeviceRequest(raw, &request)
        length = Int(request.wLenDone)
        return kr
    }
    return result == kIOReturnSuccess ? Array(buffer.prefix(length)) : nil
}

// MARK: - UC-Logic switch-on

extension UCLogicTabletInfo {
    /// Switches a UC-Logic tablet on and reads what it says about itself.
    ///
    /// Huion and Gaomon tablets switch on when descriptor 200 is read. UGEE
    /// and XP-Pen tablets need output report `02 B0 04` first, sent to the
    /// interface that declares it, so for those this is `nil` until that
    /// interface is passed in. The vendor ID decides which to try, so
    /// neither gets the other's command.
    public init?(readingFrom device: IOHIDDevice, vendorID: Int) {
        if vendorID != 0x28BD,
            let reply = readStringDescriptor(device, index: 200),
            let info = UCLogicTabletInfo(huionDescriptor200: reply)
        {
            self = info
            return
        }
        guard vendorID != 0x256C, Self.declaresOutputReport(device, 0x02) else { return nil }
        hidSetOutputReport(device, bytes: [0x02, 0xB0, 0x04])
        guard let reply = readStringDescriptor(device, index: 100),
            let info = UCLogicTabletInfo(ugeeDescriptor100: reply)
        else { return nil }
        self = info
    }

    private static func declaresOutputReport(_ device: IOHIDDevice, _ reportID: UInt8) -> Bool {
        guard let hex = hidReportDescriptorHex(device),
            let layout = try? HIDReportDescriptorParser.parse(hex: hex)
        else { return false }
        return layout.reports.contains { $0.direction == .output && $0.reportID == reportID }
    }
}
