// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Errors thrown while walking a raw HID report descriptor byte stream.
public enum HIDReportDescriptorParserError: Error, Equatable, Sendable {
    case truncatedItem(offset: Int)
    case oddHexString
    case invalidHexDigit(Character)
    case unbalancedPop(offset: Int)
}

/// A single field (variable item, or one slot of an array item) within one report.
public struct DescriptorField: Equatable, Sendable {
    /// Combined `(usagePage << 16) | usage`. Normalizes both the extended (4-byte)
    /// usage-item encoding and the `Usage Page` + 2-byte `Usage` encoding to the same value.
    public var usagePage: UInt32
    public var usage: UInt32
    /// Bit offset within the report payload, *excluding* the report ID byte (if any).
    public var bitOffset: Int
    public var bitSize: Int
    public var logicalMin: Int
    public var logicalMax: Int
    public var physicalMin: Int
    public var physicalMax: Int
    public var unit: UInt32
    public var unitExponent: Int
    public var isConstant: Bool
    public var isVariable: Bool
    public var isRelative: Bool
    /// Usage path of enclosing collections, outermost first.
    public var collectionPath: [UInt32]

    public var isSigned: Bool { logicalMin < 0 }

    /// Combined usage value for lookup: `(usagePage << 16) | usage`.
    public var extendedUsage: UInt32 { (usagePage << 16) | usage }
}

public enum HIDReportDirection: Equatable, Sendable {
    case input
    case output
    case feature
}

public struct DescriptorReport: Equatable, Sendable {
    public var reportID: UInt8
    public var direction: HIDReportDirection
    public var fields: [DescriptorField]
    public var totalBits: Int
}

public struct DescriptorLayout: Equatable, Sendable {
    public var reports: [DescriptorReport]

    public func report(_ direction: HIDReportDirection, id: UInt8) -> DescriptorReport? {
        reports.first { $0.direction == direction && $0.reportID == id }
    }

    public func fields(matching usagePage: UInt32, usage: UInt32) -> [(DescriptorReport, DescriptorField)] {
        let target = (usagePage << 16) | usage
        var result: [(DescriptorReport, DescriptorField)] = []
        for report in reports {
            for field in report.fields where field.extendedUsage == target {
                result.append((report, field))
            }
        }
        return result
    }

    /// Locates the feature report whose usage matches `extendedUsage` (e.g. `0xff0d1002`
    /// for `WACOM_HID_WD_DATAMODE`), returning its report ID. `nil` if no feature report
    /// declares that usage — which is the case for every classic-Wacom / Xencelabs
    /// descriptor seen to date (they carry usage `0x00` or a vendor page instead).
    public func featureReportID(carryingUsage extendedUsage: UInt32) -> UInt8? {
        for report in reports where report.direction == .feature {
            if report.fields.contains(where: { $0.extendedUsage == extendedUsage }) {
                return report.reportID
            }
        }
        return nil
    }

    /// Feature-report usages that select a device's full reporting mode, most
    /// specific first.
    ///
    /// Wacom's vendor control leads deliberately. On a device declaring both,
    /// it is the pen-oriented one, whereas the standard Device Mode control is
    /// shared with multitouch — writing to that first on a hybrid interface
    /// would change more than intended.
    ///
    /// Both take value 2, which is why `modeSwitchFeatureReportID()` returns
    /// only an ID and callers write a fixed payload.
    public static let modeSwitchUsages: [UInt32] = [
        0xFF0D_1002,  // WACOM_HID_WD_DATAMODE (vendor)
        0x000D_0052,  // Digitizer / Device Mode (standard)
    ]

    /// Report ID of the first mode-switch control this descriptor declares, or
    /// `nil` when it declares none.
    ///
    /// Modern devices boot emitting a reduced report stream until the host
    /// writes this, and the report ID carrying it is per-device — so guessing
    /// a fixed ID works only by coincidence. `nil` is the normal answer for
    /// classic Wacom and Xencelabs hardware, whose descriptors declare neither
    /// usage; those need whatever legacy write the caller used before.
    public func modeSwitchFeatureReportID() -> UInt8? {
        for usage in Self.modeSwitchUsages {
            if let reportID = featureReportID(carryingUsage: usage) { return reportID }
        }
        return nil
    }
}

/// Walks a raw HID report descriptor byte stream, computing per-field bit offsets.
///
/// IOKit's parsed element list (see `LiveHIDDescriptorInspector`) gives usage/size/range per
/// field but never bit offsets — "IOKit doesn't expose a stable per-report ordering."
/// This walker reconstructs offsets directly from the descriptor bytes, which is the
/// one thing IOKit withholds and the one thing a usage-mapped decoder needs.
public enum HIDReportDescriptorParser: Sendable {

    public static func parse(hex: String) throws -> DescriptorLayout {
        try parse(try bytes(fromHex: hex))
    }

    public static func parse(_ bytes: [UInt8]) throws -> DescriptorLayout {
        var walker = Walker(bytes: bytes)
        try walker.run()
        return walker.makeLayout()
    }

