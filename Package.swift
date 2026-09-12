// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cheapshot",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CheapshotCore", targets: ["CheapshotCore"]),
        .executable(name: "cheapshot", targets: ["cheapshot"]),
    ],
    targets: [
        .target(
            name: "CheapshotCore",
            linkerSettings: [.linkedFramework("Vision"), .linkedFramework("AppKit")]
        ),
        .target(name: "CheapshotCLI", dependencies: ["CheapshotCore"]),
        .executableTarget(name: "cheapshot", dependencies: ["CheapshotCore", "CheapshotCLI"]),
        .testTarget(name: "CheapshotCoreTests", dependencies: ["CheapshotCore"], resources: [.copy("Golden")]),
        .testTarget(name: "CheapshotCLITests", dependencies: ["CheapshotCLI", "CheapshotCore"]),
    ]
)
