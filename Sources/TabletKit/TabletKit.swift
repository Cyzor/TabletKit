// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
//
// This file is the package's front door — the one place to start reading.
// (Deliberately no declaration here: a type named `TabletKit` inside the
// `TabletKit` module collides with the module's own DocC landing page and
// clobbers its curated topic groups — confirmed the hard way. A plain
// comment block gets the "first file to open" role without that risk, or an
// ambiguous `TabletKit.TabletKit` reference for consumers.)
//
// A HID decoder layer for drawing tablets on macOS: raw USB and Bluetooth
// report bytes in, structured pen/button/touch events out. No AppKit or
// event-injection plumbing; the only system dependency is IOKit HID,
// isolated to HIDDeviceSupport.swift.
//
// The core loop, regardless of device:
//
// 1. Look up the device in the registry (WacomDeviceRegistry or
//    VendorDeviceRegistry) to get its TabletSpec.
// 2. Call makeDecoder() once for each device.
// 3. On each HID report, pass the bytes to the decoder's events(_:) and act
//    on the TabletEvents it returns.
//
// See the README for a full worked example against a real device, and the
// DocC catalog (TabletKit.docc/TabletKit.md) for the curated symbol index.
//
// This is not yet a facade. TabletKit doesn't have a session layer —
// enumeration, interface routing, and decoder selection are still the
// caller's job. When that layer exists, its entry point belongs in this
// file, replacing this comment's three-step manual loop with a real one-call
// API. Until then, this file exists to be found first, not to hide the
// current wiring cost.
