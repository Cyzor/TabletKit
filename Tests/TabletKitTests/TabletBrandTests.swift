// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import TabletKit

final class TabletBrandTests: XCTestCase {

    func testNamesIgnoreCaseSpacesAndPunctuation() {
        for name in ["xppen", "XP-Pen", "XP Pen", "xp_pen"] {
            XCTAssertEqual(TabletBrand(name: name), .xpPen, name)
        }
        XCTAssertEqual(TabletBrand(name: "HUION"), .huion)
        XCTAssertEqual(TabletBrand(name: "gaomon"), .gaomon)
        XCTAssertEqual(TabletBrand(name: "Ugee"), .ugee)
        XCTAssertEqual(TabletBrand(name: "parblo"), .parblo)
        XCTAssertNil(TabletBrand(name: "xencelabs"))
        XCTAssertNil(TabletBrand(name: "wacom"))
        XCTAssertNil(TabletBrand(name: ""))
    }

    /// 0x006F is listed under both Huion and Gaomon, so the firmware name decides.
    func testFirmwareNameSettlesAProductIDBothBrandsUse() {
        XCTAssertEqual(TabletBrand.brands(vendorID: 0x256C, productID: 0x006F, firmwareName: "HUION_T204_190801"), [.huion])
        XCTAssertEqual(TabletBrand.brands(vendorID: 0x256C, productID: 0x006F, firmwareName: "OEM02_T19m_200101"), [.gaomon])
        XCTAssertEqual(TabletBrand.brands(vendorID: 0x256C, productID: 0x006F), [.huion, .gaomon])
    }

    /// A firmware name no profile lists still tells the brand by its prefix.
    func testFirmwarePrefixWithoutAListedModel() {
        XCTAssertEqual(TabletBrand.brands(vendorID: 0x256C, productID: 0x006F, firmwareName: "GM001_T999_000000"), [.gaomon])
        XCTAssertEqual(TabletBrand.brands(vendorID: 0x256C, productID: 0x006F, firmwareName: "HUION_T999_000000"), [.huion])
    }

    func testProductIDListedUnderTwoBrandsIsBoth() {
        XCTAssertEqual(TabletBrand.brands(vendorID: 0x5543, productID: 0x0081), [.parblo, .ugee])
    }

    func testUnlistedProductIDIsTheVendorsMainBrand() {
        XCTAssertEqual(TabletBrand.brands(vendorID: 0x256C, productID: 0xFFF0), [.huion])
        XCTAssertEqual(TabletBrand.brands(vendorID: 0x28BD, productID: 0xFFF0), [.xpPen])
        XCTAssertEqual(TabletBrand.brands(vendorID: 0x5543, productID: 0xFFF0), [])
        XCTAssertEqual(TabletBrand.brands(vendorID: 0x056A, productID: 0x0357), [])
    }

    func testXencelabsIsNeverABrand() {
        for productID in [0x5201, 0x5202, 0x5203, 0x5204, 0x520B, 0x520D] {
            XCTAssertEqual(TabletBrand.brands(vendorID: 0x28BD, productID: productID), [], String(productID, radix: 16))
        }
    }

    func testFirmwareNameNamesTheModel() {
        let profile = VendorDeviceRegistry.profile(forVendorID: 0x256C, productID: 0x006F, firmwareName: "HUION_T204_190801")
        XCTAssertEqual(profile?.productName, "Huion H950P")
        XCTAssertNil(VendorDeviceRegistry.profile(forVendorID: 0x256C, productID: 0x006F, firmwareName: nil))
        XCTAssertNil(VendorDeviceRegistry.profile(forVendorID: 0x256C, productID: 0x006F, firmwareName: "HUION_T999_000000"))
    }

    func testStringDescriptorText() {
        let name = Array("HUION_T204_190801".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        XCTAssertEqual(UCLogicTabletInfo.text(ofStringDescriptor: [UInt8(name.count + 2), 0x03] + name), "HUION_T204_190801")
        XCTAssertEqual(UCLogicTabletInfo.text(ofStringDescriptor: [0x02, 0x03]), "")
        XCTAssertNil(UCLogicTabletInfo.text(ofStringDescriptor: [0x04, 0x02, 0x41, 0x00]))
        XCTAssertNil(UCLogicTabletInfo.text(ofStringDescriptor: [0x04]))
    }
}
