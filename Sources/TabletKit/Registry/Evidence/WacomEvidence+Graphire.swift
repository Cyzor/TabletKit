// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

extension WacomEvidence {
    /// Rows using the `.graphire` report format.
    static let graphire: Table = [
        0x0010: [  // Graphire
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
        ],
        0x0011: [  // Graphire 2 (4×5)
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
        ],
        0x0012: [  // Graphire 2 (5×7)
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x0013: [  // Graphire 3 (4×5)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
        ],
        0x0014: [  // Graphire 3 (6×8)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
        ],
        0x0015: [  // Graphire 4 (4×5)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x0016: [  // Graphire 4 (6×8)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x0017: [  // Bamboo Fun small (CTE-450)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
        ],
        0x0018: [  // Bamboo Fun medium (CTE-650)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
        ],
        0x0019: [  // Bamboo1 Medium
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x0060: [  // Volito
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
        ],
        0x0061: [  // PenStation2
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x0062: [  // Volito 2
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x0063: [  // Volito 2 (2×3)
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x0064: [  // PenPartner2
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x0065: [  // Bamboo (MTE-450)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
        ],
        0x0069: [  // Wacom CTF-430
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
        ],
        0x006A: [  // Wacom CTE-460
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x006B: [  // Wacom CTE-660
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
    ]
}
