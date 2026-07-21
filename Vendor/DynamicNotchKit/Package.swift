// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// AgentShelf: vendored fork of MrKai77/DynamicNotchKit @ 1.1.0. The see-through Liquid Glass
// patch (Views/NotchView.swift, Views/NotchlessView.swift) was reverted back to an opaque black
// fill, so this no longer needs the macOS 26 .glassEffect API. The swift-docc-plugin dependency
// was dropped so builds stay offline-self-contained.

import PackageDescription

let package = Package(
    name: "DynamicNotchKit",
    platforms: [
        .macOS(.v14)
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
