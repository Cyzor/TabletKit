// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation
import IOKit.hid

/// What kind of digitizer an unrecognized HID interface presents.
///
/// Answers one narrow routing question: may a *pen* driver be attached to this
/// interface? Nothing more — it says nothing about whether a device is
/// supported, only whether pointing the pen path at it would be a mistake.
public enum DigitizerInterfaceKind: Equatable {
    /// At least one X/Y-bearing input report sits outside a touch collection.
    /// A pen driver is appropriate. Hybrid interfaces that carry both pen and
    /// touch reports land here — the pen half is drivable and must not be lost.
    case pen

    /// Every X/Y-bearing input report lives inside a Digitizer Touch Screen or
    /// Touch Pad collection. A pen driver must not be attached: the report
    /// repeats X/Y once per finger, and a pen path reading IOKit element values
    /// has no way to tell the repetitions apart, so the cursor is dragged
    /// between contacts.
    case touchOnly

    /// No usable descriptor, or no X/Y input reports at all. Callers must treat
    /// this as "no information" and fall back to whatever they did before —
    /// never as evidence of absence.
    case undetermined
}

/// Classifies an interface from its parsed report descriptor.
///
/// The distinction is the enclosing application collection, not the usages:
/// pen and touch reports both carry Generic Desktop X/Y and a Digitizer Tip
/// Switch, so usages alone cannot separate them. This is the same
/// discrimination `PrecisionTouchLayout.derive` makes, applied at the routing
/// layer instead of the decode layer.
public func classifyDigitizerInterface(
    descriptor: DescriptorLayout
) -> DigitizerInterfaceKind {
    for report in descriptor.reports where report.direction == .input {
        for field in report.fields
        where field.extendedUsage == PrecisionTouchLayout.Usage.x && !field.isConstant {
            // Relative X never indicates a pen. Windows Precision Touchpad
            // devices are required to declare a legacy Mouse collection
            // (Generic Desktop Mouse → relative X/Y) for boot compatibility
            // alongside their touch collection, so a non-touch X on its own is
            // not evidence of a digitizer — without this check the commonest
            // WPT shape classifies as `.pen` and the guard never fires. A pen
            // digitizer's X/Y are absolute by definition.
            if field.isRelative { continue }

            let isTouch =
                field.collectionPath.contains(PrecisionTouchLayout.Usage.touchScreenCollection)
                || field.collectionPath.contains(PrecisionTouchLayout.Usage.touchPadCollection)

            // One absolute X outside any touch collection is enough: the
            // interface has something a pen driver can legitimately read, so
            // classification stops here.
            if !isTouch { return .pen }
        }
    }

    // Every absolute X sits in a touch collection — necessary for `.touchOnly`,
    // but not sufficient. The collection says where a field was declared, not
    // what the device is, and some pen tablets declare a stylus under Touch
    // Screen. Withholding the pen driver from one of those would silently take
    // a working device away from its only driver, so the verdict additionally
    // requires a report that actually tracks multiple contacts.
    let multiContact = PrecisionTouchLayout.derive(from: descriptor)
        .contains { $0.isMultiContact }
    return multiContact ? .touchOnly : .undetermined
}

/// Classifies a live device by reading and parsing its report descriptor.
///
/// Fails open by design: a device that exposes no descriptor, or one this
/// parser cannot walk, returns `.undetermined` so callers keep their existing
/// behavior. A classifier that guessed under uncertainty would be worse than
/// no classifier, since the cost of a false `.touchOnly` is a drawing tablet
/// that silently stops working.
public func classifyDigitizerInterface(_ device: IOHIDDevice) -> DigitizerInterfaceKind {
    guard
        let raw = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data,
        let descriptor = try? HIDReportDescriptorParser.parse([UInt8](raw))
    else { return .undetermined }

    return classifyDigitizerInterface(descriptor: descriptor)
}
