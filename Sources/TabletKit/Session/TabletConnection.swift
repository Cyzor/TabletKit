// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import IOKit.hid
import OSLog

private let logger = Logger(subsystem: "com.cyzor.tabletkit", category: "connect")

/// One connected tablet's interfaces, and the sequence that switches it on.
///
/// Opening, registering, and closing happen on the main actor. Everything
/// that talks to the tablet runs in order on its output queue: the init
/// steps, the mode read-back, the serial read, and saving a touch sensor's
/// mode. A slow write delays the next write, never a pen report.
///
/// `@unchecked Sendable`: its own state is touched only on the main actor.
/// Work sent to the output queue captures what it needs.
package final class TabletConnection: @unchecked Sendable {
    package let spec: TabletSpec
    package let primary: any HIDInterface
    package let seize: Bool
    package let output: HIDOutputQueue
    /// Whether the primary interface is on Bluetooth. Set by ``open(onReport:)``.
    package private(set) var isBluetooth = false
    /// Every interface that delivers or takes reports, primary first.
    package private(set) var interfaces: [any HIDInterface] = []
    /// The interface that declares the init feature reports, where the
    /// format needs one found.
    package private(set) var capableInterface: (any HIDInterface)?
    package private(set) var ledInterface: (any HIDInterface)?

    /// Each write and read of the connect sequence, on the output queue.
    package var onStep: (@Sendable (ConnectStep) -> Void)?
    /// The tablet's hardware serial, or 0 when it doesn't give one. Reported
    /// once, on the output queue.
    package var onSerial: (@Sendable (UInt32) -> Void)?

    private let savedTouchModes = SavedModes()
    private var onReport: (@Sendable (any HIDInterface, HIDReport, UInt64) -> Void)?

    package enum ConnectStep: Sendable, Equatable {
        case wrote(reportID: Int, value: Int, result: IOReturn, usagePage: Int)
        case read(purpose: String, reportID: Int, result: IOReturn, reply: [UInt8], usagePage: Int)
        case inputMode(usagePage: Int)
    }

    /// Xencelabs writes are paced 3 ms apart: firmware busy repainting drops
    /// a write and still reports success.
    package init(primary: any HIDInterface, spec: TabletSpec, seize: Bool) {
        self.primary = primary
        self.spec = spec
        self.seize = seize
        output = HIDOutputQueue(label: "com.cyzor.tabletkit.output", minimumGap: 0.003)
    }

    // MARK: - Lifecycle

    /// Opens the primary interface and starts the connect sequence.
    /// `onReport` runs on ``HIDThread`` for every interface's reports.
    /// Returns the open's result; nothing else happens if it fails.
    @MainActor
    package func open(
        accepts: @escaping (any HIDInterface) -> Bool,
        onReport: @escaping @Sendable (any HIDInterface, HIDReport, UInt64) -> Void
    ) -> IOReturn {
        isBluetooth = primary.transport.lowercased().contains("bluetooth")
        self.onReport = onReport
        self.accepts = accepts
        let primary = self.primary
        let ret = primary.open(seize: seize) { report, ns in onReport(primary, report, ns) }
        let name = spec.name
        guard ret == kIOReturnSuccess else {
            logger.error("\(name, privacy: .public) (0x\(String(self.spec.productID, radix: 16, uppercase: true), privacy: .public)): failed to open (seize=\(self.seize, privacy: .public)) — \(ret, privacy: .public). Is another tablet driver running?")
            return ret
        }
        interfaces = [primary]
        logger.info("\(name, privacy: .public): opened (transport=\(primary.transport, privacy: .public))")

        // IntuosV2 USB: the InputMode switch turns on full tablet mode. Over
        // Bluetooth it would suppress pen data.
        if spec.quirks.inputModeWriteOverUSB && !isBluetooth { sendInputMode(on: primary) }
        // Intuos Pro gen 3 over BLE starts on a minimal report and needs the
        // same DATAMODE write as USB.
        if isBluetooth && spec.quirks.initOverBluetooth { runInit() }
        if !isBluetooth {
            // Some multi-interface tablets have no guarantee the primary is the
            // interface that takes the mode switch. Wait for a sibling that
            // declares it rather than send a write that lands nowhere.
            if spec.quirks.initNeedsDeclaringInterface {
                if declaresInitFeatureReports(primary) {
                    capableInterface = primary
                    runInit()
                } else {
                    logger.info("\(name, privacy: .public): primary interface does not declare the init feature reports — deferring init to a sibling interface")
                }
            } else {
                runInit()
            }
            // The serial is the same over every transport, which is how one
            // tablet's connections are told apart from another's. Xencelabs
            // never answers, and the read would block for the kernel's timeout.
            if spec.quirks.answersSerialQuery {
                readSerial()
            } else {
                let onSerial = onSerial
                output.perform { onSerial?(0) }
            }
        }
        if !accepts(primary) {
            logger.info("\(name, privacy: .public): primary interface is not the vendor tunnel — decode disabled on it, waiting for the real interface")
        }
        return ret
    }

    private var accepts: ((any HIDInterface) -> Bool)?

    /// Adds a sibling interface of the same tablet.
    @MainActor
    package func register(_ interface: any HIDInterface) {
        register(interface, alreadyOpen: false)
    }

    @MainActor
    private func register(_ interface: any HIDInterface, alreadyOpen: Bool) {
        let name = spec.name
        if !alreadyOpen, accepts?(interface) ?? true, let onReport {
            _ = interface.open(seize: false) { report, ns in onReport(interface, report, ns) }
        }
        interfaces.append(interface)
        logger.info("\(name, privacy: .public): registered interface (transport=\(interface.transport, privacy: .public))\(self.accepts?(interface) ?? true ? "" : " — non-vendor interface, decode disabled on it")")
        // PTH-660 and PTH-860 use one product ID on both transports, so a USB
        // interface can join a Bluetooth connection; gate on its own transport.
        let interfaceIsBluetooth = interface.transport.lowercased().contains("bluetooth")
        if spec.quirks.inputModeWriteOverUSB && !interfaceIsBluetooth { sendInputMode(on: interface) }
        if spec.quirks.initNeedsDeclaringInterface, !interfaceIsBluetooth, capableInterface == nil,
            declaresInitFeatureReports(interface)
        {
            capableInterface = interface
            runInit(on: interface)
        }
        // Xencelabs re-enumerates about 5 s after connecting, and the new
        // handle never got the tablet-mode init.
        if spec.quirks.reinitOnReenumeration && !isBluetooth && (accepts?(interface) ?? true) {
            runInit(on: interface)
        }
        // A touch sensor with its own product ID takes its mode write itself,
        // after its reports are being received.
        if !spec.touchCompanionInitSteps.isEmpty, let companion = spec.touchCompanionPID,
            interface.productID == companion
        {
            let steps = spec.touchCompanionInitSteps
            if declaresInitFeatureReports(interface, for: steps) {
                saveTouchModes(of: interface, before: steps)
                runInit(on: interface, steps: steps)
            } else {
                logger.info("\(name, privacy: .public): touch sensor does not declare the Device Mode feature report — skipping multitouch init")
            }
        }
    }

    /// Adds a touch sensor that arrives as its own USB device, seizing it
    /// first where the format needs that: on CintiqV1 its touchscreen
    /// collection otherwise also reaches macOS.
    @MainActor
    package func attachTouchSensor(_ interface: any HIDInterface) {
        guard spec.quirks.seizesTouchSensor, let onReport else { return register(interface) }
        // The system opened it without options, and a second open from the
        // same client ignores seize, so close it first.
        interface.close()
        let ret = interface.open(seize: true) { report, ns in onReport(interface, report, ns) }
        if ret == kIOReturnSuccess {
            logger.info("\(self.spec.name, privacy: .public): seized touch sensor")
            register(interface, alreadyOpen: true)
        } else {
            logger.error("\(self.spec.name, privacy: .public): failed to seize touch sensor — \(ret, privacy: .public)")
            register(interface)
        }
    }

    /// Adds the separate interface some Cintiqs take LED writes on.
    @MainActor
    package func registerLED(_ interface: any HIDInterface) {
        let ret = interface.open(seize: false) { _, _ in }
        logger.info("\(self.spec.name, privacy: .public): LED companion interface registered (open ret=\(ret, privacy: .public))")
        ledInterface = interface
    }

    /// Sends the init sequence again, as after sleep or when the tablet
    /// seems to have lost its mode. Not over Bluetooth, where InputMode
    /// would suppress pen data, except where the format needs DATAMODE.
    @MainActor
    package func reawaken() {
        guard !isBluetooth || spec.quirks.initOverBluetooth else { return }
        runInit()
    }

    /// Restores any touch sensor mode the connect sequence changed, then
    /// closes every interface.
    @MainActor
    package func close() {
        let saved = savedTouchModes
        let name = spec.name
        let onStep = onStep
        output.performAndWait {
            for (interface, bytes) in saved.take() {
                let ret = interface.setReport(.feature, bytes: bytes)
                if ret != kIOReturnSuccess {
                    logger.info("\(name, privacy: .public) restore touch mode failed: 0x\(String(ret, radix: 16), privacy: .public)")
                }
                onStep?(.wrote(reportID: Int(bytes[0]), value: Int(bytes.count > 1 ? bytes[1] : 0),
                               result: ret, usagePage: interface.usagePage))
            }
        }
        for interface in interfaces { interface.close() }
        ledInterface?.close()
        interfaces.removeAll()
        ledInterface = nil
        capableInterface = nil
        onReport = nil
    }

    // MARK: - The connect sequence

    /// Runs `steps`, or the tablet's own, on the output queue. The tablet's
    /// own sequence is confirmed by reading the mode back where the quirks
    /// ask for it.
    @MainActor
    private func runInit(on target: (any HIDInterface)? = nil, steps: [InitStep]? = nil) {
        let interface = target ?? capableInterface ?? primary
        let steps = steps ?? spec.initSteps
        let readBack = steps == spec.initSteps && !isBluetooth ? spec.quirks.usbModeReadBack : nil
        let name = spec.name
        let onStep = onStep
        let queue = output.dispatchQueue
        output.perform {
            let usagePage = interface.usagePage
            let lastIndex = steps.count - 1
            InitStepRunner.run(steps, on: interface, queue: queue) { outcome in
                let index = outcome.index
                switch outcome.step {
                case .featureReport(let bytes):
                    let ret = outcome.result ?? kIOReturnSuccess
                    if ret != kIOReturnSuccess {
                        logger.error("hidSetReport \(name, privacy: .public) initStep[\(index, privacy: .public)] failed: \(String(format: "0x%08x", ret), privacy: .public)")
                    } else {
                        logger.info("\(name, privacy: .public): initStep[\(index, privacy: .public)] feature report succeeded on interface usagePage=0x\(String(usagePage, radix: 16), privacy: .public)")
                    }
                    onStep?(.wrote(reportID: Int(bytes[0]), value: Int(bytes.count > 1 ? bytes[1] : 0),
                                   result: ret, usagePage: usagePage))
                case .outputReport(let bytes):
                    let hex = String(format: "0x%08x", outcome.result ?? kIOReturnSuccess)
                    let padding = outcome.sentLength > bytes.count ? " (padded to \(outcome.sentLength))" : ""
                    logger.info("\(name, privacy: .public): initStep[\(index, privacy: .public)] output report\(padding, privacy: .public) result=\(hex, privacy: .public)")
                case .stringDescriptor(let descriptorIndex):
                    logger.info("\(name, privacy: .public): initStep[\(index, privacy: .public)] string descriptor \(descriptorIndex, privacy: .public) → \(outcome.reply.map { "\($0.count) bytes" } ?? "no answer", privacy: .public)")
                case .delay:
                    break
                }
                if index == lastIndex, let readBack {
                    Self.confirmMode(readBack, on: interface, queue: queue, name: name, onStep: onStep)
                }
            }
        }
    }

    private static func confirmMode(
        _ rule: TabletQuirks.ModeReadBack, on interface: any HIDInterface, queue: DispatchQueue,
        name: String, onStep: (@Sendable (ConnectStep) -> Void)?
    ) {
        let usagePage = interface.usagePage
        InitStepRunner.confirmMode(rule, on: interface, queue: queue) { o in
            let reply = o.reply.map { String(format: "%02X", $0) }.joined(separator: " ")
            onStep?(.read(purpose: "mode read-back", reportID: Int(rule.report[0]), result: o.readResult,
                          reply: o.reply, usagePage: usagePage))
            if let written = o.writeResult {
                onStep?(.wrote(reportID: Int(rule.report[0]), value: Int(rule.report[1]),
                               result: written, usagePage: usagePage))
            }
            if o.matched {
                logger.info("\(name, privacy: .public): mode read back as \(reply, privacy: .public) after \(o.attempt, privacy: .public) resends")
            } else if o.isLast {
                logger.error("\(name, privacy: .public): mode didn't take after \(o.attempt, privacy: .public) resends; read back \(reply.isEmpty ? "nothing" : reply, privacy: .public) (0x\(String(o.readResult, radix: 16), privacy: .public))")
            } else {
                logger.info("\(name, privacy: .public): mode read back as \(reply.isEmpty ? "nothing" : reply, privacy: .public); resending")
            }
        }
    }

    /// Reads the hardware serial: feature report 0x03, firmware version in
    /// bytes 1–3 and the serial, little-endian, in bytes 4–7. The step
    /// observer gets the reply with the serial zeroed.
    @MainActor
    private func readSerial() {
        let interface = primary
        let name = spec.name
        let productID = spec.productID
        let onStep = onStep
        let onSerial = onSerial
        output.perform {
            let (ret, reply) = interface.getReport(.feature, id: 0x03, length: 64)
            var redacted = ret == kIOReturnSuccess ? reply : []
            for i in redacted.indices where (4..<8).contains(i) { redacted[i] = 0 }
            onStep?(.read(purpose: "hardware serial", reportID: 3, result: ret, reply: redacted,
                          usagePage: interface.usagePage))
            guard ret == kIOReturnSuccess, reply.count >= 8 else { onSerial?(0); return }
            let serial = UInt32(reply[4]) | UInt32(reply[5]) << 8 | UInt32(reply[6]) << 16 | UInt32(reply[7]) << 24
            if serial != 0 {
                logger.info("\(name, privacy: .public) (0x\(String(productID, radix: 16, uppercase: true), privacy: .public)): hardware serial received")
            }
            onSerial?(serial)
        }
    }

    /// Reads the modes a touch sensor holds before its init changes them, so
    /// ``close()`` can put them back. The sensor keeps a mode until it loses
    /// power, and macOS mishandles ours: on Sequoia a hand on a 27QHD held the
    /// left button after quitting.
    private func saveTouchModes(of interface: any HIDInterface, before steps: [InitStep]) {
        let saved = savedTouchModes
        let onStep = onStep
        output.perform {
            for case .featureReport(let bytes) in steps {
                let (ret, current) = interface.getReport(.feature, id: bytes[0], length: bytes.count)
                onStep?(.read(purpose: "touch mode", reportID: Int(bytes[0]), result: ret,
                              reply: ret == kIOReturnSuccess ? current : [], usagePage: interface.usagePage))
                guard ret == kIOReturnSuccess, current.count == bytes.count, current.first == bytes[0],
                    current != bytes
                else { continue }
                saved.add(interface, current)
            }
        }
    }

    /// The HID Digitizer Input Mode switch, through the element IOKit
    /// builds the report from, which a plain feature write can't match.
    private func sendInputMode(on interface: any HIDInterface) {
        let name = spec.name
        let onStep = onStep
        output.perform {
            if let iokit = interface as? IOKitHIDInterface {
                sendWacomInputModeInit(iokit.device, tag: name)
            } else if let replay = interface as? ReplayInterface {
                replay.noteInputMode()
            }
            onStep?(.inputMode(usagePage: interface.usagePage))
        }
    }

    /// Whether `interface` declares every feature report `steps` write. An
    /// empty requirement matches any interface.
    private func declaresInitFeatureReports(_ interface: any HIDInterface, for steps: [InitStep]? = nil) -> Bool {
        let required = Set((steps ?? spec.initSteps).compactMap {
            if case .featureReport(let bytes) = $0 { bytes.first } else { nil }
        })
        guard !required.isEmpty else { return true }
        guard !interface.reportDescriptor.isEmpty,
            let layout = try? HIDReportDescriptorParser.parse(interface.reportDescriptor)
        else { return false }
        let declared = Set(layout.reports.filter { $0.direction == .feature }.map(\.reportID))
        return required.isSubset(of: declared)
    }
}

/// Touch sensor modes to restore, filled on the output queue and taken on
/// close, after the queue has drained.
private final class SavedModes: @unchecked Sendable {
    private let lock = NSLock()
    private var modes: [(any HIDInterface, [UInt8])] = []

    func add(_ interface: any HIDInterface, _ bytes: [UInt8]) { lock.withLock { modes.append((interface, bytes)) } }

    func take() -> [(any HIDInterface, [UInt8])] {
        lock.withLock {
            defer { modes.removeAll() }
            return modes
        }
    }
}
