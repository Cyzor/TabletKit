// SPDX-License-Identifier: MPL-2.0
//
// tablet-session — the shortest complete TabletKit program.
//
// A TabletSession finds Wacom tablets, switches them on, and decodes their
// reports. This sample prints what arrives. It needs Input Monitoring
// permission for the terminal it runs in.
//
//     swift run tablet-session

import Foundation
import TabletKit

final class Printer: TabletSessionDelegate, TabletInputSink {
    @MainActor func session(_ session: TabletSession, didAttach transport: TabletTransport, to tablet: ConnectedTablet) {
        print("\(transport.spec.name) connected over \(transport.transportName)")
    }

    @MainActor func session(_ session: TabletSession, didDetach transport: TabletTransport, from tablet: ConnectedTablet) {
        print("\(transport.spec.name) disconnected")
    }

    @MainActor func session(_ session: TabletSession, inputSinkFor transport: TabletTransport) -> any TabletInputSink { self }

    // On the input thread, once per report.
    func didDecode(_ events: [TabletEvent], from report: HIDReport, on interface: any HIDInterface, at receivedNs: UInt64) {
        for event in events {
            switch event {
            case .pen(let point): print("pen at (\(point.x), \(point.y)), pressure \(point.normalizedPressure)")
            case .pad(let pad): print("keys held: \(pad.buttons.indices.filter { pad.buttons[$0] })")
            case .touch(let frame): print("\(frame.contacts.count) fingers down")
            default: break
            }
        }
    }
}

let printer = Printer()
let session = TabletSession(vendorIDs: Array(WacomDeviceRegistry.vendorIDs), anyPenDigitizer: false, delegate: printer)
guard session.start() == kIOReturnSuccess else {
    fputs("Can't open HID devices. Grant Input Monitoring in System Settings, then run again.\n", stderr)
    exit(1)
}
// The session's main-actor work needs the main thread's run loop;
// dispatchMain() would hand it to a worker thread.
RunLoop.main.run()
