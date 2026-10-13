// swift-tools-version: 6.0
import PackageDescription

// SwiftPM scaffold. Xcode can open this Package.swift directly.
// `project.yml` (XcodeGen) generates the real .app/.xpc .xcodeproj with
// entitlements once week 4 needs the sandbox + XPC targets.
//
// Language mode is pinned to v5 on purpose: the scaffold targets a green
// `swift build` first. Flipping to Swift 6 strict concurrency is a
// deliberate, separate task once the surface is stable.
//
// NOTE: the XPC *service* itself cannot be a SwiftPM target (it must be a
// bundle with its own Info.plist and entitlements) - that lives in project.yml.
// What SwiftPM builds here is the testable download core the service wraps.
let package = Package(
    name: "GrammarBar",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GrammarBarCore", targets: ["GrammarBarCore"]),
        .library(name: "GrammarDownloaderCore", targets: ["GrammarDownloaderCore"]),
        .executable(name: "GrammarBar", targets: ["GrammarBar"]),
        .executable(name: "GrammarBarEval", targets: ["GrammarBarEval"]),
    ],
    targets: [
        .target(name: "GrammarBarCore"),
        .target(name: "GrammarDownloaderCore"),
        .executableTarget(name: "GrammarBar", dependencies: ["GrammarBarCore"]),
        .executableTarget(name: "GrammarBarEval", dependencies: ["GrammarBarCore"]),
        .testTarget(name: "GrammarBarCoreTests", dependencies: ["GrammarBarCore"]),
        .testTarget(name: "GrammarDownloaderCoreTests", dependencies: ["GrammarDownloaderCore"]),
    ],
    swiftLanguageModes: [.v5]
)
