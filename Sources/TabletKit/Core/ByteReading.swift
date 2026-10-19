// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

/// Multi-byte field reads shared by the decoders, so each field names its
/// byte order instead of spelling out the shifts.
package protocol ByteReadable {
    func byte(at index: Int) -> UInt8
}

extension ByteReadable {
    /// Little-endian unsigned 16-bit value at `index` and `index + 1`.
    package func le16(at index: Int) -> Int {
        Int(byte(at: index)) | Int(byte(at: index + 1)) << 8
    }

    /// Big-endian unsigned 16-bit value at `index` and `index + 1`.
    package func be16(at index: Int) -> Int {
        Int(byte(at: index)) << 8 | Int(byte(at: index + 1))
    }

    /// Little-endian unsigned 24-bit value at `index` through `index + 2`.
    package func le24(at index: Int) -> Int {
        le16(at: index) | Int(byte(at: index + 2)) << 16
    }

    /// Little-endian unsigned 32-bit value at `index` through `index + 3`.
    package func le32(at index: Int) -> UInt32 {
        UInt32(le16(at: index) | le16(at: index + 2) << 16)
    }

    /// Little-endian signed 16-bit value at `index` and `index + 1`.
    package func signedLE16(at index: Int) -> Int {
        Int(Int16(truncatingIfNeeded: le16(at: index)))
    }
}

extension HIDReport: ByteReadable {
    package func byte(at index: Int) -> UInt8 { self[index] }
}

extension UnsafePointer: ByteReadable where Pointee == UInt8 {
    package func byte(at index: Int) -> UInt8 { self[index] }
}

extension Array: ByteReadable where Element == UInt8 {
    package func byte(at index: Int) -> UInt8 { self[index] }
}
