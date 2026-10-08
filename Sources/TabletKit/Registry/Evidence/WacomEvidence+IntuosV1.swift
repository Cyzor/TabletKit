// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

extension WacomEvidence {
    /// Rows using the `.intuosV1` report format.
    static let intuosV1: Table = [
        0x0020: [  // Intuos 4×5
            .penPosition: .init(.sourced, [.openTabletDriver]),
        ],
        0x0021: [  // Intuos 6×8
            .penPosition: .init(.hardware, [.testerHardware, .openTabletDriver]),
            .pressure: .init(.hardware, [.testerHardware]),
        ],
        0x0022: [  // Intuos 9×12
            .penPosition: .init(.sourced, [.openTabletDriver]),
        ],
        0x0023: [  // Intuos 12×12
            .penPosition: .init(.sourced, [.openTabletDriver]),
        ],
        0x0024: [  // Intuos 12×18
            .penPosition: .init(.sourced, [.openTabletDriver]),
        ],
        0x0026: [  // Intuos5 S (PTH-450)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.recorded, [.publicRecording, .libwacom]),
        ],
        0x0027: [  // Intuos5 M (PTH-650)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.recorded, [.publicRecording, .libwacom]),
        ],
        0x0028: [  // Intuos5 L (PTH-850)
            .penPosition: .init(.hardware, [.maintainerHardware, .publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.hardware, [.maintainerHardware, .publicRecording, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.hardware, [.maintainerHardware, .publicRecording, .libwacom]),
            .wirelessReceiver: .init(.hardware, [.maintainerHardware]),
        ],
        0x0029: [  // Wacom PTK-450
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
        ],
        0x002A: [  // Wacom PTK-650
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
        ],
        0x0041: [  // Intuos 2 (4×5)
            .penPosition: .init(.sourced, [.openTabletDriver]),
        ],
        0x0042: [  // Intuos 2 (6×8)
            .penPosition: .init(.sourced, [.openTabletDriver]),
        ],
        0x0043: [  // Intuos 2 (9×12)
            .penPosition: .init(.sourced, [.openTabletDriver]),
        ],
        0x0044: [  // Intuos 2 (12×12)
            .penPosition: .init(.sourced, [.openTabletDriver]),
        ],
        0x0045: [  // Intuos 2 (12×18)
            .penPosition: .init(.sourced, [.openTabletDriver]),
        ],
        0x00B8: [  // Intuos4 S (PTK-440)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
        ],
        0x00B9: [  // Intuos4 M (PTK-640)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
        ],
        0x00BA: [  // Intuos4 L (PTK-840)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
        ],
        0x00BB: [  // Intuos4 XL (PTK-1240)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
        ],
        0x00BC: [  // Intuos4 WL (PTK-540WL)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
            .bluetooth: .init(.sourced, [.libwacom]),
        ],
        0x00BD: [  // Intuos4 WL (PTK-540WL) BT
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
        ],
        0x0304: [  // Wacom Cintiq 13HD (DTK-1300)
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x0314: [  // Intuos Pro S (PTH-451)
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel, .openTabletDriver]),
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.recorded, [.publicRecording, .libwacom]),
        ],
        0x0315: [  // Intuos Pro M (PTH-651)
            .penPosition: .init(.hardware, [.testerHardware, .publicRecording, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.hardware, [.testerHardware, .publicRecording, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.recorded, [.publicRecording, .libwacom]),
        ],
        0x0317: [  // Intuos Pro L (PTH-851)
            .penPosition: .init(.hardware, [.testerHardware, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.hardware, [.testerHardware, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x0333: [  // Cintiq 13HD Touch (DTH-1300)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x033B: [  // Wacom CTL-490
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x033C: [  // Wacom CTH-490
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x033D: [  // Wacom CTL-690
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x033E: [  // Wacom CTH-690
            .penPosition: .init(.hardware, [.testerHardware, .linuxKernel, .openTabletDriver]),
            .pressure: .init(.hardware, [.testerHardware, .linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
    ]
}
