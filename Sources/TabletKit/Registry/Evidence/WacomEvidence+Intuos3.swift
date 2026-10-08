// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

extension WacomEvidence {
    /// Rows using the `.intuos3` report format.
    static let intuos3: Table = [
        0x00B0: [  // Intuos3 4×5 (PTZ-430)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00B1: [  // Intuos3 6×8 (PTZ-630)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00B2: [  // Intuos3 9×12 (PTZ-930)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00B3: [  // Intuos3 12×12 (PTZ-1230)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00B4: [  // Intuos3 12×19 (PTZ-1231W)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00B5: [  // Intuos3 WS (PTZ-631W)
            .penPosition: .init(.hardware, [.testerHardware, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.hardware, [.testerHardware, .linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00B7: [  // Intuos3 4×6 (PTZ-431W)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
    ]
}