    private static func bytes(fromHex hex: String) throws -> [UInt8] {
        guard hex.count % 2 == 0 else { throw HIDReportDescriptorParserError.oddHexString }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var iterator = hex.makeIterator()
        while let high = iterator.next() {
            guard let low = iterator.next() else { throw HIDReportDescriptorParserError.oddHexString }
            guard let hv = high.hexDigitValue, let lv = low.hexDigitValue else {
                throw HIDReportDescriptorParserError.invalidHexDigit(high.hexDigitValue == nil ? high : low)
            }
            result.append(UInt8(hv << 4 | lv))
        }
        return result
    }
}

/// Extracts the integer value of a field from a raw report payload (LSB-first bit
/// packing, per the HID spec), sign-extending if the field's logical range is signed.
///
/// `payload` must have the report ID byte (if any) already stripped — `field.bitOffset`
/// is relative to the first byte *after* the ID, per `DescriptorField.bitOffset`'s doc.
public func extractField(_ field: DescriptorField, from payload: [UInt8]) -> Int {
    var raw: UInt64 = 0
    for bit in 0..<field.bitSize {
        let absoluteBit = field.bitOffset + bit
        let byteIndex = absoluteBit / 8
        guard byteIndex < payload.count else { break }
        let bitIndex = absoluteBit % 8
        if (payload[byteIndex] >> bitIndex) & 1 == 1 {
            raw |= (UInt64(1) << bit)
        }
    }
    if field.isSigned && field.bitSize < 64 && field.bitSize > 0 {
        let signBit = UInt64(1) << (field.bitSize - 1)
        if raw & signBit != 0 {
            let extended = raw | (~UInt64(0) << field.bitSize)
            return Int(bitPattern: UInt(truncatingIfNeeded: extended))
        }
    }
    return Int(raw)
}

// MARK: - Walker

private struct Walker {
    let bytes: [UInt8]
    var offset = 0

    // Global state (persists across main items; push/pop restores a full snapshot).
    struct Globals {
        var usagePage: UInt32 = 0
        var logicalMin: Int = 0
        var logicalMax: Int = 0
        var physicalMin: Int = 0
        var physicalMax: Int = 0
        var unit: UInt32 = 0
        var unitExponent: Int = 0
        var reportSize: Int = 0
        var reportCount: Int = 0
        var reportID: UInt8 = 0
        var hasReportID = false
    }

    var globals = Globals()
    var globalStack: [Globals] = []

    // Local state (resets on every main item).
    var usageQueue: [UInt32] = []
    var lastUsage: UInt32?
    var usageMinPending: UInt32?

    var collectionPath: [UInt32] = []

    // Per (direction, reportID) bit cursor and accumulated fields.
    private struct ReportKey: Hashable { var direction: HIDReportDirection; var reportID: UInt8 }
    private var cursors: [ReportKey: Int] = [:]
    private var fieldsByReport: [ReportKey: [DescriptorField]] = [:]
    private var reportOrder: [ReportKey] = []

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func run() throws {
        while offset < bytes.count {
            try step()
        }
    }

    mutating func makeLayout() -> DescriptorLayout {
        var reports: [DescriptorReport] = []
        for key in reportOrder {
            let fields = fieldsByReport[key] ?? []
            let totalBits = cursors[key] ?? 0
            reports.append(DescriptorReport(reportID: key.reportID, direction: key.direction,
                                             fields: fields, totalBits: totalBits))
        }
        return DescriptorLayout(reports: reports)
    }

    private mutating func step() throws {
        let start = offset
        let prefix = bytes[offset]
        offset += 1

        if prefix == 0xFE {
            // Long item: dataSize, longItemTag, then dataSize bytes.
            guard offset + 1 < bytes.count else { throw HIDReportDescriptorParserError.truncatedItem(offset: start) }
            let dataSize = Int(bytes[offset])
            offset += 2 // dataSize byte + longItemTag byte
            guard offset + dataSize <= bytes.count else { throw HIDReportDescriptorParserError.truncatedItem(offset: start) }
            offset += dataSize
            return
        }

        let bTag = prefix >> 4
        let bType = (prefix >> 2) & 0x3
        let bSizeCode = prefix & 0x3
        let size = bSizeCode == 3 ? 4 : Int(bSizeCode)

        guard offset + size <= bytes.count else { throw HIDReportDescriptorParserError.truncatedItem(offset: start) }
        let dataBytes = bytes[offset..<(offset + size)]
        offset += size

        let unsignedValue = Self.littleEndian(dataBytes)
        let signedValue = Self.signExtend(unsignedValue, byteCount: size)

        switch bType {
        case 0: try mainItem(tag: bTag, value: UInt32(truncatingIfNeeded: unsignedValue))
        case 1: try globalItem(tag: bTag, value: unsignedValue, signedValue: signedValue, byteCount: size)
        case 2: try localItem(tag: bTag, value: UInt32(truncatingIfNeeded: unsignedValue), byteCount: size)
        default: break // reserved
        }
    }

