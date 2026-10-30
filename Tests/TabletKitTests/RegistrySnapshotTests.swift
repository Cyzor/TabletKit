import XCTest
@testable import TabletKit

final class RegistrySnapshotTests: XCTestCase {

    /// registry.json must match the registry; `swift run registry-export`
    /// rewrites it.
    func testCommittedRegistryJSONIsCurrent() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("registry.json")
        let committed = try JSONDecoder().decode(RegistrySnapshot.self, from: Data(contentsOf: url))
        let current = RegistrySnapshot.current()
        let hint = "registry.json is out of date; run `swift run registry-export`"
        XCTAssertEqual(committed.schemaVersion, current.schemaVersion, hint)
        XCTAssertEqual(committed.vendorID, current.vendorID, hint)
        XCTAssertEqual(committed.note, current.note, hint)
        XCTAssertEqual(committed.deviceCount, current.deviceCount, hint)
        XCTAssertEqual(committed.devices.count, current.devices.count, hint)
        for (old, new) in zip(committed.devices, current.devices) where old != new {
            XCTFail("\(hint): \(new.productID) \(new.name) differs")
        }
    }

    /// Optional fields write null rather than vanishing, so readers can index
    /// every key.
    func testOptionalFieldsWriteNull() throws {
        let data = try RegistrySnapshot.current().encoded()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let devices = try XCTUnwrap(json["devices"] as? [[String: Any]])
        XCTAssertFalse(devices.isEmpty)
        for device in devices {
            XCTAssertEqual(device.count, 20, "\(device["productID"] ?? "?") should carry every key")
        }
    }
}
