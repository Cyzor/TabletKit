// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import IOKit
import OSLog

private let logger = Logger(subsystem: "com.cyzor.tabletkit", category: "output")

/// Everything a host can set on one tablet: ring and dial LEDs, key
/// displays, Quick Keys settings, and a pen display's panel.
///
/// Each setter runs on the tablet's output queue, where its caches live, so
/// a write never waits on the input thread and repeated settings don't
/// resend. Interfaces arrive as the connection registers them; a Xencelabs
/// write made before the vendor tunnel exists waits for it.
///
/// `@unchecked Sendable`: all state is touched only on the output queue.
package final class TabletOutput: RingLEDControl, LabelControl, DisplayPanelControl, QuickKeysControl,
    @unchecked Sendable
{
    package let spec: TabletSpec
    private let queue: HIDOutputQueue

    // Interfaces, set as the connection learns them.
    private var primary: (any HIDInterface)?
    private var sibling: (any HIDInterface)?
    private var capable: (any HIDInterface)?
    private var led: (any HIDInterface)?
    private var isBluetooth = false
    private var isWireless = false
    private var pairedProductID = 0

    // Ring LEDs.
    private var ledIndex = 0
    private var ledIndex2 = 0
    private var dialSlotColors: [LEDColor?] = []

    // Xencelabs.
    private var dongleIdentity: [UInt8]?
    private var sentText: [String: String] = [:]
    private var requestedText: [String: String] = [:]
    private var lastOrientation = -1
    private var lastSleepMinutes = -1
    private var lastOLEDBrightness = -1
    private var lastDisplayBrightness = -1
    private var lastDisplayContrast = -1
    private var lastDisplayGamma = -1
    private var lastColorMode = -1
    private var lastBezelLED: LEDColor?
    private var pendingVendorWrites: [(bytes: [UInt8], tag: String)] = []
    private var pendingVendorWritesDropped = false
    private var batteryPoll: DispatchSourceTimer?
    private var lastReportNs: UInt64?

    // Intuos4 key displays.
    private var sentKeyLabels: [String] = []
    private var keyOLEDsRotated180 = false

    private static let maxPendingVendorWrites = 64
    /// Intuos5 and Intuos Pro gen 1 pack the slot and both luminances into one byte.
    private static let intuos5PackedLEDProductIDs: Set<Int> = [
        0x0026, 0x0027, 0x0028, 0x0029, 0x002A, 0x0314, 0x0315, 0x0317,
    ]
    /// Ring and crop-mark luminance for those, 2-bit: 0 low, 1 medium, 2 high, 3 off.
    private static let intuos5RingLuminance: UInt8 = 0
    private static let intuos5CropLuminance: UInt8 = 0
    /// Intuos4 LED report luminances, 0–127: the kernel's defaults. A zero
    /// key display brightness can leave the displays dark.
    private static let intuos4RingLuminance: UInt8 = 10
    private static let intuos4PressedLuminance: UInt8 = 20
    private static let intuos4OLEDBrightness: UInt8 = 10

    /// The slots `controls` fills.
    package let offered: TabletControls.Kinds

    /// `isWirelessReceiver`: a receiver's own row has no ring, but the
    /// tablet it relays may, and `controls` is fixed before it says which.
    package init(spec: TabletSpec, queue: HIDOutputQueue, isWirelessReceiver: Bool = false) {
        self.spec = spec
        self.queue = queue
        var offered = spec.offeredControls
        if isWirelessReceiver && TabletSpec.ringLEDFormats.contains(spec.format) { offered.insert(.ringLED) }
        self.offered = offered
    }

    /// The controls this tablet offers: a slot is filled exactly when
    /// writing to it does something.
    package var controls: TabletControls {
        TabletControls(
            ringLED: offered.contains(.ringLED) ? self : nil,
            labels: offered.contains(.labels) ? self : nil,
            displayPanel: offered.contains(.displayPanel) ? self : nil,
            quickKeys: offered.contains(.quickKeys) ? self : nil)
    }

    private var hasDisplayPanel: Bool { offered.contains(.displayPanel) }

    // MARK: - Interfaces

    /// The connection's primary interface and transport.
    package func attach(primary: any HIDInterface, isBluetooth: Bool, isWireless: Bool) {
        queue.perform { [self] in
            self.primary = primary
            self.isBluetooth = isBluetooth
            self.isWireless = isWireless
        }
    }

    /// A sibling the connection registered. For Xencelabs only the vendor
    /// tunnel counts; it also releases writes held for it.
    package func addSibling(_ interface: any HIDInterface, isVendorTunnel: Bool, isInputModeInterface: Bool) {
        queue.perform { [self] in
            if spec.format == .xencelabs {
                guard isVendorTunnel else { return }
                sibling = interface
                flushPendingVendorWrites()
            } else if sibling == nil {
                sibling = interface
            }
            // An LED slot set before this interface existed.
            if isInputModeInterface && !isBluetooth { sendRingLED() }
        }
    }

    /// The interface that declares the init feature reports, once found.
    package func setCapableInterface(_ interface: any HIDInterface) {
        queue.perform { [self] in
            capable = interface
            sendRingLED()
        }
    }

    /// The separate interface some Cintiqs take LED writes on.
    package func setLEDInterface(_ interface: any HIDInterface) {
        queue.perform { [self] in
            led = interface
            sendRingLED()
        }
    }

    /// A wireless receiver's paired tablet, which picks its LED report.
    package func setPairedProductID(_ productID: Int) {
        queue.perform { [self] in pairedProductID = productID }
    }

    /// When the input path last decoded a report, for the battery poll's
    /// silence check.
    package func noteReport(at ns: UInt64) {
        queue.perform { [self] in lastReportNs = ns }
    }

    // MARK: - Ring LEDs

    package func setRingLED(index: Int) {
        queue.perform { [self] in
            ledIndex = index
            sendRingLED()
        }
    }

    /// The second ring's slot, on two-ring Cintiqs, which take both rings in
    /// one report.
    public func setRingLED2(index: Int) {
        queue.perform { [self] in
            guard spec.format == .cintiqV1, spec.hasDualRings else { return }
            ledIndex2 = index
            sendRingLED()
        }
    }

    package func setRingLEDColors(_ colors: [LEDColor?]) {
        queue.perform { [self] in
            guard spec.format == .xencelabs, colors != dialSlotColors else { return }
            dialSlotColors = colors
            sendRingLED()
        }
    }

    /// Shows the active slot on the ring LED. On the output queue.
    private func sendRingLED() {
        guard offered.contains(.ringLED), let primary else { return }
        let index = ledIndex
        let name = spec.name
        logger.info("\(name, privacy: .public): ring LED → slot \(index) (\(self.isBluetooth ? "BT" : "USB", privacy: .public))")
        switch spec.format {
        case .intuosV2 where !isBluetooth:
            // 0x31 sets every LED channel's brightness and 0x32 picks the
            // slot. The hardware counts from bottom left, so a four-slot ring
            // adds 1 to put mode 1 at top left.
            let slot = UInt8((index + (spec.ringSlotCount == 4 ? 1 : 0)) & 0x03)
            write(.feature, [0x31, 0x46, 0x46, 0x46, 0x46, 0x46], to: primary, tag: "\(name) USB LED brightness", bestEffort: true)
            write(.feature, [0x32, 0x46, slot], to: primary, tag: "\(name) USB LED slot=\(index)")
        case .intuosV2:
            // Report 0x82, 51 bytes: channel brightness at 4–9, slot at 10.
            let slot = UInt8((index + (spec.ringSlotCount == 4 ? 1 : 0)) & 0x03)
            var buf = [UInt8](repeating: 0, count: 51)
            buf[0] = 0x82
            buf[1] = 0x02
            for i in 4...9 { buf[i] = 0x46 }
            buf[10] = slot
            write(.feature, buf, to: primary, tag: "\(name) BT LED ring slot=\(index)")
        case .cintiqV1:
            // 0x20, 9 bytes: buf[1] = 0x44 | right ring's slot | left ring's << 4.
            // Ring 1 is the left; checked on a DTK-2400.
            let slot1 = UInt8(index & 0x03)
            let slot2 = UInt8(ledIndex2 & 0x03)
            var buf = [UInt8](repeating: 0, count: 9)
            buf[0] = 0x20
            buf[1] = 0x44 | slot2 | (slot1 << 4)
            write(.feature, buf, to: led ?? primary, tag: "\(name) CintiqV1 LED slots=\(slot1),\(slot2)")
        case .intuosV1:
            let slot = UInt8(index & 0x03)
            if isWireless && pairedProductID > 0 {
                // Through the ACK-40401: 0x03, 13 bytes, Intuos5 packing in
                // buf[4]. From the kernel; unchecked against a receiver.
                var buf = [UInt8](repeating: 0, count: 13)
                buf[0] = 0x03
                buf[4] = (Self.intuos5CropLuminance << 4) | (Self.intuos5RingLuminance << 2) | slot
                write(.feature, buf, to: primary, tag: "\(name) IntuosV1 WL LED slot=\(index)", bestEffort: true)
            } else if Self.intuos5PackedLEDProductIDs.contains(spec.productID) {
                var buf = [UInt8](repeating: 0, count: 9)
                buf[0] = 0x20
                buf[1] = (Self.intuos5CropLuminance << 4) | (Self.intuos5RingLuminance << 2) | slot
                write(.feature, buf, to: capable ?? primary, tag: "\(name) Intuos5 LED slot=\(index)", bestEffort: capable == nil)
            } else {
                // Intuos4: [0x20, 0x04 | slot, ring, pressed-key, key display
                // brightness, 0…]. Best effort until the interface that
                // declares feature reports registers.
                var buf = [UInt8](repeating: 0, count: 9)
                buf[0] = 0x20
                buf[1] = 0x04 | slot
                buf[2] = Self.intuos4RingLuminance
                buf[3] = Self.intuos4PressedLuminance
                buf[4] = Self.intuos4OLEDBrightness
                write(.feature, buf, to: capable ?? primary, tag: "\(name) Intuos4 LED slot=\(index)", bestEffort: capable == nil)
            }
        case .xencelabs:
            // Every dial mode change reasserts the screen orientation the
            // user set, as the vendor driver does; leaving it out lets the
            // text drift back upright. Then the slot's color, and the dial
            // sensitivity the vendor driver always pairs with it.
            let address = dongleIdentity ?? []
            let steps = lastOrientation >= 0 ? lastOrientation : 0
            sendVendor(XencelabsOutputProtocol.orientationPayload(rotationSteps: steps, address: address),
                       tag: "screen orientation \(steps)")
            let palette = XencelabsOutputProtocol.defaultSlotColors
            let custom = dialSlotColors.indices.contains(index) ? dialSlotColors[index] : nil
            let factory = palette[((index % palette.count) + palette.count) % palette.count]
            let color = custom ?? LEDColor(r: factory.r, g: factory.g, b: factory.b)
            sendVendor(XencelabsOutputProtocol.dialColorPayload(r: color.r, g: color.g, b: color.b, address: address),
                       tag: "dial LED slot=\(index)")
            sendVendor(XencelabsOutputProtocol.dialSensitivityPayload(3, address: address),
                       tag: "dial sensitivity slot=\(index)")
        default:
            break
        }
    }

    // MARK: - Labels

    package func setRingModeLabel(_ label: String) {
        queue.perform { [self] in showModeLabel(label) }
    }

    package func setAuxKeyLabels(_ labels: [String]) {
        queue.perform { [self] in showKeyLabels(labels) }
    }

    /// On the output queue.
    private func showModeLabel(_ label: String) {
        guard spec.format == .xencelabs else { return }
        requestedText["mode"] = label
        guard sentText["mode"] != label else { return }
        sentText["mode"] = label
        for payload in XencelabsOutputProtocol.textPayloads(field: .modeName, text: label, address: dongleIdentity ?? []) {
            sendVendor(payload, tag: "OLED mode label")
        }
    }

    /// On the output queue.
    private func showKeyLabels(_ labels: [String]) {
        if spec.format == .xencelabs {
            let joined = labels.joined(separator: "\u{1F}")
            requestedText["keys"] = joined
            guard sentText["keys"] != joined else { return }
            sentText["keys"] = joined
            for payload in XencelabsOutputProtocol.keyLabelPayloads(labels, address: dongleIdentity ?? []) {
                sendVendor(payload, tag: "OLED key labels")
            }
        } else if spec.hasKeyOLEDs {
            sendKeyDisplays(labels)
        }
    }

    /// Turns the key display images 180° for a tablet used upside down, and
    /// resends what they show.
    public func setKeyOLEDsRotated180(_ rotated: Bool) {
        queue.perform { [self] in
            guard spec.hasKeyOLEDs, rotated != keyOLEDsRotated180 else { return }
            keyOLEDsRotated180 = rotated
            let shown = sentKeyLabels
            sentKeyLabels = []
            sendKeyDisplays(shown)
        }
    }

    /// Renders each changed label to its key's display, USB only. An image
    /// is about 1 KB of feature reports, so unchanged keys are skipped.
    private func sendKeyDisplays(_ labels: [String]) {
        guard let primary else { return }
        for (index, label) in labels.enumerated() where index < 8 {
            let previous = index < sentKeyLabels.count ? sentKeyLabels[index] : nil
            guard previous != label else { continue }
            while sentKeyLabels.count <= index { sentKeyLabels.append("") }
            sentKeyLabels[index] = label
            let bitmap = IntuosOLEDImageEncoder.renderTextLabel(label)
            guard let packed = IntuosOLEDImageEncoder.interleaveRows(bitmap, rotated180: keyOLEDsRotated180)
            else { continue }
            // Best effort: a bad write garbles one key's image and nothing else.
            write(.feature, WacomOutputProtocol.imageStartPayload(), to: primary, tag: "Intuos4 OLED key\(index) start", bestEffort: true)
            for chunk in WacomOutputProtocol.keyImagePayloadsUSB(image: packed, buttonID: index) {
                write(.feature, chunk, to: primary, tag: "Intuos4 OLED key\(index) chunk", bestEffort: true)
            }
            write(.feature, WacomOutputProtocol.imageStopPayload(), to: primary, tag: "Intuos4 OLED key\(index) stop", bestEffort: true)
        }
    }

    // MARK: - Quick Keys

    package func setQuickKeysOrientation(steps: Int) {
        queue.perform { [self] in
            guard spec.format == .xencelabs else { return }
            let clamped = ((steps % 4) + 4) % 4
            guard clamped != lastOrientation else { return }
            lastOrientation = clamped
            sendVendor(XencelabsOutputProtocol.orientationPayload(rotationSteps: clamped, address: dongleIdentity ?? []),
                       tag: "quick keys orientation \(clamped)")
        }
    }

    /// The auto-sleep timer, in minutes; 0 never sleeps. It survives a power cycle.
    package func setQuickKeysSleepMinutes(_ minutes: Int) {
        queue.perform { [self] in
            guard spec.format == .xencelabs else { return }
            let clamped = min(max(minutes, 0), 255)
            guard clamped != lastSleepMinutes else { return }
            lastSleepMinutes = clamped
            sendVendor(XencelabsOutputProtocol.sleepTimerPayload(minutes: UInt8(clamped), address: dongleIdentity ?? []),
                       tag: "quick keys sleep timer \(clamped)m")
        }
    }

    /// The OLED's brightness, 0 (off) through 3.
    package func setQuickKeysOledBrightness(_ level: Int) {
        queue.perform { [self] in
            guard spec.format == .xencelabs else { return }
            let clamped = min(max(level, 0), 3)
            guard clamped != lastOLEDBrightness else { return }
            lastOLEDBrightness = clamped
            sendVendor(XencelabsOutputProtocol.oledBrightnessPayload(UInt8(clamped), address: dongleIdentity ?? []),
                       tag: "quick keys OLED brightness \(clamped)")
        }
    }

    // MARK: - Pen display panel

    package func setDisplayBrightness(_ percent: Int) {
        queue.perform { [self] in
            guard hasDisplayPanel else { return }
            let clamped = min(max(percent, 0), 100)
            guard clamped != lastDisplayBrightness else { return }
            lastDisplayBrightness = clamped
            sendVendor(XencelabsOutputProtocol.displayBrightnessPayload(UInt8(clamped), address: dongleIdentity ?? []),
                       tag: "panel brightness \(clamped)")
        }
    }

    package func setDisplayContrast(_ percent: Int) {
        queue.perform { [self] in
            guard hasDisplayPanel else { return }
            let clamped = min(max(percent, 0), 100)
            guard clamped != lastDisplayContrast else { return }
            lastDisplayContrast = clamped
            sendVendor(XencelabsOutputProtocol.displayContrastPayload(UInt8(clamped), address: dongleIdentity ?? []),
                       tag: "panel contrast \(clamped)")
        }
    }

    /// Gamma as gamma × 10, so 22 is 2.2.
    package func setDisplayGamma(_ gammaTimesTen: Int) {
        queue.perform { [self] in
            guard hasDisplayPanel else { return }
            let clamped = min(max(gammaTimesTen, 0), 255)
            guard clamped != lastDisplayGamma else { return }
            lastDisplayGamma = clamped
            sendVendor(XencelabsOutputProtocol.displayGammaPayload(UInt8(clamped), address: dongleIdentity ?? []),
                       tag: "panel gamma \(clamped)")
        }
    }

    /// A color-space preset by row: 0 Adobe RGB through 6 Custom. On the wire
    /// each preset is one higher than its row; 0 isn't a preset. The commit
    /// frame after it resets any stray gamma or contrast, as the vendor
    /// driver's own preset switch does.
    package func setColorMode(_ index: Int) {
        queue.perform { [self] in
            guard hasDisplayPanel, index != lastColorMode else { return }
            lastColorMode = index
            let address = dongleIdentity ?? []
            sendVendor(XencelabsOutputProtocol.colorModePayload(UInt8(index + 1), address: address),
                       tag: "panel color mode \(index)")
            sendVendor(XencelabsOutputProtocol.displayCommitPayload(address: address), tag: "panel color mode commit")
        }
    }

    /// The light behind the bezel buttons. It has no brightness register, so
    /// brightness comes premultiplied into the color.
    package func setBezelLEDColor(_ color: LEDColor) {
        queue.perform { [self] in
            guard hasDisplayPanel, color != lastBezelLED else { return }
            lastBezelLED = color
            sendVendor(XencelabsOutputProtocol.dialColorPayload(r: color.r, g: color.g, b: color.b, address: dongleIdentity ?? []),
                       tag: "bezel LED")
        }
    }

    // MARK: - Quick Keys relink

    /// Sends the tablet-mode relink handshake for a relayed puck, and starts
    /// the battery poll. `completion` gets the write's result on the queue.
    package func relink(identity: [UInt8], completion: @escaping @Sendable (IOReturn) -> Void) {
        queue.perform { [self] in
            dongleIdentity = identity
            startBatteryPoll()
            guard let target = sibling ?? primary else { return completion(kIOReturnNotOpen) }
            let bytes = padded([0x02, 0xB0, 0x04, 0, 0, 0, 0, 0, 0, 0] + identity, for: target)
            paceVendorWrite()
            let ret = target.setReport(.output, bytes: bytes)
            logger.info("\(self.spec.name, privacy: .public): dongle relink sent, result=0x\(String(ret, radix: 16), privacy: .public)")
            completion(ret)
        }
    }

    /// Puts the LED and labels back once a relink has settled. The status
    /// polls match what the vendor driver sends at this point.
    package func resyncAfterRelink() {
        queue.perform { [self] in
            if let identity = dongleIdentity {
                sendVendor([0x02, 0xB4, 0x08, 0, 0, 0, 0, 0, 0, 0] + identity, tag: "sleep-time poll")
                sendVendor([0x02, 0xB4, 0x10, 0, 0, 0, 0, 0, 0, 0] + identity, tag: "battery poll")
                sendVendor([0x02, 0xB1, 0x0A, 0, 0, 0, 0, 0, 0, 0] + identity, tag: "OLED brightness poll")
            }
            let mode = requestedText["mode"]
            let keys = requestedText["keys"]
            sentText.removeAll()
            logger.info("\(self.spec.name, privacy: .public): display resync, mode label \(mode != nil, privacy: .public), key labels \(keys != nil, privacy: .public)")
            sendRingLED()
            if let mode { showModeLabel(mode) }
            if let keys { showKeyLabels(keys.components(separatedBy: "\u{1F}")) }
        }
    }

    /// Xencelabs re-enumerates shortly after connecting and the new handle
    /// loses what the screen showed: clear the text cache, put the LED back,
    /// and ask a receiver for its pucks now.
    package func reinitializedAfterReenumeration(isRelay: Bool) {
        queue.perform { [self] in
            sentText.removeAll()
            sendRingLED()
            if isRelay { sendVendor([0x02, 0xB8, 0x01], tag: "dongle scan") }
        }
    }

    package func stop() {
        queue.performAndWait { [self] in
            batteryPoll?.cancel()
            batteryPoll = nil
            pendingVendorWrites.removeAll()
            pendingVendorWritesDropped = false
        }
    }

    /// Polls the puck's battery every 60 s; it never reports on its own.
    private func startBatteryPoll() {
        batteryPoll?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue.dispatchQueue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self, let identity = dongleIdentity else { return }
            // Log once per silence: a sleeping puck is silent for hours.
            if let last = lastReportNs {
                let idle = DispatchTime.now().uptimeNanoseconds &- last
                if idle > 120 * NSEC_PER_SEC, idle <= 180 * NSEC_PER_SEC {
                    logger.warning("\(self.spec.name, privacy: .public): no Xencelabs reports for \(idle / NSEC_PER_SEC, privacy: .public)s — possible silent dongle link loss")
                }
            }
            sendVendor([0x02, 0xB4, 0x10, 0, 0, 0, 0, 0, 0, 0] + identity, tag: "battery poll")
        }
        timer.resume()
        batteryPoll = timer
    }

    // MARK: - Writes

    /// A Xencelabs vendor write, padded to the declared output size (the
    /// firmware ignores short ones) and paced. Before the vendor tunnel
    /// exists, it's held rather than sent to an interface that rejects it.
    private func sendVendor(_ bytes: [UInt8], tag: String) {
        guard let primary else { return }
        if spec.format == .xencelabs, sibling == nil, primary.usagePage != 0xFF0A {
            if pendingVendorWrites.count < Self.maxPendingVendorWrites {
                pendingVendorWrites.append((bytes, tag))
            } else if !pendingVendorWritesDropped {
                pendingVendorWritesDropped = true
                logger.info("\(self.spec.name, privacy: .public): vendor tunnel still absent after \(Self.maxPendingVendorWrites, privacy: .public) queued writes — dropping the rest")
            }
            return
        }
        let target = (spec.format == .xencelabs ? sibling : nil) ?? primary
        paceVendorWrite()
        write(.output, padded(bytes, for: target), to: target, tag: "\(spec.name) \(tag)", bestEffort: true)
    }

    private func flushPendingVendorWrites() {
        guard !pendingVendorWrites.isEmpty else { return }
        let queued = pendingVendorWrites
        pendingVendorWrites.removeAll()
        pendingVendorWritesDropped = false
        logger.info("\(self.spec.name, privacy: .public): vendor tunnel registered — replaying \(queued.count, privacy: .public) queued write(s)")
        for write in queued { sendVendor(write.bytes, tag: write.tag) }
    }

    private var lastVendorWriteNs: UInt64 = 0

    /// Xencelabs firmware busy repainting drops a write and still reports
    /// success, so vendor writes go 3 ms apart.
    private func paceVendorWrite() {
        let gap: UInt64 = 3_000_000
        let now = DispatchTime.now().uptimeNanoseconds
        if lastVendorWriteNs != 0, now &- lastVendorWriteNs < gap {
            usleep(UInt32((gap - (now &- lastVendorWriteNs)) / 1_000))
        }
        lastVendorWriteNs = DispatchTime.now().uptimeNanoseconds
    }

    private func write(_ kind: HIDReportKind, _ bytes: [UInt8], to target: any HIDInterface, tag: String, bestEffort: Bool = false) {
        let ret = target.setReport(kind, bytes: bytes)
        guard ret != kIOReturnSuccess else { return }
        let hex = String(format: "0x%08x", ret)
        if bestEffort {
            logger.info("hidSetReport \(tag, privacy: .public): \(hex, privacy: .public)")
        } else {
            logger.error("hidSetReport \(tag, privacy: .public) failed: \(hex, privacy: .public)")
        }
    }

    private func padded(_ bytes: [UInt8], for target: any HIDInterface) -> [UInt8] {
        let size = target.maxOutputReportSize
        return size > bytes.count ? bytes + [UInt8](repeating: 0, count: size - bytes.count) : bytes
    }
}
