// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

/// Which of a tablet's HID interfaces should carry its driver.
///
/// Pure: it reads only an interface's usages and the tablet's spec, so
/// captured descriptors can be replayed through it without hardware.
public enum InterfaceRouting {

    public typealias UsagePair = (page: Int, usage: Int)

    /// True if any top-level collection is a digitizer pen (0x0D/0x02).
    public static func isPenCollection(in pairs: [UsagePair]) -> Bool {
        pairs.contains { $0.page == 0x0D && $0.usage == 0x02 }
    }

    /// Whether an interface waits for a sibling interface to create the
    /// driver, then joins it as a secondary.
    ///
    /// - IntuosV2 (PTH-x60/x80): the vendor interface 0xFF00 is primary.
    ///   Interface 0x01 defers and is never seized; seizing it stops pen
    ///   reports.
    /// - CintiqV1 (DTK-2400 and others): interface 0x01 carries the pen.
    ///   0xFF00 carries only a periodic status report, so it defers.
    ///
    /// - Parameters:
    ///   - spec: the tablet the interface belongs to.
    ///   - usagePage: the interface's primary usage page.
    ///   - isBLE: whether the interface is on Bluetooth.
    ///   - pairs: every top-level collection the interface declares.
    public static func shouldDefer(
        spec: TabletSpec, usagePage: Int, isBLE: Bool, pairs: [UsagePair]
    ) -> Bool {
        guard !isBLE, spec.seizeUSB else { return false }
        switch spec.format {
        case .cintiqV1:
            return usagePage == 0xFF00
        case .intuosV2:
            // Pen displays like the DTH-167 have no 0xFF00 sibling: their one
            // interface leads with page 0x01 but also declares the pen
            // collection. Deferring it waited for a sibling that never comes.
            return usagePage == 0x01 && !isPenCollection(in: pairs)
        default:
            // Only the families above have a sibling to wait for. Deferring
            // any other family stranded single-interface devices such as the
            // DTU-1031, DTU-2231, and Cintiq 13HD Touch.
            return false
        }
    }

    /// What a connecting interface says about itself.
    public struct Facts: Sendable {
        public var vendorID: Int
        /// After transport folding (a Bluetooth PID maps to its USB PID).
        public var productID: Int
        public var usagePage: Int
        public var usagePairs: [UsagePair]
        public var isBluetooth: Bool
        /// A spec from outside the Wacom registry (Xencelabs); replaces the lookup.
        public var overrideSpec: TabletSpec?

        public init(
            vendorID: Int, productID: Int, usagePage: Int, usagePairs: [UsagePair],
            isBluetooth: Bool, overrideSpec: TabletSpec? = nil
        ) {
            self.vendorID = vendorID
            self.productID = productID
            self.usagePage = usagePage
            self.usagePairs = usagePairs
            self.isBluetooth = isBluetooth
            self.overrideSpec = overrideSpec
        }
    }

    /// What the descriptor holds, read only for interfaces the registry
    /// doesn't know.
    public struct DescriptorProbe: Sendable {
        public var hasXY: Bool
        public var kind: DigitizerInterfaceKind

        public init(hasXY: Bool, kind: DigitizerInterfaceKind) {
            self.hasXY = hasXY
            self.kind = kind
        }
    }

    public enum Decision: Sendable {
        /// The ACK-40401 receiver; its paired tablet is learned later.
        case wirelessDongle
        /// A touch sensor with its own PID, belonging to an attached tablet.
        case touchCompanion(ofProductID: Int)
        /// A touch sensor whose tablet hasn't attached yet: hold it.
        case holdTouchCompanion
        /// Wait for a sibling interface to create the driver.
        case deferToSibling
        /// A registered device: drive it with `spec`.
        case driver(TabletSpec, seize: Bool)
        /// An unregistered multitouch interface: observe, inject nothing.
        case observeTouchOnly
        /// An unregistered Wacom pen digitizer.
        case wacomFallback
        /// Any other vendor's standard pen digitizer.
        case genericDigitizer
        /// An LED interface belonging to an attached tablet.
        case ledCompanion(ofProductID: Int)
        case skip
    }

    /// Decides what to do with a connecting interface.
    ///
    /// - Parameters:
    ///   - facts: what the interface says about itself.
    ///   - attachedProductIDs: product IDs of tablets already driven.
    ///   - holdTouchCompanion: false once a held sensor's wait has run out.
    ///   - probe: reads the descriptor; called only for unregistered devices.
    public static func decide(
        _ facts: Facts, attachedProductIDs: [Int], holdTouchCompanion: Bool = true,
        probe: () -> DescriptorProbe
    ) -> Decision {
        let isWacom = WacomDeviceRegistry.vendorIDs.contains(facts.vendorID)
        let productID = facts.productID

        // Pinned to 0x056A: nothing on the consumer 0x0531 VID pairs with it.
        if facts.vendorID == 0x056A && productID == 0x0084 {
            return .wirelessDongle
        }

        // Ahead of the registry lookup: sensors have name-only rows that
        // would fall through to the observe-only path.
        if isWacom, facts.overrideSpec == nil {
            if let parent = attachedProductIDs.first(where: {
                WacomDeviceRegistry.spec(for: $0)?.touchCompanionPID == productID
            }) {
                return .touchCompanion(ofProductID: parent)
            }
            if holdTouchCompanion, WacomDeviceRegistry.touchCompanionPIDs.contains(productID) {
                return .holdTouchCompanion
            }
        }

        // maxX == 0 with buttons is an aux-only device (Quick Keys).
        if let spec = facts.overrideSpec ?? (isWacom ? WacomDeviceRegistry.spec(for: productID) : nil),
            spec.maxX > 0 || spec.buttonCount > 0
        {
            if shouldDefer(
                spec: spec, usagePage: facts.usagePage, isBLE: facts.isBluetooth,
                pairs: facts.usagePairs)
            {
                return .deferToSibling
            }
            // CintiqV1's digitizer interface is seized so macOS doesn't also
            // read the tip as a click.
            let seize = !facts.isBluetooth && spec.format == .cintiqV1 && spec.seizeUSB
                && facts.usagePage == 0x01
            return .driver(spec, seize: seize)
        }

        let descriptor = probe()
        if descriptor.hasXY {
            // A touch report repeats X/Y per finger, so a pen driver would
            // drag the cursor between contacts.
            if descriptor.kind == .touchOnly { return .observeTouchOnly }
            return isWacom ? .wacomFallback : .genericDigitizer
        }

        if let parent = attachedProductIDs.first(where: {
            WacomDeviceRegistry.spec(for: $0)?.ledCompanionPID == productID
        }) {
            return .ledCompanion(ofProductID: parent)
        }
        return .skip
    }
}
