// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import TabletKit

/// `DeviceInstanceKey` value semantics: string round-trip, the
/// serial → locationID → empty token ladder, and placeholder-serial handling.
///
/// The claim-the-legacy-prefix rule that consumes these keys is host policy
/// (`DeviceInstanceClaims` in MockTab) and is exercised by its own harness at
/// `tools/tests/instance-identity-tests/`.
final class DeviceInstanceKeyTests: XCTestCase {
    private let pth860 = 0x0357

    func testKeyStringRoundTrip() {
        let cases = [
            DeviceInstanceKey(productID: pth860, instance: ""),
            DeviceInstanceKey(productID: pth860, instance: "9KL0123456"),
            DeviceInstanceKey(productID: 0x5202, instance: "loc-14200000"),
            DeviceInstanceKey(productID: 0xF4, instance: "serial with spaces"),
        ]
        for key in cases {
            XCTAssertEqual(DeviceInstanceKey(stringValue: key.stringValue), key,
                           "round-trip \(key.stringValue)")
        }
        XCTAssertEqual(DeviceInstanceKey(productID: pth860, instance: "").stringValue, "0x357",
                       "empty-instance string form")
        XCTAssertNil(DeviceInstanceKey(stringValue: "357"), "missing 0x prefix rejected")
        XCTAssertNil(DeviceInstanceKey(stringValue: "0xZZ"), "non-hex PID rejected")
    }

    func testTokenSelection() {
        XCTAssertEqual(
            DeviceInstanceKey(productID: pth860, usbSerial: "ABC", locationID: 0x14200000).instance,
            "ABC", "serial wins over locationID")
        XCTAssertEqual(
            DeviceInstanceKey(productID: pth860, usbSerial: "", locationID: 0x14200000).instance,
            "loc-14200000", "empty serial falls back to locationID")
        XCTAssertEqual(
            DeviceInstanceKey(productID: pth860, usbSerial: nil, locationID: 0).instance,
            "", "neither → empty token (legacy identity)")
    }

    /// The Xencelabs Quick Keys wireless dongle relay reports the puck's serial
    /// as a literal all-zero string rather than omitting it — that must not be
    /// taken as a real instance token (it used to split a wirelessly-connected
    /// puck into its own row and settings namespace next to the wired one).
    func testPlaceholderSerialTreatedAsAbsent() {
        XCTAssertTrue(DeviceInstanceKey.isPlaceholderSerial("000000000000"),
                      "all-zero serial recognized as placeholder")
        XCTAssertTrue(DeviceInstanceKey.isPlaceholderSerial("00:00:00:00:00:00"),
                      "all-zero MAC-style serial recognized as placeholder")
        XCTAssertFalse(DeviceInstanceKey.isPlaceholderSerial("XP213BV1001188"),
                       "real serial not mistaken for placeholder")
        XCTAssertEqual(
            DeviceInstanceKey(productID: 0x5202, usbSerial: "000000000000", locationID: 0x14200000)
                .instance,
            "loc-14200000", "placeholder serial falls back to locationID like an absent one")
        XCTAssertEqual(
            DeviceInstanceKey(productID: 0x5202, usbSerial: "000000000000", locationID: 0).instance,
            "", "placeholder serial with no locationID falls back to legacy identity")
    }
}
