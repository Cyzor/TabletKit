// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The ways a tablet departs from plain "open it and read reports".
///
/// Each defaults from the report format; a registry entry overrides a field
/// where one product differs from its family.
public struct TabletQuirks: Sendable, Equatable {
    /// Over USB, needs the standard HID InputMode write before it sends
    /// pen reports.
    public var inputModeWriteOverUSB = false
    /// Needs its init steps over Bluetooth too. Most families must not get
    /// them there: the write suppresses pen data.
    public var initOverBluetooth = false
    /// Init must go to the interface that declares the init feature reports;
    /// others accept the write and ignore it.
    public var initNeedsDeclaringInterface = false
    /// Answers the hardware-serial feature report. One that doesn't stalls
    /// the read for seconds.
    public var answersSerialQuery = true
    /// Re-enumerates shortly after connecting, so init has to be sent again
    /// to the new interface.
    public var reinitOnReenumeration = false
    /// A touch sensor enumerating as its own device must be seized, or macOS
    /// also treats it as a touchscreen.
    public var seizesTouchSensor = false
    /// Over USB, a report that means "not switched on yet" when it repeats.
    public var usbIdleReport: IdleReportRule?
    /// Over USB, a mode switch that can be ignored without an error, so it's
    /// read back and resent until it takes.
    public var usbModeReadBack: ModeReadBack?
    /// Over Bluetooth, reports to wait for the pen's identity before
    /// assuming a generic pen.
    public var toolAnnounceGraceFrames: Int?
    /// Pen reports its descriptor declares are read from the descriptor,
    /// ahead of the family decoder.
    package var readsDescriptorPens = false

    public init() {}

    /// A report that, repeated for `timeout` with none of `liveReportIDs`,
    /// means init didn't take.
    public struct IdleReportRule: Sendable, Equatable {
        public var reportID: UInt8
        public var liveReportIDs: Set<UInt8>
        public var timeout: TimeInterval

        public init(reportID: UInt8, liveReportIDs: Set<UInt8>, timeout: TimeInterval) {
            self.reportID = reportID
            self.liveReportIDs = liveReportIDs
            self.timeout = timeout
        }
    }

    /// A feature report that switches the tablet's mode and reads back as
    /// `[id, mode, …]`.
    public struct ModeReadBack: Sendable, Equatable {
        /// The switch, `[id, mode]`.
        public var report: [UInt8]
        /// When to resend if the read-back doesn't match, in seconds after
        /// the first send.
        public var resendAfter: [TimeInterval]

        public init(report: [UInt8], resendAfter: [TimeInterval]) {
            self.report = report
            self.resendAfter = resendAfter
        }

        /// Whether a read-back shows the mode took.
        public func matches(_ reply: [UInt8]) -> Bool {
            report.count >= 2 && reply.count >= 2 && reply[0] == report[0] && reply[1] == report[1]
        }
    }

    /// The family's defaults.
    public static func defaults(for format: ReportFormat) -> TabletQuirks {
        var q = TabletQuirks()
        switch format {
        case .intuosV2:
            q.inputModeWriteOverUSB = true
        case .intuosV3:
            q.initOverBluetooth = true
            q.initNeedsDeclaringInterface = true
            // PTK-x70 and Movink sit on report 0x06 until DATAMODE lands.
            q.usbIdleReport = IdleReportRule(reportID: 0x06, liveReportIDs: [0x1E, 0x1B], timeout: 5)
            q.toolAnnounceGraceFrames = 4
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
        default:
            break
        }
        return q
    }
}

extension TabletSpec {
    /// A copy of this entry with `quirks` in place of its family defaults.
    public func with(quirks: TabletQuirks) -> TabletSpec {
        var copy = self
        copy.quirks = quirks
        return copy
    }

    /// A copy with one quirk changed from the family default.
    public func withQuirks(_ change: (inout TabletQuirks) -> Void) -> TabletSpec {
        var q = quirks
        change(&q)
        return with(quirks: q)
    }
}
