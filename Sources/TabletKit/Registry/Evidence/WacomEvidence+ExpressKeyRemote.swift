// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

extension WacomEvidence {
    /// Rows using the `.expressKeyRemote` report format.
    static let expressKeyRemote: Table = [
        0x0331: [  // ExpressKey Remote (EKR-100)
            .tabletButtons: .init(.hardware, [.testerHardware, .libwacom]),
            .ring: .init(.hardware, [.testerHardware, .libwacom]),
        ],
    ]
}
