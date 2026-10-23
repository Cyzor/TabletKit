// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import IOKit

/// A session's worth of HID traffic, in order, for ``ReplayBackend``.
package struct ReplayRecording: Sendable {
    package struct Interface: Sendable {
        package var vendorID = 0
        package var productID = 0
        package var usagePage = 0
        package var usage = 0
        package var usagePairs: [HIDUsagePair] = []
        package var transport = ""
        package var productName: String?
        package var serialNumber: String?
        package var locationID = 0
        package var maxInputReportSize = 0
        package var maxOutputReportSize = 0
        package var reportDescriptor: [UInt8] = []
        /// Replies to feature-report reads by report ID, given out in order.
        package var featureReplies: [UInt8: [Reply]] = [:]
        /// Answers to USB string descriptor reads, header included, by index.
        package var strings: [UInt8: [UInt8]] = [:]

        package init() {}
    }

    package struct Reply: Sendable, Equatable {
        package var result: IOReturn
        package var bytes: [UInt8]
    }

    package enum Event: Sendable {
        case attach(Int)
        case detach(Int)
        /// A report on an interface, when it arrived in nanoseconds, and the
        /// events MockTab decoded from it, where the recording kept them.
        case report(interface: Int, bytes: [UInt8], ns: UInt64, decoded: [String]?)
    }

    package var interfaces: [Interface]
    package var events: [Event]

    package init(interfaces: [Interface], events: [Event]) {
        self.interfaces = interfaces
        self.events = events
    }
}

// MARK: - Report traces

