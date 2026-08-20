import Foundation
import Testing
@testable import macbethd

@Test func actionTimeoutsAreBounded() {
    #expect(ActionTimeout.clamp(nil) == ActionTimeout.defaultSeconds)
    #expect(ActionTimeout.clamp(-10) == ActionTimeout.minSeconds)
    #expect(ActionTimeout.clamp(120) == 120)
    #expect(ActionTimeout.clamp(10_000) == ActionTimeout.maxSeconds)
    #expect(ActionTimeout.clamp(Double.infinity) == ActionTimeout.defaultSeconds)
}

@Test func sliderFillFailsWhenObservedValueMissesTarget() throws {
    try ensureSliderTargetReached(current: 10, target: 10)
    #expect(throws: RPCError.self) {
        try ensureSliderTargetReached(current: 100, target: 200)
    }
}

@Test func socketCleanupPreservesRegularFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("macbeth-socket-safety-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("important.txt")
    try Data("keep me".utf8).write(to: file)

    #expect(throws: ServerError.self) {
        try removeStaleSocketIfSafe(at: file.path)
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "keep me")
}

@Test func socketCleanupAcceptsAMissingPath() throws {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("macbeth-missing-socket-\(UUID().uuidString)")
    try removeStaleSocketIfSafe(at: missing.path)
}
