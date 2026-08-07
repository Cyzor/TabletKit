// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// HID report descriptors shared by the touch decode and interface
/// classification tests.
///
/// All of these are **written for these tests** from the HID Usage Tables and
/// the Precision Touchpad spec — none is a captured descriptor from any
/// device. Where a fixture is modeled on real hardware the observed facts are
/// recorded in its doc comment, which is where that knowledge belongs: the
/// project's standing rule is independently-derived only, so structural facts
/// learned from a third-party capture are written down and re-derived rather
/// than vendored as bytes. Same call as the CTL-460 `decodeBPT` provenance
/// comment and the IntuosV3 aux-report layout.
enum TouchDescriptorFixtures {

    /// A 10-finger Precision-Touchpad-style multitouch interface.
    ///
    /// Modeled on the touch interface of a Wacom Cintiq Pro 24 Touch
    /// (DTH-2420), USB `056a:0355`, whose descriptor is published by the
    /// `modfox/nib` project. Structure reproduced here, all of it re-derivable
    /// by running `descriptor-dump` against that public source:
    ///
    /// - input `0x81` — ten finger slots at a 48-bit stride: Tip Switch (1 bit)
    ///   + 7 pad, Contact Identifier (8), X (16, logical max 15360), Y (16,
    ///   logical max 8640); then Scan Time (16) at bit 480 and Contact Count
    ///   (8) at bit 496. 63-byte payload.
    /// - input `0x88` — single-contact variant, 7-byte payload, Tip Switch +
    ///   X/Y + Scan Time, no Contact Identifier and no Contact Count.
    /// - feature `0x84` — Contact Count Maximum. feature `0x83` — Device Mode
    ///   plus Device Index, the standard HID touch-enable control.
    ///
    /// Field bit offsets match the real device exactly. Two deliberate
    /// differences: this omits the physical-size and unit items (nothing here
    /// reads them), and it declares Contact Identifier's logical maximum as 255
    /// rather than the real device's nonsensical `[0..1]` on an 8-bit field.
    /// That quirk is the reason `PrecisionTouchDecoder` treats the contact id as
    /// an opaque value and never as a bounded index — worth keeping in mind, not
    /// worth reproducing a firmware bug to demonstrate.
    static let precisionTouch10Finger: String = [
        "050d0904a10185810922a10209421500250175019501810295078103095126ff",
        "007508950181020501093026003c751095018102093126c02195018102050dc0",
        "0922a10209421500250175019501810295078103095126ff0075089501810205",
        "01093026003c751095018102093126c02195018102050dc00922a10209421500",
        "250175019501810295078103095126ff007508950181020501093026003c7510",
        "95018102093126c02195018102050dc00922a102094215002501750195018102",
        "95078103095126ff007508950181020501093026003c751095018102093126c0",
        "2195018102050dc00922a10209421500250175019501810295078103095126ff",
        "007508950181020501093026003c751095018102093126c02195018102050dc0",
        "0922a10209421500250175019501810295078103095126ff0075089501810205",
        "01093026003c751095018102093126c02195018102050dc00922a10209421500",
        "250175019501810295078103095126ff007508950181020501093026003c7510",
        "95018102093126c02195018102050dc00922a102094215002501750195018102",
        "95078103095126ff007508950181020501093026003c751095018102093126c0",
        "2195018102050dc00922a10209421500250175019501810295078103095126ff",
        "007508950181020501093026003c751095018102093126c02195018102050dc0",
        "0922a10209421500250175019501810295078103095126ff0075089501810205",
        "01093026003c751095018102093126c02195018102050dc0095627ffff000075",
        "10950181020954250a75089501810285880922a1020942150025017501950181",
        "02950781030501093026003c751095018102093126c02195018102050dc00956",
        "27ffff000075109501810285840955250a75089501b102c0050d090ea1018583",
        "0923a102095209531500250a75089502b102c0c0",
    ].joined()

    /// A pen digitizer: Digitizer / Pen application collection (`0x0D`/`0x02`)
    /// → Stylus, report `0x10` carrying Tip Switch, In Range, X, Y and Tip
    /// Pressure.
    ///
    /// Deliberately shaped to be confusable with touch — same Generic Desktop
    /// X/Y, same Tip Switch — so only the application collection separates the
    /// two.
    static let pen: String = [
        "050d0902a10185100920a1000942093215002501750195028102950681030501",
        "09300931150026ff7f751095028102050d0930150026ff0f751095018102c0c0",
    ].joined()

    /// The pen collection above plus a single-finger Touch Screen collection on
    /// report `0x81`. Represents a device whose pen half is drivable and must
    /// not be discarded because touch is also present.
    static let penAndTouch: String = [
        "050d0902a10185100920a1000942093215002501750195028102950681030501",
        "09300931150026ff7f751095028102050d0930150026ff0f751095018102c0c0",
        "050d0904a10185810922a1020942150025017501950181029507810309517508",
        "950181020501150026ff7f7510093095018102093195018102c0c0",
    ].joined()

