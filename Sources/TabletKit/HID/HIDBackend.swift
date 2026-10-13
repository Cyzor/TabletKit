// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import IOKit.hid

/// Where a session's interfaces come from: the system's HID stack, or a
/// recording played back in a test.
package protocol HIDBackend: AnyObject, Sendable {
    /// Starts reporting interfaces as they appear and go. Both callbacks run
    /// on the main actor, in the order the system reported them. Returns the
    /// result of opening the system's HID access; it fails without Input
    /// Monitoring permission.
    @MainActor func start(
        attached: @escaping @MainActor (any HIDInterface) -> Void,
        detached: @escaping @MainActor (any HIDInterface) -> Void
    ) -> IOReturn
    /// Tries again to open HID access after an earlier failure, as when the
    /// user grants Input Monitoring later. Returns the new result.
    @MainActor func retryOpen() -> IOReturn
    @MainActor func stop()
}

extension HIDBackend {
    @MainActor package func retryOpen() -> IOReturn { kIOReturnSuccess }
}

/// The system's HID stack, through `IOHIDManager`.
///
/// `@unchecked Sendable`: its state is touched only on the main actor; the
/// manager's own callbacks arrive on ``HIDThread`` and hop to main first.
package final class IOKitBackend: HIDBackend, @unchecked Sendable {
    private let manager: IOHIDManager
    private let matching: [[String: Any]]
    private var interfaces: [ObjectIdentifier: IOKitHIDInterface] = [:]
    private var attached: (@MainActor (any HIDInterface) -> Void)?
    private var detached: (@MainActor (any HIDInterface) -> Void)?
    private var isOpen = false

    /// Matches every interface from `vendorIDs`, and any vendor's pen
    /// digitizer (usage page Digitizer, usage Pen) when `anyPenDigitizer` is
    /// set. Matching the Pen usage, not just the page, leaves trackpads and
    /// touch screens alone.
    package init(vendorIDs: [Int], anyPenDigitizer: Bool) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        var matching: [[String: Any]] = vendorIDs.map { [kIOHIDVendorIDKey: $0 as NSNumber] }
        if anyPenDigitizer {
            matching.append([kIOHIDDeviceUsagePageKey: 0x0D as NSNumber, kIOHIDDeviceUsageKey: 0x02 as NSNumber])
        }
        self.matching = matching
    }

    @MainActor package func start(
        attached: @escaping @MainActor (any HIDInterface) -> Void,
        detached: @escaping @MainActor (any HIDInterface) -> Void
    ) -> IOReturn {
        self.attached = attached
        self.detached = detached
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.matchingCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.removalCallback, context)
        IOHIDManagerScheduleWithRunLoop(manager, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
        return retryOpen()
    }

    @MainActor package func retryOpen() -> IOReturn {
        guard !isOpen else { return kIOReturnSuccess }
        let ret = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = ret == kIOReturnSuccess
        return ret
    }

    @MainActor package func stop() {
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = false
        for interface in interfaces.values { interface.close() }
        interfaces.removeAll()
        attached = nil
        detached = nil
    }

    // IOKit calls these on HIDThread. They're static so they don't take on
    // `start`'s main-actor isolation, which the Swift 6 runtime would check.
    private static let matchingCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let backend = Unmanaged<IOKitBackend>.fromOpaque(context).takeUnretainedValue()
        let handoff = DeviceHandoff(device: device)
        DispatchQueue.main.async { MainActor.assumeIsolated { backend.deviceAppeared(handoff.device) } }
    }

    private static let removalCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let backend = Unmanaged<IOKitBackend>.fromOpaque(context).takeUnretainedValue()
        let handoff = DeviceHandoff(device: device)
        DispatchQueue.main.async { MainActor.assumeIsolated { backend.deviceWent(handoff.device) } }
    }

    @MainActor private func deviceAppeared(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard interfaces[key] == nil, let attached else { return }
        let interface = IOKitHIDInterface(device)
        interfaces[key] = interface
        attached(interface)
    }

    @MainActor private func deviceWent(_ device: IOHIDDevice) {
        guard let interface = interfaces.removeValue(forKey: ObjectIdentifier(device)) else { return }
        detached?(interface)
    }
}

/// Carries a device from IOKit's callback thread to main. `IOHIDDevice` is a
/// CF object that's safe to pass between threads.
private struct DeviceHandoff: @unchecked Sendable {
    let device: IOHIDDevice
}
