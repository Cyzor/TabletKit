// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

extension WacomEvidence {
    /// Rows using the `.cintiqV1` report format.
    static let cintiqV1: Table = [
        0x003F: [  // Cintiq 21UX (DTZ-2100)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x0057: [  // Cintiq 22 (DTK-2241)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x0059: [  // Cintiq 22 Touch (DTH-2242)
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x005B: [  // Wacom Cintiq 22HD Touch (DTH-2200)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x00C5: [  // Cintiq 20WSX (DTZ-2000W)
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x00C6: [  // Cintiq 12WX
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel]),
        ],
        0x00CC: [  // Cintiq 21UX2 (DTK-2100)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00F4: [  // Cintiq 24HD (DTK-2400)
            .penPosition: .init(.hardware, [.testerHardware, .publicRecording, .linuxKernel]),
            .pressure: .init(.hardware, [.testerHardware, .publicRecording, .linuxKernel]),
            .ring: .init(.sourced, [.libwacom]),
        ],
        0x00F8: [  // Cintiq 24HD Touch (DTH-2400)
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x00FA: [  // Cintiq 22HD (DTK-2200)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x0325: [  // Wacom Cintiq Companion 2 (DTH-W1310)
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x032A: [  // Cintiq 27QHD (DTK-2700)
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x032B: [  // Cintiq 27QHD Touch (DTH-2700)
            .penPosition: .init(.hardware, [.testerHardware, .linuxKernel]),
            .pressure: .init(.hardware, [.testerHardware, .linuxKernel]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x032C: [  // Cintiq 27QHD Touch sensor (pairs 0x032B)
            .touch: .init(.hardware, [.testerHardware]),
        ],
    ]
}
