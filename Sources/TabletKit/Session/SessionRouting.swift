// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

/// What a session reads off a connecting interface before routing it. Pure,
/// so replayed interfaces route exactly as live ones do.
package enum SessionRouting {

    /// Which vendors a session drives, and with what spec.
    package enum VendorGate {
        /// Route it. `spec` is set only for drivable non-Wacom devices.
        case proceed(spec: TabletSpec?)
        /// A vendor's device the session recognizes but can't drive.
        case recognizedOnly
    }

    package static func vendorGate(_ interface: any HIDInterface) -> VendorGate {
        let vendorID = interface.vendorID
        guard !WacomDeviceRegistry.vendorIDs.contains(vendorID) else { return .proceed(spec: nil) }
        if let spec = VendorDeviceRegistry.drivableSpec(forVendorID: vendorID, productID: interface.productID) {
            return .proceed(spec: spec)
        }
        // Any other vendor's standard pen digitizer gets the generic floor.
        // Xencelabs declares a pen collection on every interface but never
        // sends on it, and 0xFEED is Karabiner's virtual device, whose
        // synthetic proximity would steal the cursor from a real tablet.
        let isPenDigitizer = interface.usagePage == 0x0D && interface.usage == 0x02
            && vendorID != 0x28BD && vendorID != 0xFEED
        return isPenDigitizer ? .proceed(spec: nil) : .recognizedOnly
    }

    /// Who an interface says it is.
    package struct Identity: Equatable {
        /// Transport variants folded onto one product ID.
        package var productID: Int
        package var isBluetooth: Bool
        package var key: DeviceInstanceKey
    }

    package static func identity(of interface: any HIDInterface) -> Identity {
        let raw = interface.productID
        let productID = WacomDeviceRegistry.vendorIDs.contains(interface.vendorID)
            ? WacomDeviceRegistry.canonicalProductID(for: raw)
            : VendorDeviceRegistry.canonicalProductID(for: raw)
        let isBluetooth = interface.transport.lowercased().contains("bluetooth")
        // The Bluetooth stack reports a different serial than USB for the
        // same tablet, so over Bluetooth identity falls back to the product.
        // The location ID fallback stays off until it's confirmed live.
        let serial = isBluetooth ? nil : interface.serialNumber
        return Identity(
            productID: productID, isBluetooth: isBluetooth,
            key: DeviceInstanceKey(productID: productID, usbSerial: serial, locationID: 0))
    }

    /// The ghost mouse collection Bluetooth tablets expose next to their
    /// real interfaces. Other page 0x01 collections are real, and so is the
    /// Graphire Wireless's: its one interface leads with a mouse and carries
    /// the pen too.
    package static func isBluetoothGhostMouse(_ interface: any HIDInterface) -> Bool {
        let identity = identity(of: interface)
        guard identity.isBluetooth, interface.usagePage == 0x01, interface.usage == 0x02 else { return false }
        let isWacom = WacomDeviceRegistry.vendorIDs.contains(interface.vendorID)
        return !(isWacom && WacomDeviceRegistry.spec(for: identity.productID)?.format == .graphire)
    }

    /// The descriptor's largest X, Y, and tip pressure, across every report,
    /// with the defaults a descriptor that declares none gets. The same
    /// answer `queryHIDDigitizerSpec` reads from IOKit's elements.
    package static func digitizerRanges(of interface: any HIDInterface) -> (maxX: Int, maxY: Int, maxPressure: Int) {
        var maxX = 0, maxY = 0, maxP = 0
        if let layout = try? HIDReportDescriptorParser.parse(interface.reportDescriptor) {
            for field in layout.reports.flatMap(\.fields) {
                if field.usagePage == 0x01 && field.usage == 0x30 { maxX = max(maxX, field.logicalMax) }
                if field.usagePage == 0x01 && field.usage == 0x31 { maxY = max(maxY, field.logicalMax) }
                if field.usagePage == 0x0D && field.usage == 0x30 { maxP = max(maxP, field.logicalMax) }
            }
        }
        let isLarge = interface.maxInputReportSize > 64
        if maxX == 0 { maxX = isLarge ? 65535 : 22860 }
        if maxY == 0 { maxY = isLarge ? 40960 : 14430 }
        if maxP == 0 { maxP = isLarge ? 8191 : 1023 }
        return (maxX, maxY, maxP)
    }

    /// The ACK-40401 receiver's spec. It carries its paired tablet's
    /// descriptor (PTH-x50, IntuosV1), so ranges come from that.
    package static func receiverSpec(for interface: any HIDInterface) -> TabletSpec {
        let ranges = digitizerRanges(of: interface)
        return TabletSpec(
            productID: 0x0084,
            name: "ACK-40401 Wireless Dongle",
            format: .intuosV1,
            maxX: ranges.maxX, maxY: ranges.maxY, maxPressure: ranges.maxPressure,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])])
    }

    /// What `InterfaceRouting.decide` reads off a descriptor it doesn't know.
    /// `hasXY` is always true, as with IOKit's elements: the range defaults
    /// fill in a missing X.
    package static func descriptorProbe(of interface: any HIDInterface) -> InterfaceRouting.DescriptorProbe {
        let kind = (try? HIDReportDescriptorParser.parse(interface.reportDescriptor))
            .map { classifyDigitizerInterface(descriptor: $0) } ?? .undetermined
        return .init(hasXY: digitizerRanges(of: interface).maxX > 0, kind: kind)
    }
}
