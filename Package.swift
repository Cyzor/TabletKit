// swift-tools-version:5.9
//
// TabletKit — pure-logic Wacom (and vendor-neutral) HID decoder layer
// extracted from the MockTab macOS driver. MPL-2.0; see LICENSES/MPL-2.0.txt.
//
// The `Sources/TabletKit/` layout is canonical SwiftPM. Run from this repo's root:
//     swift test
import PackageDescription

let package = Package(
    name: "TabletKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TabletKit", targets: ["TabletKit"]),
    ],
    targets: [
        .target(name: "TabletKit"),
        .testTarget(
            name: "TabletKitTests",
            dependencies: ["TabletKit"]
        ),
        .executableTarget(
            name: "tablet-decode",
            dependencies: ["TabletKit"],
            path: "Samples/tablet-decode"
        ),
    ]
)
