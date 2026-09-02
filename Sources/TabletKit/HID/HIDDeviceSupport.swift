// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import IOKit.hid
import OSLog

private let logger = Logger(subsystem: "com.cyzor.tabletkit", category: "device")

/// Digitizer dimensions in device units for a given tablet model.
public struct DigitizerSpec: Sendable {
    public var maxX: Int
    public var maxY: Int
    public var maxPressure: Int
    /// Number of programmable express-key buttons on this device.
    /// Used by BambooDecoder to select the correct pad-byte bit layout.
    public var buttonCount: Int = 0
    /// True if this device's pen reports carry tilt data.
    /// Currently relevant for BambooDecoder only (report[8]/report[9], 4-bit signed).
    /// IntuosV1/V2/Intuos3 always decode tilt regardless of this flag.
    public var hasTilt: Bool = false
    /// True if this model has two touch rings (one per bezel), e.g. Cintiq 24HD.
    /// Used by CintiqV1Decoder to gate decoding of the second ring byte in 0x0C reports.
    public var hasDualRings: Bool = false
    /// Number of onboard capacitive bezel buttons, e.g. the Cintiq DTK-2400's
    /// three OSD touch buttons. Used by CintiqV1Decoder to select between the
    /// 24HD-family pad layout (bytes 3-4 are capacitive OSD buttons) and the
    /// 21UX2/22HD-family layout (same bytes are touch-strip position instead).
    public var bezelButtonCount: Int = 0
    /// True if this device is a pen display (Cintiq-class) with a built-in screen.
    /// Used to gate pen-display-specific UI (e.g. parallax offset calibration).
    public var isPenDisplay: Bool = false
    /// Number of ring mode slots this device supports.
    /// Matches the number of physical toggle positions (e.g. 4 LED positions on Intuos Pro).
    /// The UI shows this many slots; the model always stores 4 (same pattern as expressKeyBindings).
    public var ringSlotCount: Int = 4
    /// True if this device has capacitive finger touch in addition to the pen.
    /// Mirrors `WacomDeviceSpec.hasFingerTouch`; gates UI for the Touch pane
    /// and the touch-enable feature report.  See `hasFingerTouch` doc there.
    public var hasFingerTouch: Bool = false
    /// Maximum simultaneous touch contacts the device reports (1 for single-touch
    /// Cintiqs like DTH-2400/DTH-2200; 10 for multi-touch DTH-271/DTH-135/DTH-1320).
    public var maxTouchContacts: Int = 0

    public init(
        maxX: Int,
        maxY: Int,
        maxPressure: Int,
        buttonCount: Int = 0,
        hasTilt: Bool = false,
        hasDualRings: Bool = false,
        bezelButtonCount: Int = 0,
        isPenDisplay: Bool = false,
        ringSlotCount: Int = 4,
        hasFingerTouch: Bool = false,
        maxTouchContacts: Int = 0
    ) {
        self.maxX = maxX
        self.maxY = maxY
        self.maxPressure = maxPressure
        self.buttonCount = buttonCount
        self.hasTilt = hasTilt
        self.hasDualRings = hasDualRings
        self.bezelButtonCount = bezelButtonCount
        self.isPenDisplay = isPenDisplay
        self.ringSlotCount = ringSlotCount
        self.hasFingerTouch = hasFingerTouch
        self.maxTouchContacts = maxTouchContacts
    }
}

// Convenience: read an integer property from an IOHIDDevice.
public func hidIntProperty(_ device: IOHIDDevice, _ key: String) -> Int {
    guard let val = IOHIDDeviceGetProperty(device, key as CFString) else { return 0 }
    return (val as? NSNumber)?.intValue ?? 0
}

