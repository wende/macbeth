import Foundation
import Testing
@testable import macbethd

@Test func detectsStandardElectronFramework() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("macbeth-runtime-\(UUID().uuidString)", isDirectory: true)
    let framework = root.appendingPathComponent(
        "Contents/Frameworks/Electron Framework.framework",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(detectRuntime(
        bundleURL: root,
        bundleIdentifier: "example.app",
        infoDictionary: [:]
    ) == .electron)
}

@Test func detectsBrandedElectronFromAsarIntegrity() {
    #expect(detectRuntime(
        bundleURL: nil,
        bundleIdentifier: "com.openai.codex",
        infoDictionary: [
            "ElectronAsarIntegrity": [
                "Resources/app.asar": ["algorithm": "SHA256"]
            ],
            "ChromiumBaseVersion": "150.0.7871.124",
        ]
    ) == .electron)
}

@Test func leavesUnmarkedNativeBundleNative() {
    #expect(detectRuntime(
        bundleURL: nil,
        bundleIdentifier: "com.apple.TextEdit",
        infoDictionary: [:]
    ) == .native)
}
