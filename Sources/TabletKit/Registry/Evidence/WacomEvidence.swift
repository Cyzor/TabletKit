// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

/// Evidence for Wacom models, keyed by product ID, kept apart from the
/// registry rows so each report format's evidence lives in its own file.
///
/// Notes are public. Cite public sources only, and never name testers,
/// serial numbers, or capture files.
enum WacomEvidence {
    typealias Table = [Int: [TabletFeature: FeatureEvidence]]

    static let families: [Table] = [
        intuosV1, intuosV2, intuosV3, intuos3, bamboo, graphire,
        cintiqV1, pl, dtu, dtus, expressKeyRemote,
    ]

    /// All families merged. A test fails if a product ID appears in two.
    static let table: Table = families.reduce(into: [:]) { merged, family in
        merged.merge(family) { first, _ in first }
    }

    /// Business and signature displays. They still work; they're just not
    /// counted as gaps.
    static let outOfScope: [Int: String] = [
        0x0039: "Signature pad",       // DTU-710
        0x003A: "Business display",    // DTI-520
        0x00C7: "Business display",    // DTU-1931
        0x00CE: "Business display",    // DTU-2231
        0x00F0: "Business display",    // DTU-1631
        0x00FB: "Business display",    // DTU-1031
        0x032F: "Business display",    // DTU-1031X
        0x0336: "Business display",    // DTU-1141
        0x0343: "Business display",    // DTK-1651
        0x0359: "Business display",    // DTU-1141B
        0x035A: "Business display",    // DTH-1152
        0x037D: "Business display",    // DTH-2452
    ]

    /// Models that also connect over Bluetooth, by their USB product ID.
    /// Rows that are themselves the Bluetooth product ID are listed too.
    static let bluetoothModels: Set<Int> = [
        0x00BC,                          // Intuos4 WL
        0x0357, 0x0360,                  // Intuos Pro M (PTH-660)
        0x0358, 0x0361,                  // Intuos Pro L (PTH-860)
        0x0376, 0x0378,                  // Intuos S and M (CTL-4100WL, CTL-6100WL)
        0x0392, 0x03DC,                  // Intuos Pro S (PTH-460)
        0x03F5, 0x03F7, 0x03F9,          // Intuos Pro gen 3
    ]

    /// Models that work through the ACK-40401 wireless kit.
    static let receiverModels: Set<Int> = [
        0x0026, 0x0027, 0x0028,          // Intuos5 touch S, M, L
        0x0314, 0x0315, 0x0317,          // Intuos Pro S, M, L (PTH-451, 651, 851)
    ]
}
