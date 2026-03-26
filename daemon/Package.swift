// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "macbethd",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "macbethd",
            path: "Sources/macbethd"
        ),
        .testTarget(
            name: "macbethdTests",
            dependencies: ["macbethd"],
            path: "Tests/macbethdTests"
        ),
    ]
)
