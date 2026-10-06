// SPDX-License-Identifier: MPL-2.0
//
// pen-surface — a minimal pen driver built on TabletKit, independent of
// MockTab.
//
// A reference sample, not a shipping tool. It moves the cursor, clicks with
// the tip, maps the barrel buttons to right and middle click, and passes
// pressure and tilt to apps that read them. The whole tablet maps to the
// main display. No settings, no ExpressKeys, no Bluetooth. Several tablets
// can be connected at once; each has its own decoder.
//
// Wacom tablets are sized from TabletKit's registry. Huion, Gaomon, XP-Pen,
// and UGEE tablets are sized from their own answer when switched on; see
// the "Supporting Tablets That Describe Themselves" article.
//
// Switch-on: most Wacom tablets start in a reduced mode (the pen moves the
// cursor, but pressure, tilt, tool type or a barrel button can be missing)
// until the host sends a short command. This sample sends the sequence
// TabletKit's registry lists for the connected model, and prints it. Pass
// --init to replace it:
//
//     pen-surface                            registry sequence
//     pen-surface --init none                skip switch-on
//     pen-surface --init 02:02,wait:150,04:00
//
// Each entry is a feature report in hex (first byte is the report ID) or a
// pause in milliseconds. Run with and without to see what switch-on does,
// or try sequences on a tablet the registry lacks. Commands go straight to
// the hardware; send only what you understand. Unplugging resets the mode.
//
// --init applies to Wacom tablets only.
//
// Quit MockTab or your tablet maker's driver first, or both will move the
// cursor.
//
// Injecting events needs Accessibility permission for the terminal
// (System Settings > Privacy & Security > Accessibility).
//
// To run:
//     swift run --package-path <path/to/TabletKit> pen-surface [--init …]

import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid
import IOKit.usb.IOUSBLib
import TabletKit

// MARK: - Arguments

/// nil: use the registry's sequence for the connected model.
var initOverride: [InitStep]?

func parseInitSteps(_ text: String) -> [InitStep]? {
    if text == "none" { return [] }
    var steps: [InitStep] = []
    for entry in text.split(separator: ",") {
        if entry.hasPrefix("wait:") {
            guard let ms = Double(entry.dropFirst(5)), ms >= 0 else { return nil }
            steps.append(.delay(ms / 1000))
        } else {
            let bytes = entry.split(separator: ":").map { UInt8($0, radix: 16) }
            guard !bytes.isEmpty, !bytes.contains(nil) else { return nil }
            steps.append(.featureReport(bytes.compactMap { $0 }))
        }
    }
    return steps
}

let usage = """
    usage: pen-surface [--init none | --init <steps>]
      <steps>  comma-separated: hex feature report (02:02) or pause (wait:150)
    """

var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--init":
        guard let value = args.popFirst(), let steps = parseInitSteps(value) else {
            fputs("pen-surface: --init needs 'none' or steps like 02:02,wait:150,04:00\n", stderr)
            exit(2)
        }
        initOverride = steps
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        fputs("pen-surface: unknown argument '\(arg)'\n\(usage)\n", stderr)
        exit(2)
    }
}

func describe(_ steps: [InitStep]) -> String {
    if steps.isEmpty { return "none" }
    return steps.map { step in
        switch step {
        case .featureReport(let b): return "feature " + b.map { String(format: "%02X", $0) }.joined(separator: " ")
        case .outputReport(let b): return "output " + b.map { String(format: "%02X", $0) }.joined(separator: " ")
        case .delay(let s): return "wait \(Int(s * 1000)) ms"
        case .stringDescriptor(let i): return "string descriptor \(i)"
        }
    }.joined(separator: ", ")
}

// MARK: - Decoder choice

func makeDecoder(_ parser: ReportParser) -> (any TabletReportDecoder)? {
    switch parser {
    case .xencelabs, .ucLogic, .expressKeyRemote: return nil  // not Wacom pens
    default: return parser.makeDecoder()
    }
}

// MARK: - Switch-on

/// True if `device` declares every feature report ID `steps` writes. A
/// tablet can show up as several interfaces, and a write sent to one that
/// lacks the report fails, leaving the tablet in reduced mode.
func declaresFeatureReports(_ device: IOHIDDevice, for steps: [InitStep]) -> Bool {
    let required = Set(steps.compactMap { step -> UInt8? in
        if case .featureReport(let b) = step { return b.first } else { return nil }
    })
    guard !required.isEmpty else { return true }
    guard let hex = hidReportDescriptorHex(device),
        let layout = try? HIDReportDescriptorParser.parse(hex: hex)
    else { return false }
    let declared = Set(layout.reports.filter { $0.direction == .feature }.map(\.reportID))
    return required.isSubset(of: declared)
}

