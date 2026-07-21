// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentShelf",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Vendored + patched (see-through Liquid Glass background) — Vendor/DynamicNotchKit.
        .package(path: "Vendor/DynamicNotchKit"),
    ],
    targets: [
        .target(name: "AgentShelfCore"),
        .executableTarget(
            name: "agentshelf-hook",
            dependencies: ["AgentShelfCore"]
        ),
        .executableTarget(
            name: "agentshelf-setup",
            dependencies: ["AgentShelfCore"]
        ),
        .executableTarget(
            name: "AgentShelfApp",
            dependencies: [
                "AgentShelfCore",
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
            ]
        ),
        .testTarget(
            name: "AgentShelfCoreTests",
            dependencies: ["AgentShelfCore"]
        ),
    ]
)
