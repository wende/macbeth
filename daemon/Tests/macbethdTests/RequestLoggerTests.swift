import Testing
import Foundation
@testable import macbethd

// MARK: - Helpers

private func makeTempDir(prefix: String = "macbeth-log-test-") throws -> URL {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let dir = tmp.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeRecord(
    method: String? = "list_apps",
    requestID: String? = "1",
    paramsBytes: Int = 32,
    resultBytes: Int = 64,
    durationMs: Int = 1,
    ok: Bool = true,
    errorCode: Int? = nil,
    params: JSONValue? = nil,
    result: JSONValue? = nil
) -> RPCLogRecord {
    RPCLogRecord(
        ts: "2026-08-10T16:00:00.000Z",
        connectionID: "conn-test",
        requestID: requestID,
        method: method,
        paramsBytes: paramsBytes,
        resultBytes: resultBytes,
        durationMs: durationMs,
        ok: ok,
        errorCode: errorCode,
        paramsPreview: RPCPreviewBuilder.preview(of: params),
        resultPreview: RPCPreviewBuilder.preview(of: result)
    )
}

private func readNDJSON(in dir: URL, file: String = "requests.log") throws -> [RPCLogRecord] {
    let url = dir.appendingPathComponent(file)
    let contents = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    return contents
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { line in
            try? decoder.decode(RPCLogRecord.self, from: Data(line.utf8))
        }
}

// MARK: - Tests

@Test func writesNDJSONLinePerRecord() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let logger = try RequestLogger(directory: dir, maxFileBytes: 1024 * 1024, maxFiles: 5)

    await logger.log(makeRecord(method: "list_apps", requestID: "1"))
    await logger.log(makeRecord(method: "connect_app", requestID: "2"))
    await logger.log(makeRecord(method: "screenshot", requestID: "3"))

    let records = try readNDJSON(in: dir)
    #expect(records.count == 3)
    #expect(records.map(\.method) == ["list_apps", "connect_app", "screenshot"])
    #expect(records.map(\.requestID) == ["1", "2", "3"])
    #expect(records.allSatisfy { $0.connectionID == "conn-test" })
}

@Test func rotatesAtSizeCap() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Tiny cap — 1 KB. Each record ≈ 200 bytes; ~5 records force a rotation.
    let logger = try RequestLogger(directory: dir, maxFileBytes: 1024, maxFiles: 10)

    for i in 0..<20 {
        await logger.log(makeRecord(method: "spam_\(i)", paramsBytes: 256, resultBytes: 256))
    }

    let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    let rotated = entries.filter {
        let name = $0.lastPathComponent
        return name.hasPrefix("requests-") && name.hasSuffix(".log") && name != "requests.log"
    }
    #expect(!rotated.isEmpty, "expected at least one rotated file, got none in \(dir.path)")

    // Every line across every file must still parse.
    var totalParsed = 0
    for url in [dir.appendingPathComponent("requests.log")] + rotated {
        totalParsed += try readNDJSON(in: dir, file: url.lastPathComponent).count
    }
    #expect(totalParsed == 20)
}

@Test func evictsOldestRotatedFiles() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Cap of 3 rotated files. Force plenty of rotations.
    let logger = try RequestLogger(directory: dir, maxFileBytes: 256, maxFiles: 3)

    for i in 0..<30 {
        await logger.log(makeRecord(method: "spam_\(i)", paramsBytes: 200, resultBytes: 200))
    }

    let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    let rotated = entries
        .map(\.lastPathComponent)
        .filter { $0.hasPrefix("requests-") && $0.hasSuffix(".log") && $0 != "requests.log" }
        .sorted()
    #expect(rotated.count == 3, "expected 3 rotated files, got \(rotated.count): \(rotated)")
}

@Test func startupEvictionConverges() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Pre-populate 15 stale rotated files.
    for i in 0..<15 {
        let name = "requests-2026-08-10T16-00-\(String(format: "%02d", i)).log"
        try "stale\n".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let preCount = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("requests-") }.count
    #expect(preCount == 15)

    _ = try RequestLogger(directory: dir, maxFileBytes: 1024, maxFiles: 10)
    let postCount = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("requests-") }.count
    #expect(postCount == 10)
}

