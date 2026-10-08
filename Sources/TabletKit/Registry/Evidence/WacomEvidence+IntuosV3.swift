// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

extension WacomEvidence {
    /// Rows using the `.intuosV3` report format.
    static let intuosV3: Table = [
        0x0100: [  // Wacom One S (CTC-4110WL)
            .penPosition: .init(.hardware, [.testerHardware, .openTabletDriver]),
            .pressure: .init(.hardware, [.testerHardware, .openTabletDriver]),
        ],
        0x0102: [  // Wacom One M (CTC-6110WL)
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
        ],
        0x0103: [  // Wacom One M (CTC-6110WL, Bluetooth)
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
        ],
        0x03F0: [  // Wacom Movink 13 (DTH-135)
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x03F5: [  // Intuos Pro S gen 3 (PTK-470)
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .bluetooth: .init(.sourced, [.libwacom]),
        ],
        0x03F7: [  // Intuos Pro M gen 3 (PTK-670)
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .bluetooth: .init(.sourced, [.libwacom]),
        ],
        0x03F9: [  // Intuos Pro L gen 3 (PTK-870)
            .penPosition: .init(.hardware, [.maintainerHardware, .openTabletDriver]),
            .pressure: .init(.hardware, [.maintainerHardware, .openTabletDriver]),
            .tabletButtons: .init(.hardware, [.maintainerHardware]),
            .dial: .init(.hardware, [.maintainerHardware]),
            .bluetooth: .init(.hardware, [.maintainerHardware, .libwacom]),
        ],
    ]
}
