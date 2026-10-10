// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

extension WacomEvidence {
    /// Rows using the `.bamboo` report format.
    static let bamboo: Table = [
        0x00D0: [  // Bamboo Touch (CTT-460)
            .touch: .init(.hardware, [.testerHardware, .publicRecording]),
        ],
        0x00D1: [  // Bamboo Pen & Touch (CTH-460)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00D2: [  // Wacom CTH-461
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00D3: [  // Wacom CTH-661
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00D4: [  // Bamboo Pen (CTL-460)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
        ],
        0x00D5: [  // Bamboo Pen (CTL-660)
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x00D6: [  // Bamboo Fun Pen & Touch (CTH-461)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00D7: [  // Bamboo Pen & Touch (small)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00D8: [  // Wacom CTH-661
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00D9: [  // Bamboo Touch (CTT-460A)
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00DA: [  // Bamboo Pen & Touch SE (CTH-461SE)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00DB: [  // Bamboo Pen & Touch SE (CTH-661SE)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00DC: [  // Bamboo Touch (CTT-470)
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00DD: [  // Wacom CTL-470
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
        ],
        0x00DE: [  // Wacom CTH-470
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00DF: [  // Wacom CTH-670
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x0300: [  // Wacom CTL-471
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
        ],
        0x0301: [  // Bamboo One M (CTL-671)
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
        ],
        0x0302: [  // Wacom CTH-480
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .touch: .init(.recorded, [.publicRecording]),
        ],
        0x0303: [  // Wacom CTH-680
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .touch: .init(.recorded, [.publicRecording]),
        ],
        0x030E: [  // Wacom CTL-480
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x0318: [  // Wacom CTH-301
            .penPosition: .init(.sourced, [.openTabletDriver, .descriptorCorpus]),
            .pressure: .init(.sourced, [.openTabletDriver, .descriptorCorpus]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x0319: [  // Wacom CTH-300
            .penPosition: .init(.sourced, [.openTabletDriver, .descriptorCorpus]),
            .pressure: .init(.sourced, [.openTabletDriver, .descriptorCorpus]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x0323: [  // Wacom CTL-680
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x037A: [  // Wacom CTL-472
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
        ],
        0x037B: [  // Wacom CTL-672
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
        ],
    ]
}