/// Query the HID descriptor elements for the digitizer's coordinate and pressure ranges.
///
/// Returns `(maxX, maxY, maxPressure)` read from logical-maximum values on
/// Generic Desktop X/Y and Digitizer Tip Pressure elements. Also returns
/// `isLargeReport` (true when MaxInputReportSize > 64) to distinguish IntuosV1
/// from IntuosV2 report families.
///
/// Used by `TabletManager` when building a `WacomDeviceSpec` at runtime —
/// e.g. for the ACK-40401 wireless dongle whose paired-tablet dimensions are
/// encoded in its HID descriptor rather than the static registry.
public func queryHIDDigitizerSpec(_ device: IOHIDDevice)
    -> (maxX: Int, maxY: Int, maxPressure: Int, isLargeReport: Bool)
{
    var maxX = 0
    var maxY = 0
    var maxP = 0
    let maxReportSize = hidIntProperty(device, kIOHIDMaxInputReportSizeKey)
    let isLargeReport = maxReportSize > 64

    guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) else {
        let fallbackP = isLargeReport ? 8191 : 1023
        let (fallbackX, fallbackY) = isLargeReport ? (65535, 40960) : (22860, 14430)
        return (fallbackX, fallbackY, fallbackP, isLargeReport)
    }

    let count = CFArrayGetCount(elements)
    for i in 0..<count {
        // Fix: Safely unwrap the optional pointer returned by CFArrayGetValueAtIndex
        guard let rawPtr = CFArrayGetValueAtIndex(elements, i) else { continue }
        let elem = Unmanaged<IOHIDElement>.fromOpaque(rawPtr).takeUnretainedValue()
        let page = IOHIDElementGetUsagePage(elem)
        let usage = IOHIDElementGetUsage(elem)
        let logMax = IOHIDElementGetLogicalMax(elem)

        if page == 0x01 {
            if usage == 0x30 && logMax > maxX { maxX = logMax }
            if usage == 0x31 && logMax > maxY { maxY = logMax }
        }
        if page == 0x0D && usage == 0x30 && logMax > maxP { maxP = logMax }
    }

    // Fallback values when descriptor doesn't specify X/Y. Large devices (192+ byte reports)
    // get 65535x40960; smaller IntuosV1-family (10-byte) get 22860x14430.
    if maxX == 0 { maxX = isLargeReport ? 65535 : 22860 }
    if maxY == 0 { maxY = isLargeReport ? 40960 : 14430 }
    if maxP == 0 { maxP = isLargeReport ? 8191 : 1023 }
    return (maxX, maxY, maxP, isLargeReport)
}

/// Sends the HID Digitizer Input Mode feature report to switch the device into
/// full tablet mode, unlocking cursor/mouse tool button state in pen reports.
///
/// Searches the device's elements for Usage Page 0x0D (Digitizer) / Usage 0x29
/// (Input Mode), reads its report ID, and sends [reportID, 2]. Call once per
/// interface immediately after a successful IOHIDDeviceOpen.
///
/// No-op when the element is not present on this interface (safe to call on both
/// interfaces of a PTH-660/860 — the vendor interface simply has no match).
public func sendWacomInputModeInit(_ device: IOHIDDevice, tag: String) {
    // Match on the standard HID Digitizer Input Mode usage.
    let match: [String: Any] = ["UsagePage": 0x0D, "Usage": 0x29]
    guard
        let cfArr = IOHIDDeviceCopyMatchingElements(device, match as CFDictionary, 0),
        CFArrayGetCount(cfArr) > 0,
        let rawPtr = CFArrayGetValueAtIndex(cfArr, 0)
    else {
        logger.debug("\(tag, privacy: .public): no InputMode element on this interface — skipping init")
        return
    }

    // CFArrayGetValueAtIndex returns an unretained IOHIDElement reference.
    let elem = Unmanaged<IOHIDElement>.fromOpaque(rawPtr).takeUnretainedValue()
    let reportID = IOHIDElementGetReportID(elem)
    let reportBits = IOHIDElementGetReportSize(elem) * IOHIDElementGetReportCount(elem)
    logger.debug("\(tag, privacy: .public): InputMode element found — reportID=\(reportID, privacy: .public) size=\(reportBits, privacy: .public) bits (\((reportBits + 7) / 8, privacy: .public) bytes payload)")

    // Use IOHIDDeviceSetValue rather than IOHIDDeviceSetReport with a raw byte array.
    // IOHIDDeviceSetReport([reportID, 2]) only sends 2 bytes; if the feature report is
    // longer the device discards it. IOHIDDeviceSetValue lets IOHIDKit build the
    // correctly-sized report from the element descriptor (handles byte offset + padding).
    let value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, elem, 0, 2)
    let ret = IOHIDDeviceSetValue(device, elem, value)
    if ret == kIOReturnSuccess {
        logger.debug("\(tag, privacy: .public): InputMode init OK (reportID=\(reportID, privacy: .public))")
    } else {
        logger.error("\(tag, privacy: .public): InputMode init FAILED (0x\(String(ret, radix: 16, uppercase: true), privacy: .public))")
    }
}
