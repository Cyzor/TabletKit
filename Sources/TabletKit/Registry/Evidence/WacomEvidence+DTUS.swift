// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

extension WacomEvidence {
    /// Rows using the `.dtus` report format.
    static let dtus: Table = [
        0x00FB: [  // Wacom DTU-1031
            .penPosition: .init(.recorded, [.publicRecording, .linuxKernel]),
            .pressure: .init(.recorded, [.publicRecording, .linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x032F: [  // Wacom DTU-1031X
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
        ],
        0x0336: [  // Wacom DTU-1141
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
        0x0343: [  // Wacom DTK1651
            .penPosition: .init(.sourced, [.linuxKernel]),
            .pressure: .init(.sourced, [.linuxKernel]),
            .tabletButtons: .init(.sourced, [.libwacom]),
        ],
    ]
}
