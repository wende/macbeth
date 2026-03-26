// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacbethTestApp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MacbethTestApp",
            path: "Sources/MacbethTestApp"
        ),
    ]
)
