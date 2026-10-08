// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

extension WacomEvidence {
    /// Rows using the `.pl` report format.
    static let pl: Table = [
        0x0030: [  // PL400
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x0031: [  // PL500
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x0032: [  // PL600
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x0033: [  // PL600SX
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x0034: [  // PL550 (Cintiq 15X)
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x0035: [  // PL800 (Cintiq 18SX)
            .penPosition: .init(.sourced, [.linuxKernel, .openTabletDriver]),
            .pressure: .init(.sourced, [.linuxKernel, .openTabletDriver]),
        ],
        0x0037: [  // PL700
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x0038: [  // PL510
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x0039: [  // DTU-710
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x00C0: [  // DTF-720
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x00C2: [  // DTF-720a
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x00C4: [  // DTF-521
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x00C7: [  // DTU-1931
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
    ]
}
