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
package struct IdleReportWatcher: Sendable {
    package let rule: TabletQuirks.IdleReportRule
    private var idleSince: TimeInterval?
    private var lastAttempt = -TimeInterval.infinity

    package init(rule: TabletQuirks.IdleReportRule) { self.rule = rule }

    /// True when init should be sent again. Repeats at most once per timeout.
    package mutating func observe(_ report: HIDReport, now: TimeInterval) -> Bool {
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

/// Notices an IntuosV2 USB pen that the tablet keeps sensing without
/// identifying it: report 0x10 with status 0x40 (Sense) and not 0x20
/// (InRange). Such reports carry position only. A pen normally gets
/// identified within a few reports; a CTL-6100 has kept this up for over a
/// minute, tip and buttons dead, until the pen left range. Asks for a pen
/// scan restart after `after` seconds of it, and once more `retryAfter`
/// later if it persists: the same reports can come from a pen hovering a
/// little high, which each restart pauses. See
/// ``TabletQuirks/usbPenScanSwitch``.
package struct SenseOnlyWatcher: Sendable {
    package static let after: TimeInterval = 1.0
    package static let retryAfter: TimeInterval = 3.0
    package static let attempts = 2
    /// Reports further apart than this end a stretch: the pen has left.
    package static let maxGap: TimeInterval = 0.1
    /// A restart silences the tablet for a moment (a PTK-870 took 0.66 s to
    /// report a hovering pen after scanning came back on), so a gap this
    /// soon after one doesn't start a fresh stretch.
    package static let restartQuiet: TimeInterval = 2.0

    private var since: TimeInterval?
    private var last = -TimeInterval.infinity
    private var made = 0
    private var lastRestart = -TimeInterval.infinity

    package init() {}

    /// True when the pen scan should restart.
    package mutating func observe(_ report: HIDReport, now: TimeInterval) -> Bool {
        guard report.count >= 2, report[0] == 0x10 else { return false }
        // Only an identified pen ends a stretch. The exit frame a restart
        // provokes (status 0x00) neither ends nor extends it.
        if report[1] & 0x20 != 0 {
            since = nil
            return false
        }
        guard report[1] & 0x40 != 0 else { return false }
        defer { last = now }
        let afterRestart = now - lastRestart < Self.restartQuiet + Self.maxGap
        if since == nil || (now - last > Self.maxGap && !afterRestart) {
            since = now
            made = 0
        }
        guard let since, made < Self.attempts,
            now - (made == 0 ? since : lastRestart) >= (made == 0 ? Self.after : Self.retryAfter)
        else { return false }
        made += 1
        lastRestart = now
        return true
    }
}

/// Reads the paired tablet's product ID from a Wacom wireless receiver's
/// status report (0x80). The receiver names it while the tablet sleeps too,
/// so a tablet asleep at launch still finds its window.
package struct DonglePairingWatcher: Sendable {
    package private(set) var announcedProductID: Int?

    package init() {}

    /// The paired product ID when it first appears or changes.
    package mutating func observe(_ report: HIDReport) -> Int? {
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
/// The level flickers between neighboring steps from one report to the next,
/// and reads low for a few seconds after a link, so a level counts only once
/// it holds for `holdReports` reports. A change in charging shows at once.
///
/// The level also rises as the battery rests after load. Without charging,
/// capacity only falls, so once shown, a level on battery only falls.
package struct DongleBatteryWatcher: Sendable {
    /// Reports a new level must hold, about two seconds at the receiver's
    /// half-second status rate.
    package static let holdReports = 4

    package private(set) var lastReading: DeviceEvent.Battery?
    private var pending: DeviceEvent.Battery?
    private var pendingCount = 0

    package init() {}

    /// The battery when it first appears or changes while a tablet is linked.
    package mutating func observe(_ report: HIDReport) -> DeviceEvent.Battery? {
        guard report.count >= 6, report[0] == 0x80 else { return nil }
        guard report[1] & 0x01 != 0 else {
            // Announce again on relink, even at the same level.
            lastReading = nil
            pending = nil
            return nil
        }
        let level = Int(report[5] & 0x1F)
        let reading = DeviceEvent.Battery(
            percent: level * 100 / 31, charging: report[5] & 0x80 != 0)
        guard reading != lastReading else {
            pending = nil
            return nil
        }
        if lastReading == nil || lastReading?.charging == reading.charging {
            if let last = lastReading, !reading.charging, reading.percent > last.percent {
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
