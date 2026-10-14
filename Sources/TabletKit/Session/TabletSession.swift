// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import IOKit
import OSLog

private let logger = Logger(subsystem: "com.cyzor.tabletkit", category: "session")

/// Finds tablets, connects them, and hands their events to a delegate.
///
/// Each interface the backend reports is gated by vendor, routed with
/// ``InterfaceRouting``, and grouped: interfaces of one product and
/// transport share a ``TabletTransport``, and a tablet's transports share a
/// ``ConnectedTablet``. Interfaces that arrive before the one that takes
/// them are held until it does, and a touch sensor whose tablet never
/// appears is routed on its own after ``heldSensorTimeout``.
///
/// Three executors, as the delegate's methods say: the main actor for
/// lifecycle, the input thread for reports and events, and one output queue
/// per transport for the connect sequence and control writes.
@MainActor
package final class TabletSession {
    package private(set) weak var delegate: (any TabletSessionDelegate)?
    package private(set) var tablets: [ConnectedTablet] = []
    /// Interfaces routed to no driver here, which the delegate may drive itself.
    package private(set) var unclaimed: [any HIDInterface] = []
    /// How long a touch sensor waits for its tablet before routing alone.
    package var heldSensorTimeout: TimeInterval = 10

    private let backend: any HIDBackend
    private var transportOf: [ObjectIdentifier: TabletTransport] = [:]
    private var ledInterfaces: Set<ObjectIdentifier> = []
    private var heldSiblings = HeldInterfaces<Holder>()
    private var heldSensors = HeldInterfaces<Holder>()
    /// Each receiver's tablet, by the receiver's own identity, so its later
    /// interfaces find it after it joins the tablet it relays.
    private var receiverHomes: [DeviceInstanceKey: ConnectedTablet] = [:]
    private var nextID = 1
    /// One holder per interface, since held interfaces compare by identity.
    private var holders: [ObjectIdentifier: Holder] = [:]

    private static let receiverProductID = 0x0084

    package init(backend: any HIDBackend, delegate: any TabletSessionDelegate) {
        self.backend = backend
        self.delegate = delegate
    }

    /// Starts listening. Returns the result of opening HID access, which
    /// fails without Input Monitoring permission.
    @discardableResult
    package func start() -> IOReturn {
        backend.start(
            attached: { [weak self] in self?.attach($0) },
            detached: { [weak self] in self?.detach($0) })
    }

    /// Tries HID access again, as after Input Monitoring is granted.
    package func retryOpen() -> IOReturn { backend.retryOpen() }

    package func stop() {
        backend.stop()
        for tablet in tablets {
            for transport in tablet.transports { transport.close() }
        }
        tablets.removeAll()
        unclaimed.removeAll()
        transportOf.removeAll()
        ledInterfaces.removeAll()
        heldSiblings = HeldInterfaces()
        heldSensors = HeldInterfaces()
        holders.removeAll()
        receiverHomes.removeAll()
    }

    /// Sends every tablet's init again, as after the Mac wakes.
    package func reawakenAll() {
        for tablet in tablets {
            for transport in tablet.transports { transport.reawaken() }
        }
    }

    /// The transport an interface belongs to.
    package func transport(for interface: any HIDInterface) -> TabletTransport? {
        transportOf[ObjectIdentifier(interface)]
    }

    // MARK: - Attach

    private func attach(_ interface: any HIDInterface, holdingSensor: Bool = true) {
        guard case .proceed(let overrideSpec) = SessionRouting.vendorGate(interface) else {
            logger.info("recognized 0x\(String(interface.vendorID, radix: 16), privacy: .public)/0x\(String(interface.productID, radix: 16), privacy: .public), no decoder support")
            return giveUp(interface, as: .recognizedOnly)
        }
        if SessionRouting.isBluetoothGhostMouse(interface) { return }
        let identity = SessionRouting.identity(of: interface)
        let rawProductID = interface.productID
        let tablet = group(for: identity, rawProductID: rawProductID)

        // Another interface of a transport that's already connected.
        if let existing = tablet?.transports.first(where: { $0.rawProductID == rawProductID }) {
            transportOf[ObjectIdentifier(interface)] = existing
            existing.register(interface)
            return
        }

        let facts = InterfaceRouting.Facts(
            vendorID: interface.vendorID, productID: identity.productID, usagePage: interface.usagePage,
            usagePairs: interface.usagePairs.map { (page: $0.page, usage: $0.usage) },
            isBluetooth: identity.isBluetooth, overrideSpec: overrideSpec)
        let attached = tablets.filter { !$0.transports.isEmpty }.map(\.productID)
        let decision = InterfaceRouting.decide(
            facts, attachedProductIDs: attached, holdTouchCompanion: holdingSensor
        ) { SessionRouting.descriptorProbe(of: interface) }

        switch decision {
        case .wirelessDongle:
            install(interface, spec: SessionRouting.receiverSpec(for: interface), seize: false,
                    isWireless: true, identity: identity, joining: tablet)

        case .driver(let spec, let seize):
            install(interface, spec: spec, seize: seize, isWireless: false, identity: identity, joining: tablet)

        case .deferToSibling:
            heldSiblings.hold(holder(interface), under: rawProductID)

        case .touchCompanion(let parentProductID):
            guard let parent = activeTransport(ofProductID: parentProductID) else { return }
            transportOf[ObjectIdentifier(interface)] = parent
            parent.attachTouchSensor(interface)

        case .holdTouchCompanion:
            let productID = identity.productID
            heldSensors.hold(holder(interface), under: productID)
            DispatchQueue.main.asyncAfter(deadline: .now() + heldSensorTimeout) { [weak self] in
                guard let self, self.heldSensors.take(self.holder(interface), under: productID) else { return }
                logger.info("0x\(String(productID, radix: 16, uppercase: true), privacy: .public): touch sensor's tablet never appeared, routing on its own")
                self.attach(interface, holdingSensor: false)
            }

        case .ledCompanion(let parentProductID):
            guard let parent = activeTransport(ofProductID: parentProductID) else { return }
            transportOf[ObjectIdentifier(interface)] = parent
            ledInterfaces.insert(ObjectIdentifier(interface))
            parent.registerLED(interface)

        case .observeTouchOnly:
            giveUp(interface, as: .observeTouchOnly)
        case .wacomFallback:
            giveUp(interface, as: .wacomFallback)
        case .genericDigitizer:
            giveUp(interface, as: .genericDigitizer)
        case .skip:
            break
        }
    }

    /// The tablet an interface joins, if one is connected: its receiver's
    /// home, the same identity, or the same product where either side has
    /// no serial. A serial-less tablet that gains a serial takes it on.
    private func group(for identity: SessionRouting.Identity, rawProductID: Int) -> ConnectedTablet? {
        let key = identity.key
        if rawProductID == Self.receiverProductID, let home = receiverHomes[key] { return home }
        if let same = tablets.first(where: { $0.key == key }) { return same }
        if key.instance.isEmpty {
            return tablets.first { $0.productID == identity.productID }
        }
        if let serialless = tablets.first(where: { $0.productID == identity.productID && $0.key.instance.isEmpty }) {
            let old = serialless.key
            serialless.key = key
            delegate?.session(self, didRekey: serialless, from: old)
            return serialless
        }
        return nil
    }

    private func install(
        _ interface: any HIDInterface, spec: TabletSpec, seize: Bool, isWireless: Bool,
        identity: SessionRouting.Identity, joining existing: ConnectedTablet?
    ) {
        logger.info("\(spec.name, privacy: .public) connected\(seize ? " (seized)" : "", privacy: .public)")
        let tablet = existing ?? newTablet(key: identity.key)
        let transport = TabletTransport(
            id: takeID(), primary: interface, spec: spec, seize: seize, isWireless: isWireless,
            key: identity.key, backend: backend, session: self)
        tablet.transports.append(transport)
        transport.tablet = tablet
        transportOf[ObjectIdentifier(interface)] = transport
        if isWireless { receiverHomes[identity.key] = tablet }
        delegate?.session(self, didAttach: transport, to: tablet)
        if !transport.open() { delegate?.session(self, transportDidChangeState: transport) }

        // Interfaces that arrived first, waiting for this one.
        for held in heldSiblings.release(interface.productID).map(\.interface) {
            transportOf[ObjectIdentifier(held)] = transport
            transport.register(held)
        }
        if let sensorProductID = WacomDeviceRegistry.spec(for: identity.productID)?.touchCompanionPID {
            for held in heldSensors.release(sensorProductID).map(\.interface) {
                transportOf[ObjectIdentifier(held)] = transport
                transport.attachTouchSensor(held)
            }
        }
    }

    private func holder(_ interface: any HIDInterface) -> Holder {
        if let existing = holders[ObjectIdentifier(interface)] { return existing }
        let holder = Holder(interface)
        holders[ObjectIdentifier(interface)] = holder
        return holder
    }

    private func newTablet(key: DeviceInstanceKey) -> ConnectedTablet {
        let tablet = ConnectedTablet(id: takeID(), key: key)
        tablets.append(tablet)
        return tablet
    }

    private func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func activeTransport(ofProductID productID: Int) -> TabletTransport? {
        tablets.first { $0.productID == productID && !$0.transports.isEmpty }?.activeTransport
    }

    private func giveUp(_ interface: any HIDInterface, as kind: UnclaimedKind) {
        unclaimed.append(interface)
        delegate?.session(self, didFindUnclaimed: interface, as: kind)
    }

    // MARK: - Detach

    private func detach(_ interface: any HIDInterface) {
        if let holder = holders.removeValue(forKey: ObjectIdentifier(interface)) {
            heldSensors.drop(holder)
            heldSiblings.drop(holder)
        }
        if let index = unclaimed.firstIndex(where: { $0 === interface }) {
            unclaimed.remove(at: index)
            delegate?.session(self, didLoseUnclaimed: interface)
            return
        }
        let key = ObjectIdentifier(interface)
        guard let transport = transportOf.removeValue(forKey: key) else { return }
        if ledInterfaces.remove(key) != nil {
            transport.forget(interface)
            return
        }
        // Any interface leaving takes its transport with it; the others of
        // one USB device or link leave together.
        transportOf = transportOf.filter { $0.value !== transport }
        ledInterfaces = ledInterfaces.filter { transportOf[$0] != nil }
        transport.close()
        guard let tablet = transport.tablet else { return }
        tablet.transports.removeAll { $0 === transport }
        if transport.isWireless {
            receiverHomes = receiverHomes.filter { $0.value !== tablet }
        }
        logger.info("\(transport.spec.name, privacy: .public): transport 0x\(String(transport.rawProductID, radix: 16), privacy: .public) disconnected")
        delegate?.session(self, didDetach: transport, from: tablet)
        if tablet.transports.isEmpty { tablets.removeAll { $0 === tablet } }
    }

    // MARK: - From transports

    func transportDidChangeState(_ transport: TabletTransport) {
        delegate?.session(self, transportDidChangeState: transport)
    }

    func transport(_ transport: TabletTransport, didReadSerial serial: UInt32) {
        delegate?.session(self, transport: transport, didReadSerial: serial)
    }

    /// A receiver named its tablet: it joins that tablet's group, so one
    /// tablet keeps one identity across cable and receiver.
    func transport(_ transport: TabletTransport, didPairWith productID: Int) {
        delegate?.session(self, transport: transport, didPairWith: productID)
        guard transport.isWireless, let source = transport.tablet, source.productID != productID,
            WacomDeviceRegistry.spec(for: productID) != nil
        else { return }
        let target = tablets.first { $0.productID == productID && $0 !== source }
            ?? newTablet(key: DeviceInstanceKey(productID: productID, instance: ""))
        source.transports.removeAll { $0 === transport }
        target.transports.append(transport)
        transport.tablet = target
        receiverHomes[transport.key] = target
        logger.info("ACK-40401 now relaying for 0x\(String(productID, radix: 16, uppercase: true), privacy: .public)")
        delegate?.session(self, didRegroup: transport, from: source, to: target)
        if source.transports.isEmpty { tablets.removeAll { $0 === source } }
    }
}

