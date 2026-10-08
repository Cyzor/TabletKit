// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

extension WacomEvidence {
    /// Rows using the `.dtu` report format.
    static let dtu: Table = [
        0x003A: [  // DTI-520
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x00CE: [  // Wacom DTU-2231
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel]),
        ],
        0x00F0: [  // Wacom DTU-1631
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
    ]
}
