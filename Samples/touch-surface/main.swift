// SPDX-License-Identifier: MPL-2.0
//
// touch-surface — turn a Wacom tablet's touch sensor into a standalone
// gesture surface, independent of MockTab.
//
// This is a reference sample, not a shipping tool. It shows what you can
// build directly on TabletKit's touch decoding: single-finger cursor
// movement, single-finger tap for left-click, two-finger pan (scroll),
// two-finger pinch-zoom, and two-finger tap for right-click.
//
// It works with any Wacom tablet whose touch report TabletKit can decode
// from a fixed coordinate range in the registry — the intuosV1, intuosV2,
// and bamboo parser families, around 20 devices from the original Bamboo
// Pen & Touch through the Cintiq Pro line. A handful of newer Cintiq
// Pro/DTH displays decode touch from their live HID descriptor instead of a
// fixed registry range (`PrecisionTouchDecoder`); this sample doesn't
// implement that path, and says so if one connects. See `resolveDevice`
// below for the exact rule.
//
// This sample drives one tablet at a time. If several are attached, it
// ignores any it can't handle and uses the most recent supported one to
// connect — it doesn't decode multiple tablets at once.
//
// Unlike TabletKit's other samples, this one has real side effects: it
// opens a live HID device and injects system input via CGEvent. TabletKit
// itself does neither. This sample steps outside that boundary on purpose,
// to show the library is useful for exactly this kind of app.
//
// Injecting events normally needs Accessibility permission (System
// Settings > Privacy & Security > Accessibility). Running from a terminal
// that's already trusted seems to extend that trust to processes it
// launches, at least on the macOS version this was tested against — no
// per-binary grant needed. Not confirmed on an untrusted terminal or other
// macOS versions; if events stop injecting, check the AXIsProcessTrusted()
// message this prints at startup.
//
// To run:
//     swift run --package-path <path/to/TabletKit> touch-surface

import ApplicationServices
import Foundation
import IOKit.hid
import CoreGraphics
import TabletKit

if !AXIsProcessTrusted() {
    fputs("Accessibility permission not granted for this exact binary — gestures will be recognized but nothing will be injected. Grant it at System Settings > Privacy & Security > Accessibility, then restart.\n", stderr)
}

// MARK: - Runner
//
// IOKit's HID callbacks are C function pointers, which can't capture Swift
// closure state. All mutable state lives on this class instead, reached
// through the `context` pointer both callbacks receive.

/// What this sample needs to know about a connected device before it can
/// decode anything from it. Built once per connection, in
/// `TouchSurfaceRunner.handleDeviceConnected`, from whichever product ID
/// IOKit reports — not known in advance, since this sample matches any
/// Wacom vendor device rather than one fixed product.
struct ResolvedDevice {
    let spec: WacomDeviceSpec
    let digiSpec: DigitizerSpec
    let deviceUnitsPerMM: Double
    let pinchDominanceRatio: Double
}

struct UnsupportedDevice: Error {
    let reason: String
}

/// Picks a decoder and gesture tuning for `spec`, or explains why this
/// sample can't handle it.
///
/// A device is unsupported when it has no touch sensor, or when its touch
/// range (`touchMaxX`/`touchMaxY`) is 0 in the registry. The second case
/// covers six Cintiq Pro/DTH displays that decode touch from their live HID
/// descriptor (`PrecisionTouchDecoder`) rather than a fixed registry range
/// — an architecture this sample doesn't implement. Every other
/// touch-capable device in the registry has a real touch range and uses the
/// `.intuosV1`, `.intuosV2`, or `.bamboo` parser.
func resolveDevice(_ spec: WacomDeviceSpec) -> Result<(ResolvedDevice, any TabletReportDecoder), UnsupportedDevice> {
    guard spec.hasFingerTouch else {
        return .failure(UnsupportedDevice(reason: "\(spec.name) has no touch sensor per the registry"))
    }
    guard spec.touchMaxX > 0, spec.touchMaxY > 0 else {
        return .failure(UnsupportedDevice(reason: """
            \(spec.name)'s touch decoding is HID-descriptor-driven (PrecisionTouchDecoder), \
            which this sample doesn't implement. Supported: any Wacom touch device with a \
            fixed touchMaxX/Y in TabletKit's registry (Bamboo, Intuos, and Intuos Pro families).
            """))
    }

    let digiSpec = DigitizerSpec(
        maxX: spec.maxX,
        maxY: spec.maxY,
        maxPressure: spec.maxPressure,
        buttonCount: spec.buttonCount,
        hasTilt: spec.hasTilt,
        hasFingerTouch: spec.hasFingerTouch,
        maxTouchContacts: spec.maxTouchContacts)

    let decoder: any TabletReportDecoder
    // pinchDominanceRatio needs a different value per touch-sensor
    // generation, not one constant — see GestureRecognizer.swift for why.
    // 1.75 is MockTab's own value for the newer BPT3 5-slot sensor
    // (intuosV2, bamboo); 5.0 is this sample's own estimate for the older
    // 16-slot sensor (intuosV1), tuned against a PTH-850.
    let pinchDominanceRatio: Double
    switch spec.parser {
    case .intuosV1:
        decoder = IntuosV1Decoder()
        pinchDominanceRatio = 5.0
    case .intuosV2:
        decoder = IntuosV2Decoder()
        pinchDominanceRatio = 1.75
    case .bamboo:
        decoder = BambooDecoder()
        pinchDominanceRatio = 1.75
    default:
        return .failure(UnsupportedDevice(reason: "\(spec.name) uses \(spec.parser), which this sample has no decoder mapping for"))
    }

    let deviceUnitsPerMM = Double(spec.touchMaxX) / (spec.activeWidthMM ?? Double(spec.touchMaxX) / 40.0)

    let resolved = ResolvedDevice(
        spec: spec, digiSpec: digiSpec,
        deviceUnitsPerMM: deviceUnitsPerMM, pinchDominanceRatio: pinchDominanceRatio)
    return .success((resolved, decoder))
}

