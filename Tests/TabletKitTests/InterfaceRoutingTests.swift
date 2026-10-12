// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import TabletKit

/// Replays captured interface descriptors through `InterfaceRouting`.
/// A registered device whose every interface defers never gets a driver;
/// that was the DTH-167 and Cintiq 13HD Touch bug.
final class InterfaceRoutingTests: XCTestCase {

    private struct Device: Decodable {
        let productID: String
        let transport: String
        let interfaces: [[[Int]]]
    }

    private func corpus(_ name: String) throws -> [Device] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/InterfaceRouting/\(name)")
        return try JSONDecoder().decode([Device].self, from: Data(contentsOf: url))
    }

    func testEveryRegisteredDeviceGetsADriver() throws {
        // Seizing 0x01 on these stops pen reports.
        let mustDefer: Set<String> = ["0x0357 USB 0x1", "0x0358 USB 0x1"]
        var failures: [String] = []
        var checked = 0
        for d in try corpus("corpus.json") + corpus("corpus-linuxwacom.json") {
            let pid = Int(d.productID.dropFirst(2), radix: 16)!
            guard pid != 0x0084,  // dongle: routed before the registry
                  !WacomDeviceRegistry.touchCompanionPIDs.contains(pid),
                  let spec = WacomDeviceRegistry.spec(for: pid),
                  spec.maxX > 0 || spec.buttonCount > 0
            else { continue }
            checked += 1
            let isBLE = d.transport.hasPrefix("Bluetooth")
            var drivers = 0
            for tops in d.interfaces {
                let pairs = tops.map { (page: $0[0], usage: $0[1]) }
                let page = pairs.first?.page ?? 0
                let deferred = InterfaceRouting.shouldDefer(
                    spec: spec, usagePage: page, isBLE: isBLE, pairs: pairs)
                if !deferred { drivers += 1 }
                let key = "\(d.productID) \(d.transport) 0x\(String(page, radix: 16))"
                if mustDefer.contains(key) && !deferred {
                    failures.append("\(spec.name) (\(key)): must defer")
                }
            }
            if drivers == 0 {
                failures.append("\(spec.name) (\(d.productID) \(d.transport)): every interface defers")
            }
        }
        XCTAssertGreaterThan(checked, 70)
        XCTAssertEqual(failures, [])
    }
}