func runSteps(_ steps: ArraySlice<InitStep>, on device: IOHIDDevice) {
    guard let step = steps.first else { return }
    let rest = steps.dropFirst()
    switch step {
    case .featureReport(let bytes):
        let ret = bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(bytes[0]), $0.baseAddress!, $0.count)
        }
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        print("switch-on: feature \(hex) → \(ret == kIOReturnSuccess ? "OK" : String(format: "failed 0x%08X", ret))")
        runSteps(rest, on: device)
    case .delay(let seconds):
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { runSteps(rest, on: device) }
    case .outputReport, .stringDescriptor:
        print("switch-on: skipping \(describe([step])) (this sample sends feature reports only)")
        runSteps(rest, on: device)
    }
}

// MARK: - Tablets that describe themselves

let wacomVendorID = 0x056A
/// Huion and Gaomon; XP-Pen, UGEE, and Parblo; older UC-Logic tablets.
let ucLogicVendorIDs = [0x256C, 0x28BD, 0x5543]

/// Reads a USB string descriptor, header included, without opening the
/// device, so it works alongside our own HID connection.
func readStringDescriptor(_ device: IOHIDDevice, index: UInt8) -> [UInt8]? {
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

/// True if `device` declares output report `reportID`.
func declaresOutputReport(_ device: IOHIDDevice, _ reportID: UInt8) -> Bool {
    guard let hex = hidReportDescriptorHex(device),
        let layout = try? HIDReportDescriptorParser.parse(hex: hex)
    else { return false }
    return layout.reports.contains { $0.direction == .output && $0.reportID == reportID }
}

/// Switches a UC-Logic tablet on and reads what it says about itself.
///
/// Huion tablets switch on when descriptor 200 is read. UGEE tablets need
/// output report `02 B0 04` first, sent to the interface that declares it,
/// so for those this returns `nil` until that interface turns up. The
/// vendor ID says which to try, so neither tablet gets the other's command.
func switchOnAndDescribe(_ device: IOHIDDevice, vendor: Int) -> UCLogicTabletInfo? {
    if vendor != 0x28BD,
        let reply = readStringDescriptor(device, index: 200),
        let info = UCLogicTabletInfo(huionDescriptor200: reply)
    {
        return info
    }
    guard vendor != 0x256C, declaresOutputReport(device, 0x02) else { return nil }
    // The firmware ignores a short write; pad to the declared report size.
    let size = max(hidIntProperty(device, kIOHIDMaxOutputReportSizeKey), 3)
    let command: [UInt8] = [0x02, 0xB0, 0x04] + [UInt8](repeating: 0, count: size - 3)
    let ret = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x02, command, command.count)
    print("switch-on: output 02 B0 04, padded to \(size) bytes → \(ret == kIOReturnSuccess ? "OK" : String(format: "failed 0x%08X", ret))")
    return readStringDescriptor(device, index: 100).flatMap(UCLogicTabletInfo.init(ugeeDescriptor100:))
}

// MARK: - Runner

/// One connected tablet: its spec, its decoder, and the decoder's state.
/// Every tablet gets its own, so two tablets never share a decoder.
final class Tablet {
    let name: String
    let spec: DigitizerSpec
    let family: DeviceFamily
    var decoder: any TabletReportDecoder
    var state = DecoderState()
    var initSent = false
    /// Fires when a tablet that never reports the pen leaving goes quiet.
    var silenceTimer: Timer?

    init(name: String, spec: DigitizerSpec, family: DeviceFamily, decoder: any TabletReportDecoder) {
        self.name = name
        self.spec = spec
        self.family = family
        self.decoder = decoder
    }
}

/// The context for one interface's report callback, so each report reaches
/// the tablet it came from.
final class Listener {
    let tablet: Tablet
    unowned let runner: PenSurfaceRunner

    init(tablet: Tablet, runner: PenSurfaceRunner) {
        self.tablet = tablet
        self.runner = runner
    }
}

final class PenSurfaceRunner {
    /// Connected tablets, keyed by vendor and product ID.
    var tablets: [Int: Tablet] = [:]
    var listeners: [Listener] = []
    /// Interfaces of UC-Logic tablets that haven't answered yet.
    var waiting: [Int: [IOHIDDevice]] = [:]

    let screen = CGDisplayBounds(CGMainDisplayID())
    var tipDown = false
    var button1Down = false
    var button2Down = false
    var lastStatus = Date.distantPast

    // What the tablets have reported so far. With --init none, some stay no.
    var seenPressure = false
    var seenTilt = false
    var seenButton2 = false
    var seenTool = false

