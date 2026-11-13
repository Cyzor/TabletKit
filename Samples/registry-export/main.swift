// SPDX-License-Identifier: MPL-2.0
//
// registry-export — writes registry.json from the Wacom registry
//
// Run after editing WacomDeviceRegistry+Devices.swift and commit the result. The
// registry tests fail while the committed file is out of date.
//
// Usage:
//     swift run registry-export [output-path]
//
// The output path defaults to registry.json at the package root.

import Foundation
import TabletKit

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? root.appendingPathComponent("registry.json")
let snapshot = RegistrySnapshot.current()
do {
    try snapshot.encoded().write(to: output, options: .atomic)
    print("Wrote \(snapshot.deviceCount) devices to \(output.path)")
} catch {
    fputs("registry-export: \(error.localizedDescription)\n", stderr)
    exit(1)
}
