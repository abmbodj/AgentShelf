// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentShelf",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.1.0"),
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
