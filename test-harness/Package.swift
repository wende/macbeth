// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacbethTestHarness",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacbethTestApp",
            path: "Sources/MacbethTestApp"
        ),
    ]
)
