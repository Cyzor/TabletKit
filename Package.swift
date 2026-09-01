// swift-tools-version:5.9
//
// TabletKit — pure-logic Wacom (and vendor-neutral) HID decoder layer
// extracted from the MockTab macOS driver. MPL-2.0; see LICENSES/MPL-2.0.txt.
//
// The `Sources/TabletKit/` layout is canonical SwiftPM. Run from this repo's root:
//     swift test
//
// This package has no dependencies on purpose — a clone builds and tests with
// nothing to resolve. API documentation is built on demand by
// tools/build-docs.sh rather than by a SwiftPM docs plugin.
import PackageDescription

let package = Package(
    name: "TabletKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TabletKit", targets: ["TabletKit"]),
    ],
    targets: [
        .target(
            name: "TabletKit",
            // The catalog is built on demand by tools/build-docs.sh, which reads
            // it directly, so SwiftPM must not treat it as an unhandled resource.
            // Excluding it here is what keeps a plain `swift build` warning-free
            // with no dependency on swift-docc-plugin.
            exclude: ["TabletKit.docc"]
        ),
        .testTarget(
            name: "TabletKitTests",
            dependencies: ["TabletKit"]
        ),
        .executableTarget(
            name: "tablet-decode",
            dependencies: ["TabletKit"],
            path: "Samples/tablet-decode"
        ),
        .executableTarget(
            name: "descriptor-dump",
            dependencies: ["TabletKit"],
            path: "Samples/descriptor-dump"
        ),
        .executableTarget(
            name: "hid-trace-sweep",
            dependencies: ["TabletKit"],
            path: "Samples/hid-trace-sweep"
        ),
    ]
)
