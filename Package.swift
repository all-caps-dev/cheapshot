// swift-tools-version:5.9
import PackageDescription

// Platform-neutral code (redaction rules, layout, token counting, ledger) lives in
// CheapshotPortable, which imports Foundation only. CheapshotCore holds the Apple-framework
// parts (Vision OCR, PDFKit, ImageIO, AppKit/UIKit) and re-exports CheapshotPortable, so code
// that says `import CheapshotCore` sees the same API as before the split.

// Swift (manifest): the targets every platform builds.
var targets: [Target] = [
    .target(name: "CheapshotPortable"),
    .testTarget(name: "CheapshotPortableTests", dependencies: ["CheapshotPortable"], resources: [.copy("Golden")]),
]
var products: [Product] = [
    .library(name: "CheapshotPortable", targets: ["CheapshotPortable"]),
]

#if !os(Windows)
// Apple-only targets. Left out of the manifest on Windows so `swift build` and `swift test`
// there only see the portable target (the Windows CI job; cheapshot Windows investigation,
// section 7, "first step").
targets += [
    .target(
        name: "CheapshotCore",
        dependencies: ["CheapshotPortable"],
        // AppKit only on macOS: iOS has no AppKit. Core reaches it only behind `#if canImport(AppKit)`.
        linkerSettings: [.linkedFramework("Vision"), .linkedFramework("AppKit", .when(platforms: [.macOS])),
                         .linkedFramework("PDFKit")]
    ),
    .target(name: "CheapshotCLI", dependencies: ["CheapshotCore"]),
    .executableTarget(name: "cheapshot", dependencies: ["CheapshotCore", "CheapshotCLI"]),
    .testTarget(name: "CheapshotCoreTests", dependencies: ["CheapshotCore"]),
    .testTarget(name: "CheapshotCLITests", dependencies: ["CheapshotCLI", "CheapshotCore"]),
]
products += [
    .library(name: "CheapshotCore", targets: ["CheapshotCore"]),
    .executable(name: "cheapshot", targets: ["cheapshot"]),
]
#endif

let package = Package(
    name: "cheapshot",
    // macOS 13 is the CLI's floor and stays put. iOS 17 is for the app (cheapshot native app plan,
    // step 1): only CheapshotCore is meant to build there; the CLI targets are macOS only.
    // Windows has no entry here: SwiftPM has no Windows platform version to set.
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: products,
    targets: targets
)