/// One physical tablet: every transport it's connected over, under one
/// identity.
@MainActor
package final class ConnectedTablet: Identifiable {
    package nonisolated let id: Int
    package internal(set) var key: DeviceInstanceKey
    package internal(set) var transports: [TabletTransport] = []

    init(id: Int, key: DeviceInstanceKey) {
        self.id = id
        self.key = key
    }

    /// Transport variants folded onto one product ID.
    package var productID: Int { key.productID }

    /// The transport that drives the tablet when it has more than one, as
    /// the Quick Keys puck does on its cable and receiver at once.
    package var activeTransport: TabletTransport? {
        transports.max {
            VendorDeviceRegistry.transportPriority(forRawProductID: $0.rawProductID)
                < VendorDeviceRegistry.transportPriority(forRawProductID: $1.rawProductID)
        }
    }
}

/// Why the session left an interface to someone else.
package enum UnclaimedKind: Sendable, Equatable {
    /// A known vendor's device with no decoder.
    case recognizedOnly
    /// A multitouch interface the registry doesn't know: watch, inject nothing.
    case observeTouchOnly
    /// A Wacom pen digitizer the registry doesn't know.
    case wacomFallback
    /// Another vendor's standard pen digitizer.
    case genericDigitizer
}

/// What a session tells its owner.
///
/// Lifecycle methods run on the main actor. ``transport(_:didDecode:at:)``
/// and ``transport(_:didReceive:at:from:)`` run on the input thread and must
/// return quickly; ``transport(_:didRun:)`` runs on the transport's output
/// queue.
package protocol TabletSessionDelegate: AnyObject, Sendable {
    /// A transport connected, joining `tablet`. It opens right after this,
    /// so its reports can already arrive.
    @MainActor func session(_ session: TabletSession, didAttach transport: TabletTransport, to tablet: ConnectedTablet)
    /// A transport went. `tablet` is gone too if it has no transports left.
    @MainActor func session(_ session: TabletSession, didDetach transport: TabletTransport, from tablet: ConnectedTablet)
    /// A receiver moved to the tablet it relays. `old` is gone if it has no
    /// transports left.
    @MainActor func session(
        _ session: TabletSession, didRegroup transport: TabletTransport, from old: ConnectedTablet, to new: ConnectedTablet)
    /// A tablet with no serial took on a connecting interface's serial.
    @MainActor func session(_ session: TabletSession, didRekey tablet: ConnectedTablet, from old: DeviceInstanceKey)
    /// An interface joined a transport after it opened.
    @MainActor func session(_ session: TabletSession, didAdd interface: any HIDInterface, to transport: TabletTransport)
    /// The connect sequence finished, or the transport failed.
    @MainActor func session(_ session: TabletSession, transportDidChangeState transport: TabletTransport)
    @MainActor func session(_ session: TabletSession, transport: TabletTransport, didReadSerial serial: UInt32)
    /// A wireless receiver named its tablet. Called whether or not the
    /// session knows that tablet well enough to regroup.
    @MainActor func session(_ session: TabletSession, transport: TabletTransport, didPairWith productID: Int)
    @MainActor func session(_ session: TabletSession, didFindUnclaimed interface: any HIDInterface, as kind: UnclaimedKind)
    @MainActor func session(_ session: TabletSession, didLoseUnclaimed interface: any HIDInterface)

    /// One report's events, with the time it arrived. On the input thread.
    func transport(_ id: TabletTransport.ID, didDecode events: [TabletEvent], at receivedNs: UInt64)
    /// Every report before decoding, as for capture. On the input thread.
    func transport(_ id: TabletTransport.ID, didReceive report: HIDReport, at receivedNs: UInt64, from interface: any HIDInterface)
    /// Each write and read of the connect sequence. On the output queue.
    func transport(_ id: TabletTransport.ID, didRun step: TabletConnection.ConnectStep)
}

