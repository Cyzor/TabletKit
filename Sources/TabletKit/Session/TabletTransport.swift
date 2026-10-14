// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import IOKit
import OSLog

private let logger = Logger(subsystem: "com.cyzor.tabletkit", category: "session")

/// One way a tablet is connected: its USB cable, its Bluetooth link, or a
/// wireless receiver. Interfaces of the same product and transport join it.
///
/// Ties the three parts of a driver together: ``TabletConnection`` opens and
/// switches the tablet on, ``TabletInput`` turns its reports into events on
/// the input thread, and ``TabletOutput`` takes control writes. The input
/// path makes no hops: a report decodes and reaches the delegate on the
/// thread it arrived on.
@MainActor
package final class TabletTransport: Identifiable {
    package nonisolated let id: Int
    /// The product ID as the interface reports it, before transport folding.
    package nonisolated let rawProductID: Int
    package nonisolated let spec: TabletSpec
    package nonisolated let isBluetooth: Bool
    /// Whether this is a wireless receiver, which relays a tablet it pairs with.
    package nonisolated let isWireless: Bool
    /// The transport as the system names it, such as "USB" or "Bluetooth Low Energy".
    package nonisolated let transportName: String
    /// The identity the first interface gave. A receiver keeps its own even
    /// after it joins the tablet it relays.
    package nonisolated let key: DeviceInstanceKey

    package enum State: Sendable, Equatable {
        /// Opened, with the connect sequence still running.
        case connecting
        case normal
        case faulted(TabletFailure)
        case disconnected
    }

    package private(set) var state: State = .connecting
    /// The tablet this transport belongs to.
    package internal(set) weak var tablet: ConnectedTablet?
    /// The tablet a wireless receiver named, or 0 until it does.
    package private(set) var pairedProductID = 0
    package private(set) var hardwareSerial: UInt32?

    package var primary: any HIDInterface { connection.primary }
    /// Every interface whose reports reach the delegate, primary first.
    package private(set) var deliveringInterfaces: [any HIDInterface] = []
    /// Every interface this transport holds, including the LED interface.
    package private(set) var interfaces: [any HIDInterface] = []
    package var controls: TabletControls { output.controls }

    let connection: TabletConnection
    let output: TabletOutput
    private let input: InputBox
    private let backend: any HIDBackend
    private weak var session: TabletSession?

    init(
        id: Int, primary: any HIDInterface, spec: TabletSpec, seize: Bool, isWireless: Bool,
        key: DeviceInstanceKey, backend: any HIDBackend, session: TabletSession
    ) {
        self.id = id
        rawProductID = primary.productID
        self.spec = spec
        isBluetooth = primary.transport.lowercased().contains("bluetooth")
        self.isWireless = isWireless
        transportName = primary.transport
        self.key = key
        self.backend = backend
        self.session = session
        connection = TabletConnection(primary: primary, spec: spec, seize: seize)
        output = TabletOutput(spec: spec, queue: connection.output)
        var input = TabletInput(spec: spec, isBluetooth: isBluetooth, isWireless: isWireless)
        input.register(primary)
        self.input = InputBox(input)
    }

    // MARK: - Lifecycle

    /// Opens the primary interface and starts the connect sequence. False if
    /// the open failed, with the transport faulted.
    func open() -> Bool {
        let id = id
        let delegate = session?.delegate
        connection.onStep = { step in delegate?.transport(id, didRun: step) }
        connection.onSerial = { [weak self] serial in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.serialRead(serial) } }
        }
        output.attach(primary: primary, isBluetooth: isBluetooth, isWireless: isWireless)
        let ret = connection.open(
            accepts: { [spec] in Self.accepts($0, spec: spec) },
            onReport: makeReportHandler())
        guard ret == kIOReturnSuccess else {
            state = .faulted(ret == kIOReturnNotPermitted ? .permissionDenied : .openFailed(ret))
            return false
        }
        interfaces = [primary]
        if Self.accepts(primary, spec: spec) { deliveringInterfaces = [primary] }
        if let capable = connection.capableInterface { output.setCapableInterface(capable) }
        // Ready once the queue reaches the end of what open sent it.
        connection.output.perform { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.connectSequenceFinished() } }
        }
        return true
    }

    /// Adds a sibling interface of the same product and transport.
    func register(_ interface: any HIDInterface) {
        let hadCapable = connection.capableInterface != nil
        connection.register(interface)
        joined(interface, hadCapable: hadCapable)
    }

    /// Adds a touch sensor that enumerates as its own product.
    func attachTouchSensor(_ interface: any HIDInterface) {
        let hadCapable = connection.capableInterface != nil
        connection.attachTouchSensor(interface)
        joined(interface, hadCapable: hadCapable)
    }

    /// Adds the separate interface some Cintiqs take LED writes on.
    func registerLED(_ interface: any HIDInterface) {
        connection.registerLED(interface)
        output.setLEDInterface(interface)
        interfaces.append(interface)
    }

    /// Sends the init sequence again, as after sleep.
    package func reawaken() {
        connection.reawaken()
    }

    /// Restores what the connect sequence changed and closes every interface.
    func close() {
        output.stop()
        connection.close()
        state = .disconnected
        deliveringInterfaces.removeAll()
        interfaces.removeAll()
    }

    /// Whether `interface` belongs to this transport.
    func holds(_ interface: any HIDInterface) -> Bool {
        interfaces.contains { $0 === interface }
    }

    /// Drops one interface that went away while others stay.
    func forget(_ interface: any HIDInterface) {
        interfaces.removeAll { $0 === interface }
        deliveringInterfaces.removeAll { $0 === interface }
    }

    private func joined(_ interface: any HIDInterface, hadCapable: Bool) {
        let isBT = interface.transport.lowercased().contains("bluetooth")
        let accepted = Self.accepts(interface, spec: spec)
        let input = input
        backend.performOnInput(after: 0) { input.value.register(interface) }
        output.addSibling(
            interface, isVendorTunnel: accepted,
            isInputModeInterface: spec.quirks.inputModeWriteOverUSB && !isBT)
        if !hadCapable, let capable = connection.capableInterface { output.setCapableInterface(capable) }
        // Xencelabs re-enumerates and the new handle lost what the screen showed.
        if spec.quirks.reinitOnReenumeration && !isBluetooth && accepted {
            output.reinitializedAfterReenumeration(
                isRelay: XencelabsRelayWatcher.relayProductIDs.contains(spec.productID))
        }
        interfaces.append(interface)
        if accepted { deliveringInterfaces.append(interface) }
        if let session { session.delegate?.session(session, didAdd: interface, to: self) }
    }

    private nonisolated static func accepts(_ interface: any HIDInterface, spec: TabletSpec) -> Bool {
        spec.format != .xencelabs || interface.usagePage == 0xFF0A
    }

    private func connectSequenceFinished() {
        guard state == .connecting else { return }
        state = .normal
        session?.transportDidChangeState(self)
    }

    private func serialRead(_ serial: UInt32) {
        hardwareSerial = serial
        session?.transport(self, didReadSerial: serial)
    }

    // MARK: - The input path

    /// The handler every interface's reports run through, on the input
    /// executor. It captures only what it needs, so a report never touches
    /// main-actor state.
    private func makeReportHandler() -> @Sendable (any HIDInterface, HIDReport, UInt64) -> Void {
        let id = id
        let input = input
        let output = output
        let backend = backend
        let delegate = session?.delegate
        let notesReports = spec.format == .xencelabs
        let accepts: @Sendable (any HIDInterface) -> Bool = { [spec] in Self.accepts($0, spec: spec) }
        return { [weak self] interface, report, ns in
            guard accepts(interface) else { return }
            delegate?.transport(id, didReceive: report, at: ns, from: interface)
            let result = input.value.handle(report, at: ns)
            if notesReports { output.noteReport(at: ns) }
            if !result.events.isEmpty {
                delegate?.transport(id, didDecode: result.events, at: ns)
            }
            for effect in result.effects {
                switch effect {
                case .relinkPuck(let identity):
                    Self.relink(identity, input: input, output: output, backend: backend)
                case .resendInit, .pairedTablet:
                    Self.onMain { self?.carryOut(effect) }
                }
            }
        }
    }

    private func carryOut(_ effect: TabletInput.Effect) {
        switch effect {
        case .resendInit(let reason):
            logger.info("\(self.spec.name, privacy: .public): resending init (\(String(describing: reason), privacy: .public))")
            connection.reawaken()
        case .pairedTablet(let productID):
            pairedProductID = productID
            output.setPairedProductID(productID)
            session?.transport(self, didPairWith: productID)
        case .relinkPuck:
            break
        }
    }

    /// The puck can answer before its screen takes text, so the display
    /// resync waits a second after a relink, and only the latest one runs.
    private nonisolated static func relink(
        _ identity: [UInt8], input: InputBox, output: TabletOutput, backend: any HIDBackend
    ) {
        output.relink(identity: identity) { ret in
            backend.performOnInput(after: 0) {
                guard let generation = input.value.relinkWriteFinished(ret == kIOReturnSuccess) else { return }
                backend.performOnInput(after: 1) {
                    guard input.value.relinkGeneration == generation else { return }
                    output.resyncAfterRelink()
                }
            }
        }
    }

    /// Runs `body` on main: now if already there, as during replay.
    nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }
}

/// Why a transport stopped working.
package enum TabletFailure: Sendable, Equatable {
    /// The system refused access: Input Monitoring isn't granted.
    case permissionDenied
    /// The interface wouldn't open, often because another tablet driver holds it.
    case openFailed(IOReturn)
}

/// A transport's input state, touched only on the input executor.
final class InputBox: @unchecked Sendable {
    var value: TabletInput
    init(_ value: TabletInput) { self.value = value }
}
