// SPDX-License-Identifier: MPL-2.0
//
// descriptor-dump — offline HID report-descriptor walker
//
// Parses a raw HID report descriptor (as hex bytes) and prints its reports,
// fields, and computed bit offsets. Useful when adding support for a new
// device: run MockTab's discovery capture on the device, then feed this tool
// either the discovery JSON directly or the `rawHex` string it contains.
//
// This performs no IOKit device access itself — it is pure offline analysis
// of bytes already captured elsewhere, which is why it lives in TabletKit
// rather than the app.
//
// Usage:
//     swift run --package-path <path/to/TabletKit> descriptor-dump <hex-string>
//     swift run --package-path <path/to/TabletKit> descriptor-dump --file <path>
//
// <path> may be either:
//   - a discovery JSON file (as produced by MockTab's capture/discovery flow),
//     from which `hidReportDescriptor.rawHex` is extracted, or
//   - a plain text file containing just the hex string.

import Foundation
import TabletKit

func usage() -> Never {
    fputs("""
        usage:
          descriptor-dump <hex-string>
          descriptor-dump --file <path-to-discovery-json-or-hex-file>
        """ + "\n", stderr)
    Foundation.exit(1)
}

func loadHex(fromFile path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path) else {
        fputs("error: could not read \(path)\n", stderr)
        Foundation.exit(1)
    }
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let descriptor = json["hidReportDescriptor"] as? [String: Any],
       let rawHex = descriptor["rawHex"] as? String {
        return rawHex
    }
    guard let text = String(data: data, encoding: .utf8) else {
        fputs("error: \(path) is neither a discovery JSON nor a UTF-8 hex file\n", stderr)
        Foundation.exit(1)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

let arguments = CommandLine.arguments.dropFirst()
guard !arguments.isEmpty else { usage() }

let hex: String
if arguments.first == "--file" {
    guard arguments.count == 2 else { usage() }
    hex = loadHex(fromFile: Array(arguments)[1])
} else {
    guard arguments.count == 1 else { usage() }
    hex = arguments.first!.trimmingCharacters(in: .whitespacesAndNewlines)
}

let layout: DescriptorLayout
do {
    layout = try HIDReportDescriptorParser.parse(hex: hex)
} catch {
    fputs("error: failed to parse descriptor: \(error)\n", stderr)
    Foundation.exit(1)
}

guard !layout.reports.isEmpty else {
    print("No reports found in descriptor.")
    Foundation.exit(0)
}

func label(_ direction: HIDReportDirection) -> String {
    switch direction {
    case .input: return "input"
    case .output: return "output"
    case .feature: return "feature"
    }
}

func usageString(_ field: DescriptorField) -> String {
    String(format: "page=0x%04X usage=0x%04X", field.usagePage, field.usage)
}

for report in layout.reports {
    let byteCount = (report.totalBits + 7) / 8
    print(String(format: "%@:0x%02X  %d fields, %d bits (%d bytes payload, +1 ID byte)",
                 label(report.direction), report.reportID, report.fields.count, report.totalBits, byteCount))
    for field in report.fields {
        let kind = field.isConstant ? "const" : (field.isVariable ? "var" : "array")
        let rel = field.isRelative ? " rel" : ""
        print(String(format: "  off=%-5d size=%-3d %@  %@  range=[%d..%d]%@",
                      field.bitOffset, field.bitSize, usageString(field), kind, field.logicalMin, field.logicalMax, rel))
    }
    if let dataModeID = layout.featureReportID(carryingUsage: 0xff0d1002), report.reportID == dataModeID {
        print("  → declares WACOM_HID_WD_DATAMODE (0xff0d1002)")
    }
    print("")
}

if let dataModeID = layout.featureReportID(carryingUsage: 0xff0d1002) {
    print(String(format: "DATAMODE feature report: 0x%02X", dataModeID))
} else {
    print("DATAMODE feature report: not declared (usage 0xff0d1002 not found)")
}
