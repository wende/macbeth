// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "macbethd",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Shared, AppKit-free IPC types + debounce logic used by both the daemon
        // and the glow helper (and directly unit-tested).
        .target(
            name: "GlowProtocol",
            path: "Sources/GlowProtocol"
        ),
        .executableTarget(
            name: "macbethd",
            dependencies: ["GlowProtocol"],
            path: "Sources/macbethd"
        ),
        // Lightweight AppKit helper that renders the screen-edge glow overlay.
        .executableTarget(
            name: "macbeth-glow",
            dependencies: ["GlowProtocol"],
            path: "Sources/macbeth-glow"
        ),
        .testTarget(
            name: "macbethdTests",
            dependencies: ["macbethd", "GlowProtocol"],
            path: "Tests/macbethdTests"
        ),
    ]
)
