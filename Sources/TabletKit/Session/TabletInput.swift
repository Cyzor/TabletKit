// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.cyzor.tabletkit", category: "input")

/// What a connected tablet's reports mean, one report at a time.
///
/// Holds everything between "a report arrived" and "these are its events":
/// the checks that run before decoding, the decoders (including touch
/// sensors read from a descriptor or a fixed layout), the IntuosV3
/// Bluetooth identity fix-ups, and the wireless receiver's link gate. It
/// does no I/O. What needs a write comes back as an ``Effect`` for the
/// owner of the interfaces to carry out. Time comes from each report's
/// arrival, so replaying a recording gives the same result as the live run.
///
/// Call from the input executor only.
package struct TabletInput {
    /// The tablet's spec. A wireless receiver takes on its paired tablet's
    /// touch capability when the tablet is named.
    package private(set) var spec: TabletSpec
    package let isBluetooth: Bool
    package let isWireless: Bool
    /// The tablet a wireless receiver is paired with, or 0 until it says.
    package private(set) var pairedProductID = 0
    /// The finger range a touch sensor's descriptor declares. `exact` marks
    /// a range from the report the decoder parses.
    package private(set) var touchRange: (x: Int, y: Int, exact: Bool)?

    /// Something the owner of the interfaces should do.
    package enum Effect: Sendable, Equatable {
        /// Send init again: the tablet sat on its idle report, the pen's
        /// announcement stopped arriving, or a receiver's link came up.
        case resendInit(InitReason)
        /// A wireless receiver named the tablet it's paired with.
        case pairedTablet(productID: Int)
        /// A relayed Quick Keys puck needs relinking, addressed to this
        /// identity. Report the write's result with ``relinkWriteFinished(_:)``.
        case relinkPuck(identity: [UInt8])
    }

    package enum InitReason: Sendable, Equatable {
        case stuckOnIdleReport(reportID: UInt8)
        case toolAnnouncementDrought
        case wirelessLinkUp
    }

    /// One report's events, as consumers should see them, and what to do.
    package struct Output: Sendable {
        package var events: [TabletEvent] = []
        package var effects: [Effect] = []
    }

    private var decoder: DeviceDecoder
    private var toolGrace: ToolAnnouncementGrace
    private var touchDecoders: [UInt8: PrecisionTouchDecoder] = [:]
    private var fixedTouchDecoders: [UInt8: DeviceDecoder] = [:]
    private var idleWatcher: IdleReportWatcher?
    private var pairingWatcher = DonglePairingWatcher()
    private var relayWatcher = XencelabsRelayWatcher()
    private var remoteLinks = ExpressKeyRemoteWatcher()

    private var lastRealToolAnnouncementNs: UInt64?
    private var lastAnnouncementRecoveryNs: UInt64?
    private var lastRealToolIdentity: ToolIdentity?

    private var wirelessReady = false
    private var wirelessLinkConfirmed = false
    private var batteryWarningLogged = false
    private var wirelessLastAcceptedPoint: TabletPoint?
    private var lastRemotePairingSummary: String?

    /// How long a Bluetooth LE session can go without a real announcement
    /// before it's treated as stuck. It can stop arriving for 30 s or more
    /// after enough proximity cycling.
    private static let toolAnnouncementDroughtNs: UInt64 = 8_000_000_000
    /// Debounce for the drought's init resend.
    private static let toolAnnouncementRecoveryCooldownNs: UInt64 = 8_000_000_000
    /// Log-only check for receiver chatter: a corrupted byte over RF tends to
    /// jump one axis while the other stays put.
    private static let wirelessOutlierFraction = 0.2
    /// The Xencelabs vendor tunnel. The family's other interfaces carry
    /// unrelated mouse traffic that would misdecode as stuck keys.
    private static let xencelabsVendorUsagePage = 0xFF0A
    /// Report IDs `IntuosV2Decoder` handles itself, which a descriptor-derived
    /// touch decoder must never shadow. Its 0x21 touch report is the one
    /// verified on hardware.
    private static let intuosV2ReservedReportIDs: Set<UInt8> = [0x01, 0x03, 0x10, 0x1E, 0x11, 0x21, 0x80]

    package init(spec: TabletSpec, isBluetooth: Bool, isWireless: Bool) {
        self.spec = spec
        self.isBluetooth = isBluetooth
        self.isWireless = isWireless
        decoder = DeviceDecoder(format: spec.format, digitizer: spec.digitizerSpec, family: spec.family)
        toolGrace = ToolAnnouncementGrace(frames: spec.quirks.toolAnnounceGraceFrames ?? 0)
        idleWatcher = spec.quirks.usbIdleReport.map(IdleReportWatcher.init)
    }

    /// The ranges reports are read against.
    package var digitizer: DigitizerSpec { decoder.digitizer }

    /// Whether the pen was in range after the last report.
    package var penInRange: Bool { decoder.penInRange }

    /// Whether reports from an interface on `usagePage` should be decoded.
    package func accepts(usagePage: Int) -> Bool {
        spec.format != .xencelabs || usagePage == Self.xencelabsVendorUsagePage
    }

    /// Adds the touch decoders `interface`'s descriptor or product ID calls for.
    package mutating func register(_ interface: any HIDInterface) {
        deriveTouchDecoders(from: interface.reportDescriptor)
        deriveFixedTouchDecoder(productID: interface.productID, descriptor: interface.reportDescriptor)
    }

    /// Records a Quick Keys relink write's result. Returns the relink
    /// generation to resync the display for, or nil when none is due.
    package mutating func relinkWriteFinished(_ succeeded: Bool) -> Int? {
        relayWatcher.relinkSent(succeeded: succeeded)
    }

    /// Advances whenever the puck links or drops, so a resync scheduled for
    /// an older link doesn't run.
    package var relinkGeneration: Int { relayWatcher.relinkGeneration }

    // MARK: - One report

    package mutating func handle(_ report: HIDReport, at ns: UInt64) -> Output {
        let now = ns != 0 ? ns : DispatchTime.now().uptimeNanoseconds
        var output = Output()
        recoverFromUSBIdleReport(report, now: now, into: &output)
        adoptDonglePairedTablet(report, into: &output)
        noteXencelabsRelay(report, into: &output)
        noteRemoteLinks(report)

        let wasInProximity = decoder.penInRange
        let graceEnded = toolGrace.advance(penInRange: wasInProximity)
        let decoded = decode(report, now: now, synthesizeToolEnter: isBluetooth && graceEnded, into: &output)
        output.events = gate(decoded, wasInProximity: wasInProximity, into: &output)
        return output
    }

    private mutating func recoverFromUSBIdleReport(_ report: HIDReport, now: UInt64, into output: inout Output) {
        let name = spec.name
        guard !isBluetooth, var watcher = idleWatcher else { return }
        let stuck = watcher.observe(report, now: Double(now) / 1_000_000_000)
        idleWatcher = watcher
        guard stuck else { return }
        let rule = watcher.rule
        logger.info("\(name, privacy: .public): USB stuck on idle report 0x\(String(rule.reportID, radix: 16), privacy: .public) for over \(rule.timeout, privacy: .public)s; sending init again")
        output.effects.append(.resendInit(.stuckOnIdleReport(reportID: rule.reportID)))
    }

    private mutating func adoptDonglePairedTablet(_ report: HIDReport, into output: inout Output) {
        let name = spec.name
        guard isWireless, let paired = pairingWatcher.observe(report), paired != pairedProductID,
            let pairedSpec = WacomDeviceRegistry.spec(for: paired), pairedSpec.maxX > 0, pairedSpec.maxY > 0
        else { return }
        // A paired row with no touch data (one never decoded) mustn't turn
        // off the receiver's own touch mid-session.
        var updated = pairedSpec.digitizerSpec
        if decoder.digitizer.hasFingerTouch, !updated.hasFingerTouch {
            updated.hasFingerTouch = true
            updated.maxTouchContacts = decoder.digitizer.maxTouchContacts
        }
        decoder.digitizer = updated
        spec = Self.applyingTouchCapability(pairedSpec, to: spec)
        pairedProductID = paired
        logger.info("\(name, privacy: .public): paired tablet 0x\(String(paired, radix: 16, uppercase: true), privacy: .public) — maxX=\(pairedSpec.maxX, privacy: .public) maxY=\(pairedSpec.maxY, privacy: .public) maxPressure=\(pairedSpec.maxPressure, privacy: .public)")
        output.effects.append(.pairedTablet(productID: paired))
    }

    private mutating func noteXencelabsRelay(_ report: HIDReport, into output: inout Output) {
        let name = spec.name
        guard spec.format == .xencelabs else { return }
        let relink = relayWatcher.observe(report, productID: spec.productID)
        switch relink.linkChange {
        case .online: logger.info("\(name, privacy: .public): puck online again, re-arming relink")
        case .offline: logger.info("\(name, privacy: .public): puck offline")
        case nil: break
        }
        if let identity = relink.relinkIdentity { output.effects.append(.relinkPuck(identity: identity)) }
    }

    private mutating func noteRemoteLinks(_ report: HIDReport) {
        let name = spec.name
        guard spec.format == .expressKeyRemote else { return }
        for change in remoteLinks.observe(report) {
            logger.info("\(name, privacy: .public): remote \(change.serial, privacy: .public) \(change.link == .online ? "online" : "unpaired", privacy: .public)")
        }
    }

    // MARK: - Decoding

    /// Decodes with the touch decoder for the report's ID, or the main
    /// decoder plus the IntuosV3 Bluetooth identity fix-ups.
    private mutating func decode(
        _ report: HIDReport, now: UInt64, synthesizeToolEnter: Bool, into output: inout Output
    ) -> [TabletEvent] {
        let name = spec.name
        if report.count > 0, var fixed = fixedTouchDecoders[report[0]] {
            // A hand-specified layout wins over a derived one.
            fixed.digitizer = decoder.digitizer
            let events = fixed.events(report)
            fixedTouchDecoders[report[0]] = fixed
            return events
        }
        if report.count > 0, let touch = touchDecoders[report[0]] {
            return touch.decode(report: report).map { [.touch(TouchFrame(contacts: $0.contacts))] } ?? []
        }
        var decoded = decoder.events(report)
        // Over Bluetooth the decoder also announces an Art Pen it infers from
        // a twisted barrel, alongside that frame's pen point. A real
        // announcement arrives alone, so only that one counts here.
        var point: TabletPoint?
        var toolEnter: ToolIdentity?
        for event in decoded {
            switch event {
            case .pen(let p) where point == nil: point = p
            case .tool(let t) where toolEnter == nil && t.phase == .enter: toolEnter = t.identity
            default: break
            }
        }
        let inferredArtPen = spec.format == .intuosV3 && isBluetooth && point != nil
        if let toolEnter, !(inferredArtPen && toolEnter.serial == 0 && toolEnter.toolCode == 0x0804) {
            lastRealToolAnnouncementNs = now
            lastRealToolIdentity = toolEnter
        }
        let decoderEmittedToolEnter = toolEnter != nil
        if synthesizeToolEnter, !decoderEmittedToolEnter, decoder.penInRange, let point {
            // Most sessions use one pen, so a missed announcement usually
            // means the same pen came back: reuse its identity if the end
            // matches, rather than a generic one.
            let identity: ToolIdentity
            if let cached = lastRealToolIdentity, cached.isEraser == point.eraser {
                identity = cached
            } else {
                identity = ToolIdentity(
                    serial: 0, toolCode: point.eraser ? 0x0008 : 0x0000, isEraser: point.eraser, isMouse: false)
            }
            decoded.insert(.tool(ToolEvent(identity: identity, phase: .enter)), at: 0)
            // The real announcement can stop arriving entirely; init brings
            // it back. Debounced so a stuck session isn't resent every frame.
            let sinceReal = lastRealToolAnnouncementNs.map { now &- $0 } ?? .max
            let sinceRecovery = lastAnnouncementRecoveryNs.map { now &- $0 } ?? .max
            if sinceReal > Self.toolAnnouncementDroughtNs, sinceRecovery > Self.toolAnnouncementRecoveryCooldownNs {
                lastAnnouncementRecoveryNs = now
                logger.info("\(name, privacy: .public): no real BLE tool announcement in over 8s — re-sending DATAMODE to recover")
                output.effects.append(.resendInit(.toolAnnouncementDrought))
            }
        }
        return decoded
    }

    // MARK: - Gating

    /// Applies the receiver's link gate and the Pen Display's bezel layout,
    /// and acts on link and battery status, in report order. Returns the
    /// events unchanged, without copying, for tablets with neither.
    private mutating func gate(
        _ decoded: [TabletEvent], wasInProximity: Bool, into output: inout Output
    ) -> [TabletEvent] {
        guard isWireless || (spec.format == .xencelabs && spec.isPenDisplay) else {
            for case .device(let device) in decoded { note(device, into: &output) }
            return decoded
        }
        let name = spec.name
        var events: [TabletEvent] = []
        events.reserveCapacity(decoded.count)
        for event in decoded {
            switch event {
            case .pen(let point):
                guard !isWireless || wirelessReady else { continue }
                if !wasInProximity { wirelessLastAcceptedPoint = nil }
                if isWireless, let last = wirelessLastAcceptedPoint, point.maxX > 0, point.maxY > 0 {
                    let dx = abs(point.x - last.x), dy = abs(point.y - last.y)
                    let xOutlier = Double(dx) > Double(point.maxX) * Self.wirelessOutlierFraction && dy < point.maxY / 20
                    let yOutlier = Double(dy) > Double(point.maxY) * Self.wirelessOutlierFraction && dx < point.maxX / 20
                    if xOutlier || yOutlier {
                        logger.warning("\(name, privacy: .public): candidate wireless coordinate outlier — last=(\(last.x, privacy: .public),\(last.y, privacy: .public)) new=(\(point.x, privacy: .public),\(point.y, privacy: .public)) maxX=\(point.maxX, privacy: .public) maxY=\(point.maxY, privacy: .public)")
                    }
                }
                wirelessLastAcceptedPoint = point
                events.append(event)
            case .tool:
                guard !isWireless || wirelessReady else { continue }
                events.append(event)
            case .pad(var pad):
                // The Pen Display's three bezel buttons arrive as aux keys 0–2;
                // they also go to the bezel slots, 16–18.
                if spec.format == .xencelabs && spec.isPenDisplay {
                    let bezel = (0..<3).map { pad.buttons.indices.contains($0) && pad.buttons[$0] }
                    while pad.buttons.count < 19 { pad.buttons.append(false) }
                    pad.buttons.replaceSubrange(16..<19, with: bezel)
                }
                events.append(.pad(pad))
            case .device(let device):
                note(device, into: &output)
                events.append(event)
            case .dial, .touch:
                events.append(event)
            }
        }
        return events
    }

    /// Acts on link status, and logs what's worth logging.
    private mutating func note(_ device: DeviceEvent, into output: inout Output) {
        let name = spec.name
        switch device.kind {
        case .wireless:
            if let status = device.wireless { handleWirelessStatus(status, into: &output) }
        case .toolSupport:
            logger.info("\(name, privacy: .public): \(device.unsupportedToolNote ?? "", privacy: .public)")
        case .remotePairing:
            // The receiver repeats its table about twice a second; log it
            // only when it changes.
            let paired = (device.remotePairing ?? []).filter(\.connected)
                .map { "\($0.index):\($0.serial)" }.joined(separator: ",")
            if paired != lastRemotePairingSummary {
                lastRemotePairingSummary = paired
                logger.info("\(name, privacy: .public): paired remotes [\(paired.isEmpty ? "none" : paired, privacy: .public)]")
            }
        default:
            break
        }
    }


    private mutating func handleWirelessStatus(_ status: WirelessStatus, into output: inout Output) {
        let name = spec.name
        switch status {
        case .active:
            // Receivers repeat the status; act once per link.
            guard !wirelessLinkConfirmed else { return }
            logger.info("\(name, privacy: .public): wireless link active")
            // Coordinates and identity from before the link are stale.
            decoder.reset()
            wirelessReady = true
            wirelessLinkConfirmed = true
            batteryWarningLogged = false
            output.effects.append(.resendInit(.wirelessLinkUp))
        case .lost:
            if wirelessLinkConfirmed {
                logger.info("\(name, privacy: .public): wireless link lost")
                wirelessLinkConfirmed = false
            }
            wirelessReady = false
            batteryWarningLogged = false
            decoder.reset()
        case .lowBattery:
            if !batteryWarningLogged {
                logger.warning("\(name, privacy: .public): battery critically low")
                batteryWarningLogged = true
            }
        case .unknown:
            break
        }
    }

    // MARK: - Touch decoders

    private mutating func deriveTouchDecoders(from descriptor: [UInt8]) {
        guard spec.hasFingerTouch, !descriptor.isEmpty,
            let layout = try? HIDReportDescriptorParser.parse(descriptor)
        else { return }
        let reserved: Set<UInt8> = spec.format == .intuosV2 ? Self.intuosV2ReservedReportIDs : []
        for touchLayout in PrecisionTouchLayout.derive(from: layout) {
            guard !reserved.contains(touchLayout.reportID), touchDecoders[touchLayout.reportID] == nil else { continue }
            touchDecoders[touchLayout.reportID] = PrecisionTouchDecoder(layout: touchLayout)
            if touchLayout.logicalMaxX > 0, touchLayout.logicalMaxY > 0, touchRange?.exact != true {
                touchRange = (touchLayout.logicalMaxX, touchLayout.logicalMaxY, true)
                DescribedTouchRanges.record(touchRange!, forProductID: spec.productID)
            }
        }
    }

    private mutating func deriveFixedTouchDecoder(productID: Int, descriptor: [UInt8]) {
        guard let entry = DeviceDecoder.fixedLayoutTouch(
                productID: productID, digitizer: decoder.digitizer, family: spec.family),
            fixedTouchDecoders[entry.reportID] == nil
        else { return }
        fixedTouchDecoders[entry.reportID] = entry.decoder
        // Vendor-format reports, but the descriptor still names the finger
        // range, where Linux reads it for these sensors.
        guard !descriptor.isEmpty, let layout = try? HIDReportDescriptorParser.parse(descriptor) else { return }
        let fingerFields = layout.reports.filter { $0.direction == .input }.flatMap(\.fields)
            .filter { $0.collectionPath.contains(0x000D_0022) && $0.logicalMax > 0 }
        guard let x = fingerFields.first(where: { $0.extendedUsage == 0x0001_0030 })?.logicalMax,
            let y = fingerFields.first(where: { $0.extendedUsage == 0x0001_0031 })?.logicalMax
        else { return }
        if touchRange == nil {
            touchRange = (x, y, false)
            DescribedTouchRanges.record(touchRange!, forProductID: spec.productID)
        }
    }

    /// A receiver's spec with its paired tablet's touch capability. Its own
    /// identity, format, and init stay.
    private static func applyingTouchCapability(_ paired: TabletSpec, to base: TabletSpec) -> TabletSpec {
        guard paired.hasFingerTouch else { return base }
        return TabletSpec(
            productID: base.productID, name: base.name, format: base.format,
            maxX: base.maxX, maxY: base.maxY, maxPressure: base.maxPressure,
            buttonCount: base.buttonCount, bezelButtonCount: base.bezelButtonCount,
            hasTouchRing: base.hasTouchRing, hasDualRings: base.hasDualRings,
            hasMechanicalDial: base.hasMechanicalDial, hasKeyOLEDs: base.hasKeyOLEDs,
            hasTouchStrips: base.hasTouchStrips, ringSlotCount: base.ringSlotCount,
            hasEraser: base.hasEraser, hasTilt: base.hasTilt, tiltMaxDegrees: base.tiltMaxDegrees,
            hasFingerTouch: true, maxTouchContacts: paired.maxTouchContacts,
            touchMaxX: paired.touchMaxX, touchMaxY: paired.touchMaxY,
            isPenDisplay: base.isPenDisplay, seizeUSB: base.seizeUSB,
            initSteps: base.initSteps, ledCompanionPID: base.ledCompanionPID,
            confidence: base.confidence, productStringMatch: base.productStringMatch,
            activeWidthMM: base.activeWidthMM, activeHeightMM: base.activeHeightMM)
            .with(quirks: base.quirks)
    }
}