final class TouchSurfaceRunner {
    var resolved: ResolvedDevice?
    var decoder: (any TabletReportDecoder)?
    var decoderState = DecoderState()
    var recognizer: GestureRecognizer?
    let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)

    deinit {
        reportBuffer.deallocate()
    }

    /// Called once per matched Wacom device IOKit connects. With several
    /// tablets attached, some may not be usable (see `resolveDevice`) —
    /// those are logged and ignored rather than treated as fatal, so one
    /// unsupported tablet doesn't stop a supported one from working.
    func handleDeviceConnected(_ device: IOHIDDevice) {
        let rawProductID = hidIntProperty(device, kIOHIDProductIDKey)
        guard let spec = WacomDeviceRegistry.spec(for: rawProductID) else {
            fputs("Connected device (PID 0x\(String(rawProductID, radix: 16))) is not in TabletKit's registry — ignoring\n", stderr)
            return
        }
        switch resolveDevice(spec) {
        case .failure(let error):
            fputs("\(spec.name): \(error.reason) — ignoring this device\n", stderr)
            return
        case .success(let (resolved, decoder)):
            self.resolved = resolved
            self.decoder = decoder
            self.recognizer = GestureRecognizer(
                deviceUnitsPerMM: resolved.deviceUnitsPerMM,
                pinchDominanceRatio: resolved.pinchDominanceRatio)
            print("Connected: \(spec.name)  (PID \(String(format: "0x%04X", rawProductID)))  descriptor \(hidReportDescriptorHex(device) != nil ? "OK" : "unavailable")")
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 512, Self.reportCallback, context)
    }

    func handleReport(length: CFIndex) {
        guard let resolved, var decoder, let recognizer else { return }
        let results = decoder.decode(
            report: reportBuffer,
            length: length,
            spec: resolved.digiSpec,
            state: &decoderState,
            deviceFamily: resolved.spec.family)
        self.decoder = decoder  // decoders are value types — write the mutated copy back

        for result in results {
            guard case .touch(let contacts) = result else { continue }
            if ProcessInfo.processInfo.environment["TOUCH_SURFACE_DEBUG"] != nil {
                let desc = contacts.map { "id=\($0.id) x=\($0.x) y=\($0.y)" }.joined(separator: " | ")
                print("[touch] \(contacts.count) contact(s): \(desc)")
            }
            guard let gesture = recognizer.process(contacts) else { continue }
            dispatch(gesture)
        }
    }

    static let deviceCallback: IOHIDDeviceCallback = { context, result, sender, device in
        guard let context else { return }
        Unmanaged<TouchSurfaceRunner>.fromOpaque(context).takeUnretainedValue().handleDeviceConnected(device)
    }

    static let reportCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, length in
        guard let context else { return }
        Unmanaged<TouchSurfaceRunner>.fromOpaque(context).takeUnretainedValue().handleReport(length: length)
    }
}

// MARK: - Gesture -> system input
//
// The pinch/scroll injection technique — CGEvent type 29 with a set of
// undocumented-but-public fields — comes from MockTab's own touch injection
// (InputInjector+Touch.swift), which traces it to the open-source Mac Mouse
// Fix project (github.com/noah-nuebling/mac-mouse-fix, TouchSimulator.m).
// Reimplemented independently here, not copied.

