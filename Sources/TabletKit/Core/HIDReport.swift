/// One raw HID input report, borrowed for the duration of a decode call.
///
/// Wraps the buffer the IOKit input-report callback delivers, including the
/// leading report-ID byte, so `report[n]` reads the same byte as the raw
/// pointer did. The buffer belongs to the caller: do not keep an `HIDReport`
/// after the call that received it returns. That is also why it is not
/// `Sendable`.
public struct HIDReport {
    /// Pointer to the first byte of the report, the report ID.
    public let pointer: UnsafePointer<UInt8>
    /// Number of valid bytes at `pointer`, including the report-ID byte.
    public let count: Int

    /// Wraps `count` bytes at `pointer`, as delivered by IOKit.
    public init(pointer: UnsafePointer<UInt8>, count: Int) {
        self.pointer = pointer
        self.count = count
    }

    /// The report ID, or 0 for an empty report.
    public var reportID: UInt8 { count > 0 ? pointer[0] : 0 }

    /// The byte at `index`, counting the report-ID byte as index 0.
    public subscript(index: Int) -> UInt8 { pointer[index] }

    /// Calls `body` with a report borrowing `bytes`.
    public static func withReport<R>(
        _ bytes: [UInt8],
        _ body: (HIDReport) throws -> R
    ) rethrows -> R {
        try bytes.withUnsafeBufferPointer { buffer in
            // A non-nil base is needed even for an empty array; count 0 keeps it unread.
            try withUnsafePointer(to: 0 as UInt8) { empty in
                try body(HIDReport(pointer: buffer.baseAddress ?? empty, count: buffer.count))
            }
        }
    }
}
