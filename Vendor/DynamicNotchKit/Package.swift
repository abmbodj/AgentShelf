// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// AgentShelf: vendored fork of MrKai77/DynamicNotchKit @ 1.1.0. Patched so the notch panel
// renders see-through Liquid Glass instead of an opaque black fill (Views/NotchView.swift,
// Views/NotchlessView.swift). Platform bumped to macOS 26 for the .glassEffect API; the
// swift-docc-plugin dependency was dropped so builds stay offline-self-contained.

import PackageDescription

let package = Package(
    name: "DynamicNotchKit",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "DynamicNotchKit",
            targets: ["DynamicNotchKit"]
        )
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "DynamicNotchKit",
            path: "Sources"
        ),
        .testTarget(
            name: "DynamicNotchKitTests",
            dependencies: ["DynamicNotchKit"]
        )
    ]
)
