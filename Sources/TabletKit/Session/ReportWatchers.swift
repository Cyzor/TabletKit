// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

// Report watchers: small state machines that read a tablet's reports and say
// what the driver should do. They never touch the device, so they're safe on
// the input thread and testable by replaying reports. Times are seconds on
// any monotonic clock.

/// Notices a tablet stuck in its idle report after init, and asks for init
/// again. See ``TabletQuirks/usbIdleReport``.
public struct IdleReportWatcher: Sendable {
    public let rule: TabletQuirks.IdleReportRule
    private var idleSince: TimeInterval?
    private var lastAttempt = -TimeInterval.infinity

    public init(rule: TabletQuirks.IdleReportRule) { self.rule = rule }

    /// True when init should be sent again. Repeats at most once per timeout.
    public mutating func observe(_ report: HIDReport, now: TimeInterval) -> Bool {
        guard report.count > 0 else { return false }
        let id = report.reportID
        if id == rule.reportID {
            let since = idleSince ?? now
            if idleSince == nil { idleSince = now }
            if now - since > rule.timeout, now - lastAttempt > rule.timeout {
                lastAttempt = now
                return true
            }
        } else if rule.liveReportIDs.contains(id) {
            idleSince = nil
        }
        return false
    }
}

/// Reads the paired tablet's product ID from a Wacom wireless receiver's
/// status report (0x80). The receiver names it while the tablet sleeps too,
/// so a tablet asleep at launch still finds its window.
public struct DonglePairingWatcher: Sendable {
    public private(set) var announcedProductID: Int?

    public init() {}

    /// The paired product ID when it first appears or changes.
    public mutating func observe(_ report: HIDReport) -> Int? {
        guard report.count >= 8, report[0] == 0x80 else { return nil }
        let pid = Int(report[6]) << 8 | Int(report[7])  // big-endian
        guard pid > 0, pid != announcedProductID else { return nil }
        announcedProductID = pid
        return pid
    }
}

/// Reads the paired tablet's battery from a Wacom wireless receiver's status
/// report (0x80). Byte 5 holds the level out of 31 in its low five bits, and
/// bit 7 is set while the battery charges.
///
/// On battery, the level flickers between neighboring steps from one report
/// to the next, so a new level counts only once it holds for
/// `holdReports` reports. The first reading and a change in charging show at
/// once.
///
/// The level also drifts with load over minutes, rising as the battery rests.
/// Once the gauge settles after a link, a level on battery only falls.
public struct DongleBatteryWatcher: Sendable {
    /// Reports a new level must hold, about two seconds at the receiver's
    /// half-second status rate.
    public static let holdReports = 4
    /// Reports after a link during which the level may still rise, about a
    /// minute.
    public static let settleReports = 120

    public private(set) var lastReading: DeviceEvent.Battery?
    private var pending: DeviceEvent.Battery?
    private var pendingCount = 0
    private var linkedReports = 0

    public init() {}

    /// The battery when it first appears or changes while a tablet is linked.
    public mutating func observe(_ report: HIDReport) -> DeviceEvent.Battery? {
        guard report.count >= 6, report[0] == 0x80 else { return nil }
        guard report[1] & 0x01 != 0 else {
            // Announce again on relink, even at the same level.
            lastReading = nil
            pending = nil
            linkedReports = 0
            return nil
        }
        linkedReports += 1
        let level = Int(report[5] & 0x1F)
        let reading = DeviceEvent.Battery(
            percent: level * 100 / 31, charging: report[5] & 0x80 != 0)
        guard reading != lastReading else {
            pending = nil
            return nil
        }
        if let last = lastReading, last.charging == reading.charging {
            if !reading.charging, reading.percent > last.percent, linkedReports > Self.settleReports {
                pending = nil
                return nil
            }
            if reading == pending {
                pendingCount += 1
            } else {
                pending = reading
                pendingCount = 1
            }
            guard pendingCount >= Self.holdReports else { return nil }
        }
        pending = nil
        lastReading = reading
        return reading
    }
}

/// Over Bluetooth, gives a pen's identity announcement a few reports to
/// arrive before the driver assumes a generic pen.
/// See ``TabletQuirks/toolAnnounceGraceFrames``.
public struct ToolAnnouncementGrace: Sendable {
    public let frames: Int
    private var framesInRange = 0

    public init(frames: Int) { self.frames = frames }

    /// Call once per report with whether the pen was in range before it.
    /// True on the one report where the grace runs out.
    public mutating func advance(penInRange: Bool) -> Bool {
        framesInRange = penInRange ? min(framesInRange + 1, frames + 1) : 0
        return frames > 0 && framesInRange == frames
    }
}
