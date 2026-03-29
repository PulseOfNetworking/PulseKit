// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PulseKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8)
    ],
    products: [
        .library(name: "PulseKit",          targets: ["PulseKit"]),
        .library(name: "PulseKitUI",        targets: ["PulseKitUI"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PulseKit",
            dependencies: [],
            path: "Sources/PulseKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),          // core only — REST, plugins, cache
        .target(
            name: "PulseKitUI",
            dependencies: ["PulseKit"],
            path: "Sources/PulseKitUI"
        ),
    ]
)
