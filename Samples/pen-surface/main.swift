// SPDX-License-Identifier: MPL-2.0
//
// pen-surface — a minimal pen driver built on TabletKit, independent of
// MockTab.
//
// A reference sample, not a shipping tool. It moves the cursor, clicks with
// the tip, maps the barrel buttons to right and middle click, and passes
// pressure and tilt to apps that read them. The whole tablet maps to the
// main display. No settings, no ExpressKeys, no Bluetooth, one tablet at a
// time.
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
// Quit MockTab or Wacom's driver first, or both will move the cursor.
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
    case .intuosV1: return IntuosV1Decoder()
    case .intuosV2: return IntuosV2Decoder()
    case .intuosV3: return IntuosV3Decoder()
    case .intuos3: return Intuos3Decoder()
    case .bamboo: return BambooDecoder()
    case .cintiqV1: return CintiqV1Decoder()
    case .graphire: return GraphireDecoder()
    case .dtus: return DTUSDecoder()
    case .dtu: return DTUDecoder()
    case .pl: return WacomPLDecoder()
    case .xencelabs, .expressKeyRemote: return nil  // not Wacom pens
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

// MARK: - Runner

final class PenSurfaceRunner {
    var spec: WacomDeviceSpec?
    var digiSpec: DigitizerSpec?
    var decoder: (any TabletReportDecoder)?
    var decoderState = DecoderState()
    var interfaces: [IOHIDDevice] = []
    var initSent = false

    let screen = CGDisplayBounds(CGMainDisplayID())
    var tipDown = false
    var button1Down = false
    var button2Down = false
    var lastStatus = Date.distantPast

    // What this tablet has reported so far. With --init none, some stay no.
    var seenPressure = false
    var seenTilt = false
    var seenButton2 = false
    var seenTool = false

    func handleInterface(_ device: IOHIDDevice) {
        let pid = hidIntProperty(device, kIOHIDProductIDKey)
        guard let found = WacomDeviceRegistry.spec(for: pid) else {
            fputs("PID 0x\(String(pid, radix: 16)) is not in TabletKit's registry — ignoring\n", stderr)
            return
        }
        guard let newDecoder = makeDecoder(found.parser) else { return }

        // A different tablet takes over; another interface of the same one joins.
        if spec?.productID != found.productID {
            spec = found
            digiSpec = found.digitizerSpec
            decoder = newDecoder
            decoderState = DecoderState()
            interfaces = []
            initSent = false
            seenPressure = false; seenTilt = false; seenButton2 = false; seenTool = false
            print("Connected: \(found.name)  (PID \(String(format: "0x%04X", pid)))")
            print("switch-on sequence: \(describe(initOverride ?? found.initSteps))\(initOverride == nil ? " (registry)" : " (--init)")")
        }
        interfaces.append(device)

        if found.seizeUSB {
            // Keeps macOS's own mouse driver from also moving the cursor.
            IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }

        let size = max(hidIntProperty(device, kIOHIDMaxInputReportSizeKey), 512)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)  // lives as long as the device
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, size, Self.reportCallback, context)

        let steps = initOverride ?? found.initSteps
        if !initSent, declaresFeatureReports(device, for: steps) {
            initSent = true
            runSteps(steps[...], on: device)
        }
        // Intuos Pro (PTH-x60) also needs its input mode set on USB, or it
        // sends touch but no pen. Part of switch-on, so --init none skips it.
        if found.parser == .intuosV2, initOverride?.isEmpty != true {
            sendWacomInputModeInit(device, tag: found.name)
        }
    }

    func handleReport(_ report: UnsafePointer<UInt8>, length: CFIndex) {
        guard let spec, let digiSpec, var decoder else { return }
        let results = decoder.decode(
            report: report, length: length, spec: digiSpec,
            state: &decoderState, deviceFamily: spec.family)
        self.decoder = decoder  // value type: keep the mutated copy

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
            format: "x %6d  y %6d  pressure %4d/%d  tilt %+.2f %+.2f  buttons %@%@%@   seen: pressure %@ tilt %@ button 2 %@ tool ID %@",
            p.x, p.y, p.pressure, p.maxPressure, p.tiltX, p.tiltY,
            tipDown ? "T" : "-", p.penButton1 ? "1" : "-", p.penButton2 ? "2" : "-",
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
        Unmanaged<PenSurfaceRunner>.fromOpaque(context).takeUnretainedValue().handleReport(report, length: length)
    }
}

// MARK: - Startup

print("pen-surface — TabletKit minimal pen driver sample")
if !AXIsProcessTrusted() {
    fputs("Accessibility permission missing: pen input will decode but not reach the cursor.\n", stderr)
}
print("Tip: left click. Lower barrel button: right click. Upper: middle click. Ctrl-C quits.")
print("Waiting for a Wacom tablet over USB…")

let runner = PenSurfaceRunner()
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x056A] as CFDictionary)  // Wacom
IOHIDManagerRegisterDeviceMatchingCallback(
    manager, PenSurfaceRunner.deviceCallback, Unmanaged.passUnretained(runner).toOpaque())
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard openResult == kIOReturnSuccess else {
    fputs("Failed to open IOHIDManager: \(openResult)\n", stderr)
    exit(1)
}
CFRunLoopRun()
