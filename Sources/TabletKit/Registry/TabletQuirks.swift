// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The ways a tablet departs from plain "open it and read reports".
///
/// Each defaults from the report format; a registry entry overrides a field
/// where one product differs from its family.
package struct TabletQuirks: Sendable, Equatable {
    /// Over USB, needs the standard HID InputMode write before it sends
    /// pen reports.
    package var inputModeWriteOverUSB = false
    /// Needs its init steps over Bluetooth too. Most families must not get
    /// them there: the write suppresses pen data.
    package var initOverBluetooth = false
    /// Init must go to the interface that declares the init feature reports;
    /// others accept the write and ignore it.
    package var initNeedsDeclaringInterface = false
    /// Answers the hardware-serial feature report. One that doesn't stalls
    /// the read for seconds.
    package var answersSerialQuery = true
    /// Re-enumerates shortly after connecting, so init has to be sent again
    /// to the new interface.
    package var reinitOnReenumeration = false
    /// A touch sensor enumerating as its own device must be seized, or macOS
    /// also treats it as a touchscreen.
    package var seizesTouchSensor = false
    /// Over USB, a report that means "not switched on yet" when it repeats.
    package var usbIdleReport: IdleReportRule?
    /// Over USB, a mode switch that can be ignored without an error, so it's
    /// read back and resent until it takes.
    package var usbModeReadBack: ModeReadBack?
    /// Pen reports its descriptor declares are read from the descriptor,
    /// ahead of the family decoder.
    package var readsDescriptorPens = false

    package init() {}

    /// A report that, repeated for `timeout` with none of `liveReportIDs`,
    /// means init didn't take.
    package struct IdleReportRule: Sendable, Equatable {
        package var reportID: UInt8
        package var liveReportIDs: Set<UInt8>
        package var timeout: TimeInterval

        package init(reportID: UInt8, liveReportIDs: Set<UInt8>, timeout: TimeInterval) {
            self.reportID = reportID
            self.liveReportIDs = liveReportIDs
            self.timeout = timeout
        }
    }

    /// A feature report that switches the tablet's mode and reads back as
    /// `[id, mode, …]`.
    package struct ModeReadBack: Sendable, Equatable {
        /// The switch, `[id, mode]`.
        package var report: [UInt8]
        /// When to resend if the read-back doesn't match, in seconds after
        /// the first send.
        package var resendAfter: [TimeInterval]

        package init(report: [UInt8], resendAfter: [TimeInterval]) {
            self.report = report
            self.resendAfter = resendAfter
        }

        /// Whether a read-back shows the mode took.
        package func matches(_ reply: [UInt8]) -> Bool {
            report.count >= 2 && reply.count >= 2 && reply[0] == report[0] && reply[1] == report[1]
        }
    }

    /// The family's defaults.
    package static func defaults(for format: ReportFormat) -> TabletQuirks {
        var q = TabletQuirks()
        switch format {
        case .intuosV2:
            q.inputModeWriteOverUSB = true
        case .intuosV3:
            q.initOverBluetooth = true
            q.initNeedsDeclaringInterface = true
            // PTK-x70 and Movink sit on report 0x06 until DATAMODE lands.
            q.usbIdleReport = IdleReportRule(reportID: 0x06, liveReportIDs: [0x1E, 0x1B], timeout: 5)
        case .intuosV1, .bamboo:
            q.initNeedsDeclaringInterface = true
        case .xencelabs:
            q.answersSerialQuery = false
            q.reinitOnReenumeration = true
        case .ucLogic:
            q.answersSerialQuery = false
        case .cintiqV1:
            q.seizesTouchSensor = true
        case .descriptor:
            q.readsDescriptorPens = true
        case .graphire:
            // Mouse-mode reports (0x01) mean the tablet left Wacom mode; switch it back.
            q.usbIdleReport = IdleReportRule(reportID: 0x01, liveReportIDs: [0x02], timeout: 0.25)
        default:
            break
        }
        return q
    }
}

extension TabletSpec {
    /// The write that puts the tablet back in mouse mode when the driver
    /// closes it, so the pen still moves the cursor after quit. Only for
    /// tablets switched on by `[0x02, 0x02]`; PTK-x70 and Movink keep their
    /// mode, since nothing shows what they expect.
    package var mouseModeRestore: [UInt8]? {
        guard format != .intuosV3, initSteps.contains(.featureReport([0x02, 0x02])) else { return nil }
        return [0x02, 0x01]
    }

    /// A copy of this entry with `quirks` in place of its family defaults.
    package func with(quirks: TabletQuirks) -> TabletSpec {
        var copy = self
        copy.quirks = quirks
        return copy
    }

    /// A copy with one quirk changed from the family default.
    package func withQuirks(_ change: (inout TabletQuirks) -> Void) -> TabletSpec {
        var q = quirks
        change(&q)
        return with(quirks: q)
    }
}
