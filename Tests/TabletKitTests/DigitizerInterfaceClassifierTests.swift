// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import TabletKit

/// Whether a pen driver may be attached to an unrecognized HID interface.
///
/// The device-taking overload is not covered here — it only reads a descriptor
/// property off `IOHIDDevice` and hands the bytes to the descriptor overload,
/// which is what these tests exercise.
final class DigitizerInterfaceClassifierTests: XCTestCase {

    private func classify(_ hex: String) throws -> DigitizerInterfaceKind {
        classifyDigitizerInterface(
            descriptor: try HIDReportDescriptorParser.parse(hex: hex))
    }

    /// The case the guard exists for: a multitouch interface whose Generic
    /// Desktop X passes the IOKit element probe and would otherwise have a pen
    /// driver attached to it.
    func testMultitouchInterfaceIsTouchOnly() throws {
        XCTAssertEqual(try classify(TouchDescriptorFixtures.precisionTouch10Finger), .touchOnly)
    }

    /// A pen digitizer carrying the same usages must stay drivable. This is the
    /// regression that would break every fallback-driven tablet.
    func testPenInterfaceIsPen() throws {
        XCTAssertEqual(try classify(TouchDescriptorFixtures.pen), .pen)
    }

    /// The commonest real-world multitouch layout: a WPT device's mandatory legacy
    /// Mouse collection declares Generic Desktop X/Y outside any touch
    /// collection. Those are *relative*, so they must not count as a pen —
    /// otherwise the guard silently never fires on most touch hardware.
    func testWPTMouseCollectionDoesNotCountAsPen() throws {
        XCTAssertEqual(try classify(TouchDescriptorFixtures.mouseAndTouch), .touchOnly)
    }

    /// A hybrid interface classifies as pen: the pen half is drivable, and
    /// discarding it because touch is also present would lose real capability.
    func testHybridInterfaceIsPen() throws {
        XCTAssertEqual(try classify(TouchDescriptorFixtures.penAndTouch), .pen)
    }

    /// An opaque vendor descriptor with no X/Y at all yields no information —
    /// never a `.touchOnly` verdict, which the router would act on.
    func testOpaqueInterfaceIsUndetermined() throws {
        XCTAssertEqual(
            try classify(TouchDescriptorFixtures.opaqueVendor), .undetermined)
    }

    /// An empty descriptor is undetermined rather than a crash or a verdict.
    func testEmptyDescriptorIsUndetermined() throws {
        XCTAssertEqual(try classify(""), .undetermined)
    }

    /// Classification depends on the enclosing collection, not the usages: the
    /// pen and touch fixtures declare the same Generic Desktop X/Y and the same
    /// Digitizer Tip Switch, and still classify differently.
    func testUsagesAloneDoNotDistinguishPenFromTouch() throws {
        let pen = try HIDReportDescriptorParser.parse(hex: TouchDescriptorFixtures.pen)
        let touch = try HIDReportDescriptorParser.parse(hex: TouchDescriptorFixtures.precisionTouch10Finger)

        func usages(_ layout: DescriptorLayout) -> Set<UInt32> {
            Set(layout.reports.filter { $0.direction == .input }
                .flatMap(\.fields).filter { !$0.isConstant }.map(\.extendedUsage))
        }

        let shared = usages(pen).intersection(usages(touch))
        XCTAssertTrue(shared.contains(PrecisionTouchLayout.Usage.x))
        XCTAssertTrue(shared.contains(PrecisionTouchLayout.Usage.y))
        XCTAssertTrue(shared.contains(PrecisionTouchLayout.Usage.tipSwitch))

        XCTAssertNotEqual(
            classifyDigitizerInterface(descriptor: pen),
            classifyDigitizerInterface(descriptor: touch))
    }
}