    func handleInterface(_ device: IOHIDDevice) {
        let vendor = hidIntProperty(device, kIOHIDVendorIDKey)
        if vendor == wacomVendorID {
            handleWacom(device)
        } else {
            handleUCLogic(device, vendor: vendor)
        }
    }

    /// Returns the tablet with `id`, adding it if it's new.
    func tablet(
        id: Int, name: String, spec: DigitizerSpec, family: DeviceFamily,
        decoder: @autoclosure () -> any TabletReportDecoder
    ) -> (tablet: Tablet, isNew: Bool) {
        if let existing = tablets[id] { return (existing, false) }
        let added = Tablet(name: name, spec: spec, family: family, decoder: decoder())
        tablets[id] = added
        print("Connected: \(name)  (\(String(format: "%04X:%04X", id >> 16, id & 0xFFFF)))")
        return (added, true)
    }

    func listen(to device: IOHIDDevice, for tablet: Tablet) {
        let listener = Listener(tablet: tablet, runner: self)
        listeners.append(listener)  // keeps the callback's context alive
        let size = max(hidIntProperty(device, kIOHIDMaxInputReportSizeKey), 512)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)  // lives as long as the device
        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, size, Self.reportCallback, Unmanaged.passUnretained(listener).toOpaque())
    }

    func handleWacom(_ device: IOHIDDevice) {
        let pid = hidIntProperty(device, kIOHIDProductIDKey)
        guard let found = WacomDeviceRegistry.spec(for: pid) else {
            fputs("PID 0x\(String(pid, radix: 16)) is not in TabletKit's registry — ignoring\n", stderr)
            return
        }
        guard let decoder = makeDecoder(found.parser) else { return }

        let (tablet, isNew) = tablet(
            id: wacomVendorID << 16 | pid, name: found.name, spec: found.digitizerSpec,
            family: found.family, decoder: decoder)
        if isNew {
            print("switch-on sequence: \(describe(initOverride ?? found.initSteps))\(initOverride == nil ? " (registry)" : " (--init)")")
        }

        if found.seizeUSB {
            // Keeps macOS's own mouse driver from also moving the cursor.
            IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }
        listen(to: device, for: tablet)

        let steps = initOverride ?? found.initSteps
        if !tablet.initSent, declaresFeatureReports(device, for: steps) {
            tablet.initSent = true
            runSteps(steps[...], on: device)
        }
        // Intuos Pro (PTH-x60) also needs its input mode set on USB, or it
        // sends touch but no pen. Part of switch-on, so --init none skips it.
        if found.parser == .intuosV2, initOverride?.isEmpty != true {
            sendWacomInputModeInit(device, tag: found.name)
        }
    }

    func handleUCLogic(_ device: IOHIDDevice, vendor: Int) {
        let id = vendor << 16 | hidIntProperty(device, kIOHIDProductIDKey)
        if let known = tablets[id] {
            listen(to: device, for: known)
            return
        }
        // Interfaces arrive one at a time, and only one can switch a UGEE
        // tablet on. Hold the others until the tablet answers.
        waiting[id, default: []].append(device)
        guard let info = switchOnAndDescribe(device, vendor: vendor) else { return }

        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "UC-Logic tablet"
        let (tablet, _) = tablet(
            id: id, name: name, spec: info.digitizerSpec, family: .ucLogic,
            decoder: UCLogicDecoder(protocol: info.tabletProtocol))
        print("It describes itself (\(info.tabletProtocol)): \(info.maxX) × \(info.maxY), pressure \(info.maxPressure), \(info.lpi) lines per inch")
        if VendorDeviceRegistry.drivableProfile(forVendorID: vendor, productID: id & 0xFFFF) != nil {
            print("TabletKit also has a dedicated decoder for this tablet; this sample uses the self-description anyway.")
        }
        for interface in waiting.removeValue(forKey: id) ?? [] {
            listen(to: interface, for: tablet)
        }
    }

    func handleReport(_ report: UnsafePointer<UInt8>, length: CFIndex, from tablet: Tablet) {
        handle(
            tablet.decoder.decode(
                report: HIDReport(pointer: report, count: length), spec: tablet.spec,
                state: &tablet.state, deviceFamily: tablet.family))

        // Some tablets never say the pen left; they go quiet. Decoders don't
        // read the clock, so watch for the silence here.
        if let timeout = tablet.decoder.silenceTimeout {
            tablet.silenceTimer?.invalidate()
            tablet.silenceTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) {
                [weak self, weak tablet] _ in
                guard let self, let tablet else { return }
                self.handle(
                    tablet.decoder.decodeSilence(
                        spec: tablet.spec, state: &tablet.state, deviceFamily: tablet.family))
            }
        }
    }

    func handle(_ results: [DecodeResult]) {
        for result in results {
            switch result {
            case .pen(let point): handlePen(point)
            case .toolEnter: seenTool = true
            default: break
            }
        }
    }

    func handlePen(_ p: TabletPoint) {
        let location = CGPoint(
            x: screen.minX + screen.width * Double(p.x) / Double(max(p.maxX, 1)),
            y: screen.minY + screen.height * Double(p.y) / Double(max(p.maxY, 1)))
        let pressure = p.normalizedPressure
        if pressure > 0 { seenPressure = true }
        if p.tiltX != 0 || p.tiltY != 0 { seenTilt = true }
        if p.penButton2 { seenButton2 = true }

        // Same threshold MockTab uses; below it is sensor noise, not contact.
        let down = p.inProximity && pressure > 0.004

        if down != tipDown {
            tipDown = down
            post(down ? .leftMouseDown : .leftMouseUp, .left, at: location, point: p)
        } else {
            post(down ? .leftMouseDragged : .mouseMoved, .left, at: location, point: p)
        }
        if p.penButton1 != button1Down {
            button1Down = p.penButton1
            post(button1Down ? .rightMouseDown : .rightMouseUp, .right, at: location, point: p)
        }
        if p.penButton2 != button2Down {
            button2Down = p.penButton2
            post(button2Down ? .otherMouseDown : .otherMouseUp, .center, at: location, point: p)
        }
        printStatus(p)
    }

    func post(_ type: CGEventType, _ button: CGMouseButton, at location: CGPoint, point p: TabletPoint) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button)
        else { return }
        // Subtype first: the tablet fields share storage keyed by it. Apps
        // differ in which pressure field they read, so set both.
        e.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        e.setIntegerValueField(.tabletEventDeviceID, value: 1)
        e.setIntegerValueField(.tabletEventPointButtons, value: tipDown ? 1 : 0)
        e.setDoubleValueField(.tabletEventPointPressure, value: tipDown ? p.normalizedPressure : 0)
        e.setDoubleValueField(.mouseEventPressure, value: tipDown ? p.normalizedPressure : 0)
        // TabletKit uses the HID tilt convention; macOS's Y axis is flipped.
        e.setDoubleValueField(.tabletEventTiltX, value: p.tiltX)
        e.setDoubleValueField(.tabletEventTiltY, value: -p.tiltY)
        e.setDoubleValueField(.tabletEventRotation, value: p.rotation)
        if type == .leftMouseDown || type == .leftMouseUp {
            e.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        e.post(tap: .cghidEventTap)
    }

    /// One status line, redrawn at most 10 times a second.
    func printStatus(_ p: TabletPoint) {
        guard Date().timeIntervalSince(lastStatus) > 0.1 else { return }
        lastStatus = Date()
        let yn = { (b: Bool) in b ? "yes" : "no " }
        let line = String(
            format: "x %6d  y %6d  pressure %4d/%d  tilt %+.2f %+.2f  buttons %@%@%@%@   seen: pressure %@ tilt %@ button 2 %@ tool ID %@",
            p.x, p.y, p.pressure, p.maxPressure, p.tiltX, p.tiltY,
            tipDown ? "T" : "-", p.penButton1 ? "1" : "-", p.penButton2 ? "2" : "-", p.penButton3 ? "3" : "-",
            yn(seenPressure), yn(seenTilt), yn(seenButton2), yn(seenTool))
        print("\r" + line, terminator: "")
        fflush(stdout)
    }

    static let deviceCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<PenSurfaceRunner>.fromOpaque(context).takeUnretainedValue().handleInterface(device)
    }

    static let reportCallback: IOHIDReportCallback = { context, _, _, _, _, report, length in
        guard let context else { return }
        let listener = Unmanaged<Listener>.fromOpaque(context).takeUnretainedValue()
        listener.runner.handleReport(report, length: length, from: listener.tablet)
    }
}

// MARK: - Startup

print("pen-surface — TabletKit minimal pen driver sample")
if !AXIsProcessTrusted() {
    fputs("Accessibility permission missing: pen input will decode but not reach the cursor.\n", stderr)
}
print("Tip: left click. Lower barrel button: right click. Upper: middle click. Ctrl-C quits.")
print("Waiting for a Wacom, Huion, Gaomon, XP-Pen, or UGEE tablet over USB…")

let runner = PenSurfaceRunner()
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matching = ([wacomVendorID] + ucLogicVendorIDs).map { [kIOHIDVendorIDKey: $0] }
IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
IOHIDManagerRegisterDeviceMatchingCallback(
    manager, PenSurfaceRunner.deviceCallback, Unmanaged.passUnretained(runner).toOpaque())
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard openResult == kIOReturnSuccess else {
    fputs("Failed to open IOHIDManager: \(openResult)\n", stderr)
    exit(1)
}
CFRunLoopRun()
