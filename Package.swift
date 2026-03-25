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
        // Core networking engine
        .library(
            name: "PulseKit",
            targets: ["PulseKit"]
        ),
        // Optional SwiftUI debug UI layer
        .library(
            name: "PulseKitUI",
            targets: ["PulseKitUI"]
        )
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
        ),
        .target(
            name: "PulseKitUI",
            dependencies: ["PulseKit"],
            path: "Sources/PulseKitUI"
        ),
        .testTarget(
            name: "PulseKitTests",
            dependencies: ["PulseKit"],
            path: "Tests/PulseKitTests"
        )
    ]
)
