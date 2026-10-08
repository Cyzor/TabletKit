// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

extension WacomEvidence {
    /// Rows using the `.intuosV2` report format.
    static let intuosV2: Table = [
        0x034D: [  // Wacom MobileStudio Pro 13 (DTH-W1320)
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x034E: [  // Wacom MobileStudio Pro 16 (DTH-W1620)
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x034F: [  // Wacom DTH-1320
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x0350: [  // Wacom Cintiq Pro 16 (DTH-1620)
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x0351: [  // Cintiq Pro 24 (DTH-2420, touch)
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x0352: [  // Cintiq Pro 32 (DTH-3220)
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x0357: [  // Intuos Pro M (PTH-660)
            .penPosition: .init(.hardware, [.maintainerHardware, .openTabletDriver]),
            .pressure: .init(.hardware, [.maintainerHardware, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.hardware, [.maintainerHardware, .libwacom]),
            .bluetooth: .init(.hardware, [.maintainerHardware, .libwacom]),
        ],
        0x0358: [  // Intuos Pro L (PTH-860)
            .penPosition: .init(.hardware, [.maintainerHardware, .openTabletDriver]),
            .pressure: .init(.hardware, [.maintainerHardware, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.hardware, [.maintainerHardware, .libwacom]),
            .bluetooth: .init(.hardware, [.maintainerHardware, .libwacom]),
        ],
        0x0359: [  // DTU-1141B
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x035A: [  // DTH-1152
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x0360: [  // Wacom PTH-660
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
            .bluetooth: .init(.sourced, [.libwacom]),
        ],
        0x0361: [  // Intuos Pro L (PTH-860) BT
            .penPosition: .init(.hardware, [.maintainerHardware, .linuxKernel]),
            .pressure: .init(.hardware, [.maintainerHardware, .linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.hardware, [.maintainerHardware, .libwacom]),
            .bluetooth: .init(.sourced, [.libwacom]),
        ],
        0x0374: [  // Wacom CTL-4100
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x0375: [  // Wacom CTL-6100
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x0376: [  // Wacom CTL-4100WL
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .bluetooth: .init(.sourced, [.libwacom]),
        ],
        0x0377: [  // Wacom CTL-4100WL
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x0378: [  // Wacom CTL-6100WL
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .bluetooth: .init(.sourced, [.libwacom]),
        ],
        0x0379: [  // Wacom Intuos BT M (CTL-6100WL)
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x037D: [  // DTH-2452
            .tabletButtons: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x0390: [  // Wacom Cintiq 16 (DTK-1660)
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
        ],
        0x0392: [  // Intuos Pro S (PTH-460)
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
            .bluetooth: .init(.sourced, [.libwacom]),
        ],
        0x0398: [  // Wacom MobileStudio Pro 13 (DTH-W1321)
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x0399: [  // Wacom MobileStudio Pro 16 (DTH-W1621)
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x03A6: [  // Wacom DTC-133
            .penPosition: .init(.sourced, [.openTabletDriver, .descriptorCorpus]),
            .pressure: .init(.sourced, [.openTabletDriver, .descriptorCorpus]),
        ],
        0x03AA: [  // Wacom MobileStudio Pro 16 (DTH-W1620, alt)
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x03AE: [  // Wacom Cintiq 16 (DTK-1660)
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
        ],
        0x03B2: [  // Cintiq Pro 16 (DTH-167)
            .penPosition: .init(.hardware, [.testerHardware]),
            .pressure: .init(.hardware, [.testerHardware]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .touch: .init(.hardware, [.testerHardware, .libwacom]),
        ],
        0x03B3: [  // Cintiq Pro 16 Touch sensor (pairs 0x03B2)
            .touch: .init(.hardware, [.testerHardware]),
        ],
        0x03C0: [  // Wacom Cintiq Pro 27 (DTH-271)
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x03C4: [  // Wacom Cintiq Pro 17 (DTH172)
            .tabletButtons: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x03C5: [  // Wacom CTL-4100WL
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x03C6: [  // Wacom CTL-4100WL
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x03C7: [  // Wacom CTL-6100WL
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x03C8: [  // Wacom CTL-6100WL
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x03CB: [  // Wacom One Pen Display 13 (DTH134)
            .penPosition: .init(.sourced, [.descriptorCorpus]),
            .pressure: .init(.sourced, [.descriptorCorpus]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x03CE: [  // Wacom One Pen Display 12 (DTC-121)
            .penPosition: .init(.sourced, [.openTabletDriver, .descriptorCorpus]),
            .pressure: .init(.sourced, [.openTabletDriver, .descriptorCorpus]),
        ],
        0x03D0: [  // Wacom Cintiq Pro 22 (DTH-227)
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x03DC: [  // Intuos Pro S (PTH-460)
            .penPosition: .init(.sourced, [.openTabletDriver]),
            .pressure: .init(.sourced, [.openTabletDriver]),
            .tabletButtons: .init(.sourced, [.libwacom]),
            .ring: .init(.sourced, [.libwacom]),
            .touch: .init(.sourced, [.libwacom]),
            .bluetooth: .init(.sourced, [.libwacom]),
        ],
        0x03EC: [  // Wacom DTH134
            .penPosition: .init(.sourced, [.descriptorCorpus]),
            .pressure: .init(.sourced, [.descriptorCorpus]),
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x03ED: [  // Wacom DTC121
            .penPosition: .init(.sourced, [.descriptorCorpus]),
            .pressure: .init(.sourced, [.descriptorCorpus]),
        ],
        0x03FD: [  // Wacom Cintiq 24 Touch (DTH246)
            .touch: .init(.sourced, [.libwacom]),
        ],
        0x03FF: [  // DTH-246E
            .touch: .init(.sourced, [.libwacom]),
        ],
    ]
}