    private static func littleEndian<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        var result: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            result |= UInt64(byte) << (8 * index)
        }
        return result
    }

    private static func signExtend(_ value: UInt64, byteCount: Int) -> Int {
        guard byteCount > 0 else { return 0 }
        let bits = byteCount * 8
        let signBit = UInt64(1) << (bits - 1)
        if value & signBit != 0 {
            let extended = value | (~UInt64(0) << bits)
            return Int(bitPattern: UInt(truncatingIfNeeded: extended))
        }
        return Int(value)
    }

    // MARK: Global items

    private mutating func globalItem(tag: UInt8, value: UInt64, signedValue: Int, byteCount: Int) throws {
        switch tag {
        case 0x0: globals.usagePage = UInt32(truncatingIfNeeded: value)
        case 0x1: globals.logicalMin = signedValue
        case 0x2: globals.logicalMax = signedValue
        case 0x3: globals.physicalMin = signedValue
        case 0x4: globals.physicalMax = signedValue
        case 0x5: globals.unit = UInt32(truncatingIfNeeded: value)
        case 0x6: globals.unitExponent = signedValue
        case 0x7: globals.reportSize = Int(value)
        case 0x8: globals.reportID = UInt8(truncatingIfNeeded: value); globals.hasReportID = true
        case 0x9: globals.reportCount = Int(value)
        case 0xA: globalStack.append(globals)
        case 0xB:
            guard let popped = globalStack.popLast() else {
                throw HIDReportDescriptorParserError.unbalancedPop(offset: offset)
            }
            globals = popped
        default: break // reserved (Unit unrelated tags, etc.)
        }
    }

    // MARK: Local items

    private mutating func localItem(tag: UInt8, value: UInt32, byteCount: Int) throws {
        switch tag {
        case 0x0: // Usage
            let extended = normalizedUsage(value, byteCount: byteCount)
            usageQueue.append(extended)
            lastUsage = extended
        case 0x1: // Usage Minimum
            usageMinPending = normalizedUsage(value, byteCount: byteCount)
        case 0x2: // Usage Maximum
            if let low = usageMinPending {
                let high = normalizedUsage(value, byteCount: byteCount)
                let lowUsage = low & 0xFFFF
                let highUsage = high & 0xFFFF
                if lowUsage <= highUsage {
                    for u in lowUsage...highUsage {
                        usageQueue.append((low & 0xFFFF0000) | u)
                    }
                }
                usageMinPending = nil
            }
        default:
            break // Designator/String index/Set delimiter — not needed for offset math
        }
    }

    /// Normalizes a usage value to `(page << 16) | usage`. A 4-byte local Usage item
    /// carries its own page in the high 16 bits; a 1-2 byte item uses the current
    /// Usage Page global. Either way the Usage Page global itself is left untouched.
    private func normalizedUsage(_ value: UInt32, byteCount: Int) -> UInt32 {
        if byteCount > 2 {
            return value
        }
        return (globals.usagePage << 16) | (value & 0xFFFF)
    }

    // MARK: Main items

    private mutating func mainItem(tag: UInt8, value: UInt32) throws {
        switch tag {
        case 0x8: try emitFields(direction: .input, flags: value)
        case 0x9: try emitFields(direction: .output, flags: value)
        case 0xB: try emitFields(direction: .feature, flags: value)
        case 0xA: // Collection
            let usage = lastUsage ?? 0
            collectionPath.append(usage)
            resetLocals()
        case 0xC: // End Collection
            if !collectionPath.isEmpty { collectionPath.removeLast() }
            resetLocals()
        default:
            resetLocals()
        }
    }

    private mutating func emitFields(direction: HIDReportDirection, flags: UInt32) throws {
        let isConstant = (flags & 0x1) != 0
        let isVariable = (flags & 0x2) != 0
        let isRelative = (flags & 0x4) != 0

        let reportID = globals.hasReportID ? globals.reportID : 0
        let key = ReportKey(direction: direction, reportID: reportID)
        if fieldsByReport[key] == nil {
            fieldsByReport[key] = []
            reportOrder.append(key)
            cursors[key] = 0
        }

        let count = max(globals.reportCount, 0)
        let size = max(globals.reportSize, 0)

        for i in 0..<count {
            let usage: UInt32
            if isConstant {
                usage = 0
            } else if !usageQueue.isEmpty {
                usage = usageQueue.removeFirst()
            } else if let last = lastUsage {
                usage = last
            } else {
                usage = 0
            }

            let bitOffset = cursors[key] ?? 0
            let field = DescriptorField(
                usagePage: usage >> 16,
                usage: usage & 0xFFFF,
                bitOffset: bitOffset,
                bitSize: size,
                logicalMin: globals.logicalMin,
                logicalMax: globals.logicalMax,
                physicalMin: globals.physicalMin,
                physicalMax: globals.physicalMax,
                unit: globals.unit,
                unitExponent: globals.unitExponent,
                isConstant: isConstant,
                isVariable: isVariable,
                isRelative: isRelative,
                collectionPath: collectionPath
            )
            fieldsByReport[key]?.append(field)
            cursors[key] = bitOffset + size
            _ = i
        }

        resetLocals()
    }

    private mutating func resetLocals() {
        usageQueue.removeAll()
        lastUsage = nil
        usageMinPending = nil
    }
}
