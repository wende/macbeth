// swift-tools-version: 6.0
//
// Minimal CI test harness for the Macbeth GitHub Actions prototype.
// Designed to expose only what the end-to-end test needs:
//   - A single, predictable NSWindow with a known title.
//   - One NSTextField with a known initial value and AX identifier.
//   - One NSButton whose action updates the status label.
//   - One NSTextField acting as the "status label" with a known AX identifier.

import PackageDescription

let package = Package(
    name: "MacbethCIHarness",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MacbethCIHarness",
            path: "Sources/MacbethCIHarness"
        ),
    ]
)