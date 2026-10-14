// SPDX-License-Identifier: MPL-2.0
//
// Recordings that hold pen and hardware serials stay out of the repo. Point
// TABLETKIT_RECORDINGS at a folder of report traces (trace-*.jsonl) and
// MockTab captures (.zip), searched recursively; tests that need them skip
// without it.
import Foundation

enum PrivateRecordings {
    static var root: URL? {
        ProcessInfo.processInfo.environment["TABLETKIT_RECORDINGS"].map { URL(fileURLWithPath: $0) }
    }

    static var traces: [URL] { files("jsonl").filter { $0.lastPathComponent.hasPrefix("trace-") } }
    static var captures: [URL] { files("zip") }

    private static func files(_ pathExtension: String) -> [URL] {
        guard let root else { return [] }
        return (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == pathExtension }
            .sorted { $0.path < $1.path }
    }
}