extension ReplayRecording {
    /// Reads a report trace, one JSON object per line. Connect-time reads
    /// attach to the interfaces on the usage page they were read from.
    package init(trace: String) throws {
        var interfaces: [Interface] = []
        var index: [Int: Int] = [:]
        var events: [Event] = []
        var reads: [(usagePage: Int, reportID: UInt8, reply: Reply)] = []
        for line in trace.split(separator: "\n") where !line.isEmpty {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let kind = object["kind"] as? String
            else { throw ReplayError.malformed(String(line.prefix(80))) }
            let iface = object["iface"] as? Int
            switch kind {
            case "attach":
                guard let iface else { throw ReplayError.malformed(String(line.prefix(80))) }
                var i = Interface()
                i.vendorID = object["vendorID"] as? Int ?? 0
                i.productID = object["productID"] as? Int ?? 0
                i.usagePage = object["usagePage"] as? Int ?? 0
                i.usage = object["usage"] as? Int ?? 0
                i.usagePairs = (object["usagePairs"] as? [[Int]] ?? []).compactMap {
                    $0.count == 2 ? HIDUsagePair(page: $0[0], usage: $0[1]) : nil
                }
                i.transport = object["transport"] as? String ?? ""
                i.productName = (object["product"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                i.serialNumber = (object["serial"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                i.locationID = object["locationID"] as? Int ?? 0
                i.maxInputReportSize = object["maxInput"] as? Int ?? 0
                i.maxOutputReportSize = object["maxOutput"] as? Int ?? 0
                i.reportDescriptor = bytes(object["descriptor"] as? String ?? "")
                index[iface] = interfaces.count
                events.append(.attach(interfaces.count))
                interfaces.append(i)
            case "detach":
                if let iface, let at = index[iface] { events.append(.detach(at)) }
            case "report":
                guard let iface, let at = index[iface] else { continue }
                events.append(.report(
                    interface: at, bytes: bytes(object["bytes"] as? String ?? ""),
                    ns: (object["ns"] as? NSNumber)?.uint64Value ?? 0,
                    decoded: object["events"] as? [String]))
            case "initRead":
                guard let id = object["reportID"] as? Int else { continue }
                reads.append((
                    object["usagePage"] as? Int ?? 0, UInt8(truncatingIfNeeded: id),
                    Reply(result: IOReturn(truncatingIfNeeded: object["ioReturn"] as? Int ?? 0),
                          bytes: bytes(object["reply"] as? String ?? ""))))
            default:
                continue
            }
        }
        for read in reads {
            for i in interfaces.indices where interfaces[i].usagePage == read.usagePage {
                interfaces[i].featureReplies[read.reportID, default: []].append(read.reply)
            }
        }
        self.init(interfaces: interfaces, events: events)
    }
}

// MARK: - MockTab captures

extension ReplayRecording {
    /// Reads a MockTab capture: `summary.json` for the interfaces and their
    /// setup replies, and optionally `full-log.txt` for reports.
    ///
    /// The log collapses steady runs into value ranges, so only its verbatim
    /// lines replay: transitions, tool changes, and buttons. Every interface
    /// attaches before the first report.
    package init(captureSummary: Data, log: String? = nil) throws {
        guard let summary = try JSONSerialization.jsonObject(with: captureSummary) as? [String: Any] else {
            throw ReplayError.malformed("summary.json")
        }
        let device = summary["deviceInfo"] as? [String: Any] ?? [:]
        let vendorID = hexInt(device["vendorID"]) ?? 0
        let transport = device["transport"] as? String ?? ""
        // A single-interface capture keeps its interface at the top level.
        var single: [String: Any] = [:]
        single["productID"] = device["productID"]
        single["reports"] = summary["reports"]
        single["hidReportDescriptor"] = summary["hidReportDescriptor"]
        let listed = (summary["interfaces"] as? [[String: Any]]) ?? [single]
        var interfaces: [Interface] = []
        var reportIDs: [Set<UInt8>] = []
        for entry in listed {
            var i = Interface()
            i.vendorID = vendorID
            i.productID = hexInt(entry["productID"]) ?? hexInt(device["productID"]) ?? 0
            i.usagePage = hexInt(entry["usagePage"]) ?? 0
            i.usage = hexInt(entry["usage"]) ?? 0
            i.transport = transport
            i.productName = entry["deviceName"] as? String ?? device["name"] as? String
            let descriptor = entry["hidReportDescriptor"] as? [String: Any]
            i.reportDescriptor = bytes(descriptor?["rawHex"] as? String ?? "")
            // Captures don't record usage pairs, so they come from the descriptor.
            i.usagePairs = collectionUsages(i.reportDescriptor)
            interfaces.append(i)
            reportIDs.append(Set(((entry["reports"] as? [String: Any]) ?? [:]).keys.compactMap {
                hexInt($0).map { UInt8(truncatingIfNeeded: $0) }
            }))
        }
        for read in summary["initReads"] as? [[String: Any]] ?? [] {
            guard let id = read["reportID"] as? Int else { continue }
            let page = hexInt(read["interfaceUsagePage"]) ?? 0
            let reply = Reply(
                result: IOReturn(truncatingIfNeeded: hexInt(read["ioReturn"]) ?? 0),
                bytes: bytes(read["reply"] as? String ?? ""))
            for i in interfaces.indices where interfaces[i].usagePage == page {
                interfaces[i].featureReplies[UInt8(truncatingIfNeeded: id), default: []].append(reply)
            }
        }
        var events: [Event] = interfaces.indices.map { .attach($0) }
        for line in (log ?? "").split(separator: "\n") {
            guard let report = Self.verbatimReport(String(line)) else { continue }
            let at = reportIDs.firstIndex { $0.contains(report.id) } ?? 0
            events.append(.report(interface: at, bytes: report.bytes, ns: report.ns, decoded: nil))
        }
        self.init(interfaces: interfaces, events: events)
    }

    /// `[mm:ss.mmm] <tag> ID=XX len=N  <hex bytes>  → …`, skipping run lines.
    private static func verbatimReport(_ line: String) -> (id: UInt8, bytes: [UInt8], ns: UInt64)? {
        guard line.hasPrefix("["), !line.contains("steady-state"),
            let close = line.firstIndex(of: "]"),
            let lenRange = line.range(of: #"len=\d+\s+"#, options: .regularExpression)
        else { return nil }
        let stamp = line[line.index(after: line.startIndex)..<close].split(separator: ":")
        guard stamp.count == 2, let minutes = Double(stamp[0]), let seconds = Double(stamp[1]) else { return nil }
        var rest = line[lenRange.upperBound...]
        if let arrow = rest.range(of: "→") { rest = rest[..<arrow.lowerBound] }
        let parsed = rest.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        guard let id = parsed.first else { return nil }
        return (id, parsed, UInt64((minutes * 60 + seconds) * 1_000_000_000))
    }
}

package enum ReplayError: Error, Equatable {
    case malformed(String)
}

private func bytes(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
        if let byte = UInt8(hex[index..<next], radix: 16) { out.append(byte) }
        index = next
    }
    return out
}

/// The usages of a report descriptor's application and physical
/// collections, close to what IOKit lists as an interface's usage pairs.
func collectionUsages(_ descriptor: [UInt8]) -> [HIDUsagePair] {
    var pairs: [HIDUsagePair] = []
    var page = 0
    var usage: Int?
    var usageHasPage = false
    var i = 0
    while i < descriptor.count {
        let prefix = descriptor[i]
        if prefix == 0xFE {  // long item
            guard i + 1 < descriptor.count else { break }
            i += 3 + Int(descriptor[i + 1])
            continue
        }
        let size = [0, 1, 2, 4][Int(prefix & 0x03)]
        guard i + size < descriptor.count else { break }
        var value = 0
        for b in 0..<size { value |= Int(descriptor[i + 1 + b]) << (8 * b) }
        switch prefix & 0xFC {
        case 0x04: page = value
        case 0x08:
            if usage == nil {
                usage = value
                usageHasPage = size == 4
            }
        case 0xA0:
            // Logical collections (type 2) group fields; IOKit doesn't list them.
            if let u = usage, value != 2 {
                let pair = usageHasPage
                    ? HIDUsagePair(page: u >> 16, usage: u & 0xFFFF) : HIDUsagePair(page: page, usage: u)
                if !pairs.contains(pair) { pairs.append(pair) }
            }
        default: break
        }
        // Local items last until the next main item.
        if prefix & 0x0C == 0x00 { usage = nil }
        i += 1 + size
    }
    return pairs
}

/// An integer from a JSON number or a hex string such as "0x056A".
private func hexInt(_ value: Any?) -> Int? {
    if let n = value as? Int { return n }
    guard let s = value as? String else { return nil }
    return s.hasPrefix("0x") || s.hasPrefix("0X") ? Int(s.dropFirst(2), radix: 16) : Int(s)
}