/// The screen position this sample last posted to. Tracked locally rather
/// than read back from the system: reading `CGEvent(source: nil)?.location`
/// after every move would read back this sample's own last post, and the
/// small rounding error in each read-back compounds every frame into a
/// cursor that visibly lags or drifts from the finger driving it. Seeded
/// once from the real system location at startup, then only ever updated
/// from this sample's own posts.
var virtualCursor: CGPoint = CGEvent(source: nil)?.location ?? .zero

// A magnify or scroll gesture needs an explicit .began event before any
// .changed deltas, or the receiving app never opens a gesture session and
// nothing visible happens — even though the events post without error. Pan
// and pinch each track their own open/close state below, closing after a
// short idle gap since this sample has no per-frame ticker to watch for the
// gesture actually ending.
var panPhaseOpen = false
var lastPanAt = Date.distantPast
let panIdleTimeout: TimeInterval = 0.15

var pinchPhaseOpen = false
var lastPinchAt = Date.distantPast
let pinchIdleTimeout: TimeInterval = 0.15

let nsEventTypeGesture = CGEventType(rawValue: 29)!
let fieldIOHIDEventSubtype = CGEventField(rawValue: 110)!
let fieldMagnification = CGEventField(rawValue: 113)!
let fieldGestureDeltaX = CGEventField(rawValue: 116)!
let fieldGestureDeltaY = CGEventField(rawValue: 119)!
let fieldGesturePhase = CGEventField(rawValue: 132)!
let iohidEventTypeScroll: Int64 = 6
let iohidEventTypeZoom: Int64 = 8

/// Raw values for the wire-level gesture phase field, confirmed against a
/// real trackpad pinch with a diagnostic CGEvent tap: 1/2/4 for
/// began/changed/ended. These are NOT the same as `NSEvent.Phase`'s raw
/// values (4/8/16, a different enum at a different layer) — using
/// `NSEvent.Phase`'s numbers here means "began" reads as "ended" and
/// "changed" matches nothing, so the OS never opens a gesture session. That
/// was the actual reason an early version of this sample could log correct
/// pinch values but never make anything visibly zoom.
enum GesturePhase: Int64 {
    case began = 1
    case changed = 2
    case ended = 4
}

func postGestureScroll(dx: Double, dy: Double, phase: GesturePhase, at location: CGPoint) {
    guard let e = CGEvent(source: nil) else { return }
    e.type = nsEventTypeGesture
    e.location = location
    e.setIntegerValueField(fieldIOHIDEventSubtype, value: iohidEventTypeScroll)
    e.setIntegerValueField(fieldGesturePhase, value: phase.rawValue)
    e.setDoubleValueField(fieldGestureDeltaX, value: dx)
    e.setDoubleValueField(fieldGestureDeltaY, value: dy)
    e.post(tap: .cghidEventTap)
}

func postGestureMagnify(magnification: Double, phase: GesturePhase, at location: CGPoint) {
    guard let e = CGEvent(source: nil) else { return }
    e.type = nsEventTypeGesture
    e.location = location
    e.setIntegerValueField(fieldIOHIDEventSubtype, value: iohidEventTypeZoom)
    e.setIntegerValueField(fieldGesturePhase, value: phase.rawValue)
    e.setDoubleValueField(fieldMagnification, value: magnification)
    e.post(tap: .cghidEventTap)
}

