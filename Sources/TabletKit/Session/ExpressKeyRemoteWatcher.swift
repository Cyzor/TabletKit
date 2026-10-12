// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

/// Tracks the ExpressKey Remotes a receiver relays: which are paired, and
/// which have been heard from.
///
/// Counterpart of ``XencelabsRelayWatcher``. The EKR receiver needs nothing
/// from the host, so this only reports. It goes by what the receiver states:
/// a remote is online once one of its event reports (0x11) arrives, and
/// offline when its serial leaves the pairing table (0x10). Silence means
/// nothing, since a remote sleeps when idle and wakes on a key press. A
/// remote that is paired but never heard from is in ``silentRemotes``.
public struct ExpressKeyRemoteWatcher: Sendable {
    public struct Change: Sendable, Equatable {
        public var serial: UInt32
        public var link: RemoteLinkChange
    }

    /// Serials in the receiver's latest pairing table.
    public private(set) var paired: Set<UInt32> = []
    /// Serials that have sent an event since they were paired.
    public private(set) var heard: Set<UInt32> = []

    public init() {}

    /// Paired remotes that haven't sent anything yet.
    public var silentRemotes: [UInt32] { paired.subtracting(heard).sorted() }

    public mutating func observe(_ report: HIDReport) -> [Change] {
        guard report.count > 0 else { return [] }
        switch report.reportID {
        case ExpressKeyRemoteDecoder.remoteReportID where report.count >= 6:
            // Bytes 3–5: the sending remote's serial, little-endian.
            let serial = UInt32(report[3]) | UInt32(report[4]) << 8 | UInt32(report[5]) << 16
            guard serial != 0, heard.insert(serial).inserted else { return [] }
            return [Change(serial: serial, link: .online)]
        case ExpressKeyRemoteDecoder.deviceListReportID:
            guard case .remotePairing(let slots)? =
                ExpressKeyRemoteDecoder.decodePairingTable(report: report).first
            else { return [] }
            let now = Set(slots.filter(\.connected).map(\.serial))
            let gone = paired.subtracting(now)
            paired = now
            heard.subtract(gone)
            return gone.sorted().map { Change(serial: $0, link: .offline) }
        default:
            return []
        }
    }
}
