// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cheapshot",
    // macOS 13 is the CLI's floor and stays put. iOS 17 is for the app (cheapshot native app plan,
    // step 1): only CheapshotCore is meant to build there; the CLI targets are macOS only.
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "CheapshotCore", targets: ["CheapshotCore"]),
        .executable(name: "cheapshot", targets: ["cheapshot"]),
    ],
    targets: [
        .target(
            name: "CheapshotCore",
            // AppKit only on macOS: iOS has no AppKit. Core reaches it only behind `#if canImport(AppKit)`.
            linkerSettings: [.linkedFramework("Vision"), .linkedFramework("AppKit", .when(platforms: [.macOS])),
                             .linkedFramework("PDFKit")]
        ),
        .target(name: "CheapshotCLI", dependencies: ["CheapshotCore"]),
        .executableTarget(name: "cheapshot", dependencies: ["CheapshotCore", "CheapshotCLI"]),
        .testTarget(name: "CheapshotCoreTests", dependencies: ["CheapshotCore"], resources: [.copy("Golden")]),
        .testTarget(name: "CheapshotCLITests", dependencies: ["CheapshotCLI", "CheapshotCore"]),
    ]
)