func dispatch(_ gesture: Gesture) {
    if ProcessInfo.processInfo.environment["TOUCH_SURFACE_DEBUG"] != nil {
        print("[gesture] \(gesture)")
    }

    // Close a still-open pan or pinch if this event is a different gesture
    // and enough time has passed since the last one.
    if case .pan = gesture {} else if panPhaseOpen, Date().timeIntervalSince(lastPanAt) > panIdleTimeout {
        postGestureScroll(dx: 0, dy: 0, phase: .ended, at: virtualCursor)
        panPhaseOpen = false
    }
    if case .pinch = gesture {} else if pinchPhaseOpen, Date().timeIntervalSince(lastPinchAt) > pinchIdleTimeout {
        postGestureMagnify(magnification: 0, phase: .ended, at: virtualCursor)
        pinchPhaseOpen = false
    }

    switch gesture {
    case .cursorMove(let dx, let dy):
        // Demonstrates that a single finger can move the system cursor,
        // the same way the pen does, without the stylus.
        //
        // `mouseCursorPosition` alone would warp the cursor to an absolute
        // point. CGEvent has no "move by" constructor, so a relative move
        // needs both the new position and the deltaX/deltaY fields set
        // together — the position moves the cursor, the deltas are what
        // apps read for real relative-motion tracking.
        let scale = 0.3
        let dxScaled = Double(dx) * scale
        let dyScaled = Double(dy) * scale
        virtualCursor = CGPoint(x: virtualCursor.x + dxScaled, y: virtualCursor.y + dyScaled)
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: virtualCursor, mouseButton: .left)
        else { return }
        event.setDoubleValueField(.mouseEventDeltaX, value: dxScaled)
        event.setDoubleValueField(.mouseEventDeltaY, value: dyScaled)
        event.post(tap: .cghidEventTap)

    case .pan(let dx, let dy):
        // Scroll direction follows the real Natural Scrolling preference
        // (System Settings > Trackpad), read the same way MockTab's
        // `InputInjector.naturalScrollingEnabled` does — not hardcoded
        // either way, since it's a genuine user setting.
        let naturalScrollingEnabled = UserDefaults.standard.bool(forKey: "com.apple.swipescrolldirection")
        let directionSign: Double = naturalScrollingEnabled ? 1 : -1
        let scale = 0.6 * directionSign
        let dxScaled = Double(dx) * scale
        let dyScaled = Double(dy) * scale

        let phase: GesturePhase = panPhaseOpen ? .changed : .began
        postGestureScroll(dx: dxScaled, dy: dyScaled, phase: phase, at: virtualCursor)
        panPhaseOpen = true
        lastPanAt = Date()

        // .pixel units plus scrollWheelEventIsContinuous is what makes apps
        // treat this as a smooth trackpad scroll instead of discrete wheel
        // ticks.
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(dyScaled.rounded()),
            wheel2: Int32(dxScaled.rounded()),
            wheel3: 0)
        else { return }
        event.location = virtualCursor
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)

    case .pinch(let scale):
        // `scale` is a ratio (1.0 = no change); the magnification field
        // wants a delta from 1.0 instead, the same convention
        // `NSMagnificationGestureRecognizer.magnification` uses.
        if !pinchPhaseOpen {
            postGestureMagnify(magnification: 0, phase: .began, at: virtualCursor)
            pinchPhaseOpen = true
        }
        postGestureMagnify(magnification: scale - 1.0, phase: .changed, at: virtualCursor)
        lastPinchAt = Date()

    case .twoFingerTap:
        // Clicks at the tracked cursor position, not a fresh system read
        // — see `virtualCursor`'s comment.
        let location = virtualCursor
        let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: location, mouseButton: .right)
        let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: location, mouseButton: .right)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        print("→ right-click at \(location)")

    case .oneFingerTap:
        // Left-click, so a two-finger-tap's context menu has a way to
        // actually select something, not just appear.
        let location = virtualCursor
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        print("→ left-click at \(location)")
    }
}

// MARK: - Device setup
//
// Matches any Wacom vendor device — there's no fixed product ID to look
// for. The actual connected product is resolved against the registry in
// TouchSurfaceRunner.handleDeviceConnected once IOKit reports one.

print("touch-surface — TabletKit live touch-gesture sample")
print("Works with any Wacom touch-capable tablet TabletKit's registry has a fixed touchMaxX/Y for.")
print("Gestures: 1-finger cursor, 1-finger tap (left-click), 2-finger pan (scroll), pinch (zoom), 2-finger tap (right-click)")
print("Debug flags: TOUCH_SURFACE_DEBUG=\(ProcessInfo.processInfo.environment["TOUCH_SURFACE_DEBUG"] != nil)  TOUCH_SURFACE_FORCE_PINCH=\(GestureRecognizer.forcePinchForDebug)")
print("Waiting for a tablet to connect over USB…")
print(String(repeating: "─", count: 64))

// MARK: - IOKit HID bootstrap
//
// TabletKit has no device-manager wrapper of its own — opening a live
// device is left to the consumer, same as MockTab, just far smaller here:
// one device at a time, one report type, no reconnect handling, no BT.

let runner = TouchSurfaceRunner()
let runnerContext = Unmanaged.passUnretained(runner).toOpaque()

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

let matchDict: [String: Any] = [
    kIOHIDVendorIDKey: 0x056A  // Wacom
]
IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)

// Registered per-device, not on the manager, so the report callback fires
// only for the device this sample is actually driving — done inside
// handleDeviceConnected once IOKit hands us a matched device.
IOHIDManagerRegisterDeviceMatchingCallback(manager, TouchSurfaceRunner.deviceCallback, runnerContext)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard openResult == kIOReturnSuccess else {
    fputs("Failed to open IOHIDManager: \(openResult)\n", stderr)
    exit(1)
}

CFRunLoopRun()
