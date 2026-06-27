// SPDX-License-Identifier: MPL-2.0
//
// tablet-decode — TabletKit fixture replay sample
//
// Replays a short sequence of raw HID report bytes from a Wacom Intuos Pro M
// (PTH-660, USB) through the IntuosV2 decoder and prints each decoded event.
//
// This is a proof of concept for using TabletKit as a library. The fixture
// bytes below represent a typical pen interaction: tool entry, a pen stroke
// with position, pressure, and tilt, then tool exit. They were derived from
// the TabletKit test suite.
//
// To run:
//     swift run --package-path <path/to/TabletKit> tablet-decode

import Foundation
import TabletKit

// MARK: - Device setup

// PTH-660 USB: product ID 0x0357
guard let spec = WacomDeviceRegistry.spec(for: 0x0357) else {
    fputs("PTH-660 (0x0357) not found in registry\n", stderr)
    Foundation.exit(1)
}

let digiSpec = DigitizerSpec(
    maxX: spec.maxX,
    maxY: spec.maxY,
    maxPressure: spec.maxPressure,
    buttonCount: spec.buttonCount,
    hasTilt: spec.hasTilt,
    hasFingerTouch: spec.hasFingerTouch,
    maxTouchContacts: spec.maxTouchContacts
)

var state = DecoderState()
var decoder = IntuosV2Decoder()

print("tablet-decode — TabletKit fixture replay")
print("Device : \(spec.name)  (PID \(String(format: "0x%04X", spec.productID)))")
print("Surface: \(spec.maxX) × \(spec.maxY) device units  |  max pressure: \(spec.maxPressure)")
print(String(repeating: "─", count: 64))

// MARK: - Fixture

// Each entry is one raw HID report as it would arrive from IOHIDDevice.
// 192-byte 0x10 IntuosV2 USB pen report; layout mirrors IntuosV2Decoder's decode path.

func makeReport(
    status: UInt8,
    x: Int = 0, y: Int = 0,
    pressure: Int = 0,
    tiltX: Int8 = 0, tiltY: Int8 = 0,
    toolCode: UInt16 = 0x0842,
    serial: UInt32 = 0x0000_1234
) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: 192)
    r[0] = 0x10
    r[1] = status
    r[2] = UInt8(x & 0xFF);           r[3] = UInt8((x >> 8) & 0xFF);  r[4] = UInt8((x >> 16) & 0xFF)
    r[5] = UInt8(y & 0xFF);           r[6] = UInt8((y >> 8) & 0xFF);  r[7] = UInt8((y >> 16) & 0xFF)
    r[8] = UInt8(pressure & 0xFF);    r[9] = UInt8((pressure >> 8) & 0x1F)
    r[10] = UInt8(bitPattern: tiltX)
    r[11] = UInt8(bitPattern: tiltY)
    r[17] = UInt8(serial & 0xFF);       r[18] = UInt8((serial >> 8) & 0xFF)
    r[19] = UInt8((serial >> 16) & 0xFF); r[20] = UInt8((serial >> 24) & 0xFF)
    r[21] = UInt8(toolCode & 0xFF);    r[22] = UInt8((toolCode >> 8) & 0xFF)
    return r
}

let reports: [(label: String, bytes: [UInt8])] = [
    // Tool enters proximity (prox=1, highConf=1, no pressure yet)
    ("tool-enter",  makeReport(status: 0x60, x: 15000, y: 10000)),
    // Pen descends — light touch
    ("touch-down",  makeReport(status: 0x60, x: 15200, y: 10100, pressure: 400,  tiltX:  10, tiltY:  -5)),
    // Mid-stroke — moderate pressure and tilt
    ("mid-stroke",  makeReport(status: 0x60, x: 20000, y: 14000, pressure: 3200, tiltX:  20, tiltY: -12)),
    // Peak pressure
    ("peak",        makeReport(status: 0x60, x: 25000, y: 18000, pressure: 7800, tiltX:  30, tiltY: -20)),
    // Lifting off
    ("lift",        makeReport(status: 0x60, x: 26000, y: 19000, pressure: 200,  tiltX:   5, tiltY:  -2)),
    // Out of proximity (status=0x00 with no tool code — genuine exit)
    ("exit",        makeReport(status: 0x00, x: 26000, y: 19000)),
]

// MARK: - Replay

for (label, bytes) in reports {
    let results = bytes.withUnsafeBufferPointer { buf in
        decoder.decode(
            report: buf.baseAddress!,
            length: buf.count,
            spec: digiSpec,
            state: &state,
            deviceFamily: spec.family
        )
    }

    for result in results {
        switch result {
        case .toolEnter(let identity):
            let kind = identity.isEraser ? "eraser" : identity.isMouse ? "mouse" : "pen"
            print("[\(label)] tool-enter  code=\(String(format: "0x%04X", identity.toolCode))  serial=\(String(format: "0x%08X", identity.serial))  kind=\(kind)")

        case .pen(let point):
            let px  = String(format: "%6d", point.x)
            let py  = String(format: "%6d", point.y)
            let pr  = String(format: "%4d", point.pressure)
            let pct = String(format: "%.0f%%", point.normalizedPressure * 100)
            let tx  = String(format: "%+.2f", point.tiltX)
            let ty  = String(format: "%+.2f", point.tiltY)
            let prox = point.inProximity ? "in " : "out"
            print("[\(label)] pen         x=\(px)  y=\(py)  pressure=\(pr) (\(pct))  tilt=(\(tx), \(ty))  prox=\(prox)")

        case .aux(let buttons):
            let held = buttons.buttons.enumerated().compactMap { $0.element ? "\($0.offset)" : nil }.joined(separator: ",")
            let ring = buttons.touchRingActive ? "pos=\(buttons.touchRingPosition)" : "idle"
            print("[\(label)] aux         keys=[\(held.isEmpty ? "none" : held)]  ring=\(ring)")

        case .touch(let contacts):
            if contacts.isEmpty {
                print("[\(label)] touch       all-lifted")
            } else {
                for c in contacts {
                    print("[\(label)] touch       id=\(c.id)  x=\(c.x)  y=\(c.y)")
                }
            }

        case .wireless(let status):
            print("[\(label)] wireless    \(status)")

        case .battery(let percent, let charging):
            print("[\(label)] battery     \(percent)%\(charging ? " (charging)" : "")")

        case .mouseButton(let mask):
            print("[\(label)] mouse-btn   mask=\(String(format: "0x%02X", mask))")

        case .wheel(let index, let delta):
            print("[\(label)] wheel       index=\(index)  delta=\(String(format: "%+d", delta))")

        case .toolCompatibility(let note):
            print("[\(label)] compat-warn \(note)")

        case .none:
            break
        }
    }
}

print(String(repeating: "─", count: 64))
print("Done. \(reports.count) reports replayed.")