@Test func unwritableDirectoryDisablesLogging() throws {
    // Make the *parent* read-only so the init's createDirectory call fails.
    // Setting 0o500 on the dir itself doesn't help — POSIX permissions on a
    // directory don't restrict the owner from creating entries inside it.
    let parent = try makeTempDir(prefix: "macbeth-log-readonly-")
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)

    let blocked = parent.appendingPathComponent("cannot-create-here", isDirectory: true)
    #expect(throws: (any Error).self) {
        try RequestLogger(directory: blocked, maxFileBytes: 1024, maxFiles: 5)
    }
}

@Test func base64ScreenshotPlaceholder() {
    // Screenshot result: { data: <huge base64>, width: 3424, height: 2136, format: "png" }
    let big = String(repeating: "A", count: 2048)
    let result: JSONValue = .object([
        "data": .string(big),
        "width": .number(3424),
        "height": .number(2136),
        "format": .string("png"),
    ])

    let preview = RPCPreviewBuilder.preview(of: result)
    #expect(preview.contains("\"bytes\""), "expected bytes placeholder in preview, got: \(preview)")
    #expect(!preview.contains(big), "raw base64 must not appear in preview")
    #expect(preview.contains("\"width\""))
    #expect(preview.contains("3424"))
}

@Test func previewTruncatesLongString() {
    // A long string that *doesn't* look like base64 (has spaces and punctuation)
    // is still capped at the byte budget.
    let huge = String(repeating: "hello world! ", count: 500)
    let preview = RPCPreviewBuilder.preview(of: .string(huge), budget: 1024)
    #expect(preview.utf8.count <= 1024)
    #expect(preview.hasSuffix("..."))
}

@Test func previewEmptyAndNil() {
    #expect(RPCPreviewBuilder.preview(of: nil) == "")
    #expect(RPCPreviewBuilder.preview(of: .null) == "null")
}

@Test func parseFailureRecordShape() async throws {
    // What SocketServer emits on the parse-error branch: no method, no id, ok=false, errorCode=-32700.
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let logger = try RequestLogger(directory: dir, maxFileBytes: 1024 * 1024, maxFiles: 5)

    let record = makeRecord(
        method: nil,
        requestID: nil,
        paramsBytes: 12,
        resultBytes: 80,
        ok: false,
        errorCode: -32700
    )
    await logger.log(record)

    let parsed = try readNDJSON(in: dir)
    #expect(parsed.count == 1)
    let r = parsed[0]
    #expect(r.method == nil)
    #expect(r.requestID == nil)
    #expect(r.ok == false)
    #expect(r.errorCode == -32700)
    #expect(r.paramsBytes == 12)
}

@Test func encodeFailureRecordShape() async throws {
    // What SocketServer emits on the response-encoding-failure branch: the
    // client never received a response, but the audit record must still flag
    // the failure (ok=false, errorCode=-32603 internal error) so consumers
    // using `jq 'select(.ok == false)'` surface it.
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let logger = try RequestLogger(directory: dir, maxFileBytes: 1024 * 1024, maxFiles: 5)

    let record = makeRecord(
        method: "list_apps",
        requestID: "1",
        paramsBytes: 57,
        resultBytes: 0,
        ok: false,
        errorCode: -32603
    )
    await logger.log(record)

    let parsed = try readNDJSON(in: dir)
    #expect(parsed.count == 1)
    let r = parsed[0]
    #expect(r.method == "list_apps")
    #expect(r.requestID == "1")
    #expect(r.ok == false)
    #expect(r.errorCode == -32603)
    // Sanity-check that the encoder really would have thrown for the result
    // shape the SocketServer.encode branch would have built — pins the
    // scenario, not just the log shape.
    let unencodable: JSONValue = .number(.nan)
    do {
        _ = try JSONEncoder().encode(JSONRPCResponse(id: .number(1), result: .object(["data": unencodable])))
        #expect(Bool(false), "JSONEncoder unexpectedly accepted Double.nan")
    } catch {
        // expected
    }
}