    /// A Windows Precision Touchpad shape: a legacy Mouse application
    /// collection (Generic Desktop Mouse → **relative** X/Y, report `0x01`)
    /// alongside a Touch Screen collection on report `0x81`.
    ///
    /// WPT devices are required to declare that mouse collection for boot
    /// compatibility, which makes this the commonest real-world multitouch
    /// layout — and the case where a classifier that only checks collection
    /// membership wrongly sees a drivable pen.
    static let mouseAndTouch: String = [
        "05010902a10185010901a1000509190129031500250195037501810295017505",
        "81030501093009311581257f750895028106c0c0050d0904a10185810922a102",
        "0942150025017501950181029507810309517508950181020501150026ff7f75",
        "10093095018102093195018102c0c0",
    ].joined()

    /// An opaque vendor interface: one 31-byte input report on a vendor-defined
    /// usage page, every field usage `0x00`.
    ///
    /// The "no derivable structure" case — no X/Y, so no digitizer
    /// classification is possible. Matches the shape of real vendor accessory
    /// descriptors (Wacom's ExpressKey Remote is one), which is why capability
    /// must never be inferred from their absence. See
    /// `HIDDescriptorReader.Parsed.hasDecodableFields`.
    static let opaqueVendor: String = [
        "060cff0900a10185107508150026ff00951f09008102c0",
    ].joined()

    /// A **pen** digitizer that declares its stylus under a Touch Screen
    /// application collection: Tip Switch, In Range, absolute X/Y, and Tip
    /// Pressure, with no contact identifier and no contact count.
    ///
    /// Cheap and generic tablets really do this. It is the false positive that
    /// a collection-membership test alone produces, and acting on that verdict
    /// would withhold the pen driver from a device that has no other one.
    static let penUnderTouchScreen: String = [
        "050d0904a1018501094209321500250175019502810295068103050109300931",
        "150026ff7f751095028102050d0930150026ff0f751095018102c0",
    ].joined()

    /// A pen report on Wacom's vendor page (0xFF0D) using the *standard*
    /// Digitizer usage numbers for every field — modeled on a real Cintiq
    /// Pro 24 (DTH-2420) pen report, confirmed field-for-field against that
    /// device's own descriptor via `descriptor-dump` before this was written.
    /// Structural facts, not vendored bytes, per the independently-derived
    /// rule: tip switch/barrel/secondary barrel/eraser/invert/in-range as six
    /// status bits, vendor-usage 24-bit X/Y, standard-usage 16-bit pressure,
    /// 8-bit signed tilt X/Y, 16-bit signed twist, vendor-usage 8-bit hover
    /// distance.
    static let vendorPagePen: String = [
        "060dff0902a10185100942150025017501950181020944150025017501950181",
        "02095a15002501750195018102094515002501750195018102093c1500250175",
        "01950181020932150025017501950181027501950281030a3001150027469b01",
        "007518950181020a3101150027b6e800007518950181020930150026ff1f7510",
        "95018102093d15c0253f750895018102093e15c0253f7508950181020941167c",
        "fc2683037510950181020a32011500253f750895018102c0",
    ].joined()

    /// A single-contact touch report on `0x0C` — the shape found on every
    /// Cintiq Pro / DTH pen-display touch descriptor checked so far (Cintiq
    /// Pro 16, Cintiq Pro 27, Cintiq Pro 17, DTH134), against
    /// `linuxwacom/wacom-hid-descriptors` and TabletKit's own
    /// `descriptor-dump` tool, 2026-08-06. `IntuosV2Decoder`'s report-ID
    /// switch has no case for `0x0C` — every one of these devices' touch
    /// frames were silently discarded until `WacomKnownDevice` started
    /// deriving a `PrecisionTouchDecoder` for report IDs it doesn't reserve.
    ///
    /// One finger slot (Tip Switch, Contact Identifier, X/Y, Width/Height) —
    /// the real devices declare several, but one is enough to exercise the
    /// decode path and, more importantly, to pin the axis maxima this test
    /// asserts against `WacomDeviceRegistry`'s `touchMaxX`/`touchMaxY` for
    /// 0x0350/0x0354 (Cintiq Pro 16): 13824 x 7776. Structure re-derived from
    /// the HID Usage Tables and confirmed against the real descriptor via
    /// `descriptor-dump`, not vendored bytes, per this file's standing rule.
    static let precisionTouchCintiqProShape: String = [
        "050d0904a101850c0922a102094215002501750195018102750795018103095175",
        "089501150026ff008102050109307510950115002600368102093126601e810205",
        "0d094875081500264700810209492628008102c0c0",
    ].joined()
}