extension TabletSessionDelegate {
    @MainActor package func session(
        _ session: TabletSession, didRegroup transport: TabletTransport, from old: ConnectedTablet, to new: ConnectedTablet) {}
    @MainActor package func session(_ session: TabletSession, didRekey tablet: ConnectedTablet, from old: DeviceInstanceKey) {}
    @MainActor package func session(_ session: TabletSession, didAdd interface: any HIDInterface, to transport: TabletTransport) {}
    @MainActor package func session(_ session: TabletSession, transportDidChangeState transport: TabletTransport) {}
    @MainActor package func session(_ session: TabletSession, transport: TabletTransport, didReadSerial serial: UInt32) {}
    @MainActor package func session(_ session: TabletSession, transport: TabletTransport, didPairWith productID: Int) {}
    @MainActor package func session(_ session: TabletSession, didFindUnclaimed interface: any HIDInterface, as kind: UnclaimedKind) {}
    @MainActor package func session(_ session: TabletSession, didLoseUnclaimed interface: any HIDInterface) {}
    package func transport(_ id: TabletTransport.ID, didReceive report: HIDReport, at receivedNs: UInt64, from interface: any HIDInterface) {}
    package func transport(_ id: TabletTransport.ID, didRun step: TabletConnection.ConnectStep) {}
}

/// Holds an interface for ``HeldInterfaces``, which compares by identity.
private final class Holder {
    let interface: any HIDInterface
    init(_ interface: any HIDInterface) { self.interface = interface }
}
