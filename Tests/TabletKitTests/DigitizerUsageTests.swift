// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import TabletKit

/// `DigitizerUsage.isDecodable` against the two real opacity patterns it
/// exists to tell apart, plus the ordinary standard-page and vendor-blob
/// cases either side of them.
final class DigitizerUsageTests: XCTestCase {

    // MARK: - The two patterns this type exists to distinguish

    /// An Intuos5 touch descriptor: the *correct* Digitizer page (0x0D), but
    /// `usage == 0x00` on every field. Opaque despite the right page.
    func testStandardPageWithZeroUsageIsNotDecodable() {
        XCTAssertFalse(DigitizerUsage.isDecodable(usagePage: 0x0D, usage: 0x00))
    }

    /// A DTH-2420 pen report: Wacom's vendor page (0xFF0D), but the standard
    /// Digitizer usage numbers for tip switch, pressure, and X/Y position.
    /// Decodable despite the "wrong" page — this is the case that motivated
    /// replacing a page-only check.
    func testVendorPageWithKnownDigitizerUsageIsDecodable() {
        XCTAssertTrue(DigitizerUsage.isDecodable(usagePage: 0xFF0D, usage: DigitizerUsage.tipSwitch))
        XCTAssertTrue(DigitizerUsage.isDecodable(usagePage: 0xFF0D, usage: DigitizerUsage.tipPressure))
        XCTAssertTrue(DigitizerUsage.isDecodable(usagePage: 0xFF0D, usage: DigitizerUsage.vendorX))
        XCTAssertTrue(DigitizerUsage.isDecodable(usagePage: 0xFF0D, usage: DigitizerUsage.vendorY))
    }

    /// A classic Wacom blob report: a vendor page with an unnamed usage
    /// number. This must stay unreadable — admitting every vendor-page usage
    /// would undo the distinction the DTH-2420 case depends on.
    func testVendorPageWithUnknownUsageIsNotDecodable() {
        XCTAssertFalse(DigitizerUsage.isDecodable(usagePage: 0xFF00, usage: 0x01))
        XCTAssertFalse(DigitizerUsage.isDecodable(usagePage: 0xFF0D, usage: 0x77))
    }

    // MARK: - Ordinary cases

    func testStandardPageWithNamedUsageIsDecodable() {
        XCTAssertTrue(DigitizerUsage.isDecodable(usagePage: 0x01, usage: 0x30))  // Generic Desktop X
        XCTAssertTrue(DigitizerUsage.isDecodable(usagePage: 0x0D, usage: DigitizerUsage.tipSwitch))
    }

    /// Usage 0x00 is filler everywhere, standard page or not.
    func testZeroUsageIsNeverDecodable() {
        XCTAssertFalse(DigitizerUsage.isDecodable(usagePage: 0x01, usage: 0x00))
        XCTAssertFalse(DigitizerUsage.isDecodable(usagePage: 0xFF0D, usage: 0x00))
    }

    /// A page that is neither standard nor vendor-range is unreadable rather
    /// than guessed at.
    func testNonStandardNonVendorPageIsNotDecodable() {
        XCTAssertFalse(DigitizerUsage.isDecodable(usagePage: 0x80, usage: DigitizerUsage.tipSwitch))
    }

    // MARK: - Real descriptors

    /// Every field the DTH-2420's own pen report declares reads as decodable
    /// once the field carries a real usage — cross-checked against the
    /// device's live descriptor via `descriptor-dump` before this table was
    /// written, not assumed.
    func testAllDTH2420PenFieldsAreDecodable() {
        let usages: [UInt32] = [
            DigitizerUsage.tipSwitch, DigitizerUsage.barrelSwitch,
            DigitizerUsage.secondaryBarrel, DigitizerUsage.eraserSwitch,
            DigitizerUsage.invert, DigitizerUsage.inRange, DigitizerUsage.dataValid,
            DigitizerUsage.vendorX, DigitizerUsage.vendorY, DigitizerUsage.tipPressure,
            DigitizerUsage.tiltX, DigitizerUsage.tiltY, DigitizerUsage.twist,
            DigitizerUsage.vendorHoverDistance, DigitizerUsage.transducerSerial,
            DigitizerUsage.transducerToolType,
        ]
        for usage in usages {
            XCTAssertTrue(
                DigitizerUsage.isDecodable(usagePage: 0xFF0D, usage: usage),
                "usage 0x\(String(usage, radix: 16)) should be decodable on the vendor page")
        }
    }

    /// The PTH-660 touch report's contact fields, confirmed the same way.
    func testPTH660TouchFieldsAreDecodable() {
        XCTAssertTrue(DigitizerUsage.isDecodable(usagePage: 0xFF00, usage: DigitizerUsage.contactCount))
        XCTAssertTrue(DigitizerUsage.isDecodable(usagePage: 0xFF00, usage: DigitizerUsage.contactID))
        XCTAssertTrue(DigitizerUsage.isDecodable(usagePage: 0xFF00, usage: DigitizerUsage.tipSwitch))
    }
}
