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
        .executableTarget(name: "cheapshot", dependencies: ["CheapshotCore"]),
        .testTarget(name: "CheapshotCoreTests", dependencies: ["CheapshotCore"], resources: [.copy("Golden")]),
    ]
)
