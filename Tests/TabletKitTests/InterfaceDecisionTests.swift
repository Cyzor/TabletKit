// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import TabletKit

final class InterfaceDecisionTests: XCTestCase {

    private func facts(
        vendor: Int = 0x056A, pid: Int, page: Int = 0x0D, pairs: [(Int, Int)] = [(0x0D, 0x02)],
        bt: Bool = false, override: TabletSpec? = nil
    ) -> InterfaceRouting.Facts {
        .init(
            vendorID: vendor, productID: pid, usagePage: page,
            usagePairs: pairs.map { (page: $0.0, usage: $0.1) }, isBluetooth: bt,
            overrideSpec: override)
    }

    private func decide(
        _ f: InterfaceRouting.Facts, attached: [Int] = [], hold: Bool = true,
        hasXY: Bool = false, kind: DigitizerInterfaceKind = .undetermined
    ) -> InterfaceRouting.Decision {
        InterfaceRouting.decide(f, attachedProductIDs: attached, holdTouchCompanion: hold) {
            .init(hasXY: hasXY, kind: kind)
        }
    }

    private func name(_ d: InterfaceRouting.Decision) -> String {
        switch d {
        case .wirelessDongle: "dongle"
        case .touchCompanion(let p): "touch of \(p)"
        case .holdTouchCompanion: "hold"
        case .deferToSibling: "defer"
        case .driver(let s, let seize): "driver \(s.productID)\(seize ? " seized" : "")"
        case .observeTouchOnly: "observe"
        case .wacomFallback: "wacom fallback"
        case .genericDigitizer: "generic"
        case .ledCompanion(let p): "led of \(p)"
        case .skip: "skip"
        }
    }

    private let touchParent = WacomDeviceRegistry.knownDevices.first { $0.touchCompanionPID != nil }!
    private let ledParent = WacomDeviceRegistry.knownDevices.first { $0.ledCompanionPID != nil }!

    func testDongleOnlyOnTheMainWacomVendor() {
        XCTAssertEqual(name(decide(facts(pid: 0x0084))), "dongle")
        XCTAssertNotEqual(name(decide(facts(vendor: 0x0531, pid: 0x0084))), "dongle")
    }

    func testTouchSensorJoinsItsTabletOrWaits() {
        let sensor = touchParent.touchCompanionPID!
        XCTAssertEqual(name(decide(facts(pid: sensor), attached: [touchParent.productID])),
                       "touch of \(touchParent.productID)")
        XCTAssertEqual(name(decide(facts(pid: sensor))), "hold")
        XCTAssertNotEqual(name(decide(facts(pid: sensor), hold: false)), "hold")
    }

    func testRegisteredDevices() {
        // PTH-860: the 0x01 interface without a pen collection waits for 0xFF00.
        XCTAssertEqual(name(decide(facts(pid: 0x0358, page: 0x01, pairs: [(0x01, 0x02)]))), "defer")
        XCTAssertEqual(name(decide(facts(pid: 0x0358, page: 0xFF00, pairs: [(0xFF00, 0x01)]))), "driver 856")
        XCTAssertEqual(name(decide(facts(pid: 0x0358, page: 0x01, bt: true))), "driver 856")
        // Cintiq 24HD: the 0x01 digitizer is seized; 0xFF00 waits.
        XCTAssertEqual(name(decide(facts(pid: 0x00F4, page: 0x01))), "driver 244 seized")
        XCTAssertEqual(name(decide(facts(pid: 0x00F4, page: 0xFF00))), "defer")
    }

    func testOverrideSpecReplacesTheRegistryForAnyVendor() {
        let spec = TabletSpec(
            productID: 0x5202, name: "Quick Keys", format: .xencelabs, maxX: 0, maxY: 0,
            maxPressure: 0, buttonCount: 8, hasTouchRing: true, hasEraser: false, seizeUSB: false)
        XCTAssertEqual(name(decide(facts(vendor: 0x28BD, pid: 0x5202, override: spec))), "driver 20994")
    }

    func testUnregisteredInterfacesFollowTheDescriptor() {
        XCTAssertEqual(name(decide(facts(pid: 0x7FFF), hasXY: true, kind: .pen)), "wacom fallback")
        XCTAssertEqual(name(decide(facts(vendor: 0x256C, pid: 0x006D), hasXY: true, kind: .pen)), "generic")
        XCTAssertEqual(name(decide(facts(vendor: 0x256C, pid: 0x006D), hasXY: true, kind: .touchOnly)), "observe")
        XCTAssertEqual(name(decide(facts(pid: 0x7FFF))), "skip")
    }

    func testLEDCompanionNeedsItsTablet() {
        let led = ledParent.ledCompanionPID!
        XCTAssertEqual(name(decide(facts(pid: led), attached: [ledParent.productID])),
                       "led of \(ledParent.productID)")
        XCTAssertEqual(name(decide(facts(pid: led))), "skip")
    }

    func testRegisteredDevicesNeverProbeTheDescriptor() {
        _ = InterfaceRouting.decide(facts(pid: 0x0358, page: 0xFF00), attachedProductIDs: []) {
            XCTFail("probed a registered device")
            return .init(hasXY: false, kind: .undetermined)
        }
    }

    /// Every captured registered device gets a driver on some interface, through
    /// the whole decision rather than only the deferral rule.
    func testCorpusDevicesEachGetADriver() throws {
        struct Device: Decodable { let productID: String; let transport: String; let interfaces: [[[Int]]] }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/InterfaceRouting")
        let corpus = try ["corpus.json", "corpus-linuxwacom.json"].flatMap {
            try JSONDecoder().decode([Device].self, from: Data(contentsOf: dir.appendingPathComponent($0)))
        }
        var failures: [String] = []
        var checked = 0
        for d in corpus {
            let pid = Int(d.productID.dropFirst(2), radix: 16)!
            guard pid != 0x0084, !WacomDeviceRegistry.touchCompanionPIDs.contains(pid),
                  let spec = WacomDeviceRegistry.spec(for: pid), spec.maxX > 0 || spec.buttonCount > 0
            else { continue }
            checked += 1
            let drivers = d.interfaces.filter { tops in
                let pairs = tops.map { (page: $0[0], usage: $0[1]) }
                let f = InterfaceRouting.Facts(
                    vendorID: 0x056A, productID: pid, usagePage: pairs.first?.page ?? 0,
                    usagePairs: pairs, isBluetooth: d.transport.hasPrefix("Bluetooth"))
                if case .driver = decide(f) { return true }
                return false
            }
            if drivers.isEmpty { failures.append("\(spec.name) (\(d.productID) \(d.transport))") }
        }
        XCTAssertGreaterThan(checked, 70)
        XCTAssertEqual(failures, [])
    }
}
