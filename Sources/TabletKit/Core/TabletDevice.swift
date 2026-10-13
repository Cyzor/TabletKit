// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

public protocol TabletDevice: AnyObject {
    var spec: DigitizerSpec { get }
    /// What this device lets the host set. Empty by default.
    var controls: TabletControls { get }
    func open()
    func close()
    /// Resends the device's mode-switch init on an open connection. A device
    /// can connect before it's ready to take that write and stay in its
    /// power-on mode; resending is harmless when it already took. No-op
    /// for devices without an init sequence.
    func reawaken()
}

public extension TabletDevice {
    var controls: TabletControls { TabletControls() }
    func reawaken() {}
}
