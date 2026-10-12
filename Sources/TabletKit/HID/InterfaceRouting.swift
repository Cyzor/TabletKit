// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

/// Which of a tablet's HID interfaces should carry its driver.
///
/// Pure: it reads only an interface's usages and the tablet's spec, so
/// captured descriptors can be replayed through it without hardware.
public enum InterfaceRouting {

    public typealias UsagePair = (page: Int, usage: Int)

    /// True if any top-level collection is a digitizer pen (0x0D/0x02).
    public static func isPenCollection(in pairs: [UsagePair]) -> Bool {
        pairs.contains { $0.page == 0x0D && $0.usage == 0x02 }
    }

    /// Whether an interface waits for a sibling interface to create the
    /// driver, then joins it as a secondary.
    ///
    /// - IntuosV2 (PTH-x60/x80): the vendor interface 0xFF00 is primary.
    ///   Interface 0x01 defers and is never seized; seizing it stops pen
    ///   reports.
    /// - CintiqV1 (DTK-2400 and others): interface 0x01 carries the pen.
    ///   0xFF00 carries only a periodic status report, so it defers.
    ///
    /// - Parameters:
    ///   - usagePage: the interface's primary usage page.
    ///   - pairs: every top-level collection the interface declares.
    public static func shouldDefer(
        spec: TabletSpec, usagePage: Int, isBLE: Bool, pairs: [UsagePair]
    ) -> Bool {
        guard !isBLE, spec.seizeUSB else { return false }
        switch spec.format {
        case .cintiqV1:
            return usagePage == 0xFF00
        case .intuosV2:
            // Pen displays like the DTH-167 have no 0xFF00 sibling: their one
            // interface leads with page 0x01 but also declares the pen
            // collection. Deferring it waited for a sibling that never comes.
            return usagePage == 0x01 && !isPenCollection(in: pairs)
        default:
            // Only the families above have a sibling to wait for. Deferring
            // any other family stranded single-interface devices such as the
            // DTU-1031, DTU-2231, and Cintiq 13HD Touch.
            return false
        }
    }
}
