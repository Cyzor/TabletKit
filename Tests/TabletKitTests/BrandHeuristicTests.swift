// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import TabletKit

final class BrandHeuristicTests: XCTestCase {

    func testMatchesKnownBrandInProductString() {
        XCTAssertEqual(
            BrandHeuristic.likelyBrand(manufacturer: nil, product: "HUION Inspiroy 2S"),
            "Huion")
    }

    func testMatchesKnownBrandInManufacturerString() {
        XCTAssertEqual(
            BrandHeuristic.likelyBrand(manufacturer: "XP-PEN Technology", product: "Deco 01 V2"),
            "XP-Pen")
    }

    func testFallsBackToGenericCategoryKeyword() {
        XCTAssertEqual(
            BrandHeuristic.likelyBrand(manufacturer: "Acme Corp", product: "Graphics Tablet"),
            "a drawing tablet")
    }

    func testBrandNameTakesPriorityOverCategoryKeyword() {
        // Product string contains both "huion" and "tablet" — brand wins.
        XCTAssertEqual(
            BrandHeuristic.likelyBrand(manufacturer: nil, product: "Huion Pen Tablet H640P"),
            "Huion")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(
            BrandHeuristic.likelyBrand(manufacturer: "Logitech", product: "USB Receiver"))
    }

    func testNilInputsReturnNil() {
        XCTAssertNil(BrandHeuristic.likelyBrand(manufacturer: nil, product: nil))
    }

    func testCaseInsensitive() {
        XCTAssertEqual(
            BrandHeuristic.likelyBrand(manufacturer: nil, product: "WACOM CTL-472"),
            "Wacom")
    }
}
