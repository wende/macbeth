import Foundation

/// One NDJSON record per completed RPC call (including parse failures).
///
/// Lives in `~/Library/Caches/macbeth/logs/requests.log` and rotated siblings.
/// The actor at the bottom (`RequestLogger`) handles file IO; this struct is the
/// pure payload. Keep it `Sendable` so callers can hand it across the actor
/// boundary without re-encoding.
struct RPCLogRecord: Codable, Sendable {
    let ts: String            // ISO-8601 UTC with milliseconds
    let connectionID: String  // matches the connection scope used in Dispatcher
    let requestID: String?    // JSON-RPC id as string; nil on parse failure
    let method: String?       // nil when the request failed to parse
    let paramsBytes: Int      // UTF-8 byte count of raw incoming line
    let resultBytes: Int      // UTF-8 byte count of encoded response (0 on encode failure)
    let durationMs: Int       // wall time from read to encoded response
    let ok: Bool
    let errorCode: Int?       // JSON-RPC error code when ok == false
    let paramsPreview: String // truncated preview, base64 payloads replaced by {bytes: N}
    let resultPreview: String // truncated preview, base64 payloads replaced by {bytes: N}

    // Default Codable synthesis drops Optional keys when they're nil. Keep them
    // visible — `method: null` distinguishes "the request failed to parse" from
    // "the parser produced a method we forgot to write", and `errorCode: null`
    // says "ok=true" without ambiguity. Same line shape for every record means
    // downstream `jq` queries don't need to branch on key presence.
    private enum CodingKeys: String, CodingKey {
        case ts, connectionID, requestID, method, paramsBytes, resultBytes
        case durationMs, ok, errorCode, paramsPreview, resultPreview
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts)
        try c.encode(connectionID, forKey: .connectionID)
        try c.encode(requestID, forKey: .requestID)
        try c.encode(method, forKey: .method)
        try c.encode(paramsBytes, forKey: .paramsBytes)
        try c.encode(resultBytes, forKey: .resultBytes)
        try c.encode(durationMs, forKey: .durationMs)
        try c.encode(ok, forKey: .ok)
        try c.encode(errorCode, forKey: .errorCode)
        try c.encode(paramsPreview, forKey: .paramsPreview)
        try c.encode(resultPreview, forKey: .resultPreview)
    }
}

/// Persistent, rotated NDJSON audit log of every RPC call.
///
/// Single writer — only one daemon process exists per user (the Unix socket path
/// enforces that), so there is no inter-process contention. The actor serializes
/// appends and rotation decisions without locks.
///
/// Failures are swallowed. A logging error must never surface as an RPC error —
/// that would break the contract codified in `docs/error-codes.md`.
actor RequestLogger {
    private let directory: URL
    private let maxFileBytes: Int
    private let maxFiles: Int
    private let activeFile: URL
    private let fileManager = FileManager.default
    private var droppedRecords = 0
    private var lastDropWarning: Date = .distantPast

    private static let previewByteBudget = 1024
    private static let dropWarningIntervalSeconds: TimeInterval = 60

    /// The default base directory under the user's Caches root.
    /// Daemon has no bundle identifier, so we use the literal `macbeth/`.
    static func defaultDirectory() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return caches.appendingPathComponent("macbeth/logs", isDirectory: true)
    }

    init(directory: URL, maxFileBytes: Int, maxFiles: Int) throws {
        precondition(maxFileBytes > 0, "maxFileBytes must be positive")
        precondition(maxFiles >= 0, "maxFiles must be non-negative")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
        self.activeFile = directory.appendingPathComponent("requests.log")
        // Eviction uses self — but init runs before actor isolation is set up,
        // so call the nonisolated version here. After init, actor isolation
        // kicks in and subsequent calls route through the isolated method.
        Self.evictStaleRotatedFiles(in: directory, keeping: maxFiles)
    }

    /// Fire-and-forget from the caller's perspective. Callers should `Task { await
    /// logger.log(rec) }` and not await.
    func log(_ record: RPCLogRecord) {
        do {
            try appendRecord(record)
        } catch {
            recordDrop()
        }
    }

    // MARK: - Internals

    private func appendRecord(_ record: RPCLogRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(record)
        guard var line = String(data: data, encoding: .utf8) else {
            throw RequestLoggerError.encodingFailed
        }
        line.append("\n")

        let currentSize = (try? fileManager.attributesOfItem(atPath: activeFile.path)[.size] as? Int) ?? 0
        if currentSize > 0 && currentSize + line.utf8.count > maxFileBytes {
            try rotate()
        }

        // Open for writing — `FileHandle(forWritingTo:)` requires the file to
        // exist; if rotation just renamed it away, the active file may be new.
        if !fileManager.fileExists(atPath: activeFile.path) {
            fileManager.createFile(atPath: activeFile.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: activeFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        evictStaleRotatedFiles()
    }

    private func rotate() throws {
        // If no active file exists yet, nothing to rotate.
        guard fileManager.fileExists(atPath: activeFile.path) else { return }

        let stamp = Self.rotationTimestamp()
        let rotated = directory.appendingPathComponent("requests-\(stamp).log")
        // If a rotation timestamp collides (sub-second rotations), append a counter.
        var unique = rotated
        var n = 1
        while fileManager.fileExists(atPath: unique.path) {
            unique = directory.appendingPathComponent("requests-\(stamp)-\(n).log")
            n += 1
        }
        try fileManager.moveItem(at: activeFile, to: unique)
        // appendRecord will lazily create the active file when the next record arrives.
    }

    private func evictStaleRotatedFiles() {
        Self.evictStaleRotatedFiles(in: directory, keeping: maxFiles)
    }

    /// Nonisolated so the actor's `init` can call it before isolation is set up,
    /// and so it's safe to call from any context. Pure file IO on a temp dir.
    private static func evictStaleRotatedFiles(in directory: URL, keeping maxFiles: Int) {
        guard maxFiles >= 0 else { return }
        let prefix = "requests-"
        let suffix = ".log"
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        let rotated = entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(suffix) }
            .filter { $0.lastPathComponent != "requests.log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let excess = rotated.count - maxFiles
        guard excess > 0 else { return }
        for url in rotated.prefix(excess) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func recordDrop() {
        droppedRecords += 1
        let now = Date()
        if now.timeIntervalSince(lastDropWarning) > Self.dropWarningIntervalSeconds {
            lastDropWarning = now
            // fputs to stderr unconditionally — these are user-visible even with
            // --verbose off so a misconfigured log dir doesn't fail silently.
            // Rate-limited by `dropWarningIntervalSeconds` (60s default).
            FileHandle.standardError.write(Data(
                "[request-log] dropped \(droppedRecords) record(s) since startup (check log dir permissions)\n".utf8
            ))
        }
    }

    private static func rotationTimestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        // Replace colons with hyphens — Unix filenames
        return f.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}

enum RequestLoggerError: Error {
    case encodingFailed
}

// MARK: - Preview helpers

enum RPCPreviewBuilder {
    /// Build a truncated preview of a JSON value. The string is capped at
    /// `RPCLogRecord`'s preview budget (~1024 bytes). Base64 payloads (e.g. the
    /// `data` field on a screenshot result) are replaced by `{bytes: N}` before
    /// truncation so a screenshot call doesn't turn the log into megabytes of
    /// base64.
    ///
    /// Note: previews preserve plain-text fields like `fill.value` and
    /// `extract_text` results unchanged. Tool calls with sensitive content
    /// already leave the local box through cloud-backed agents — keeping the
    /// local audit log faithful to what was actually sent is a deliberate
    /// decision over a per-method redaction table. See PR #45 review.
    static func preview(of value: JSONValue?, budget: Int = 1024) -> String {
        guard let value else { return "" }
        let sanitized = redactBase64(in: value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(sanitized),
              let s = String(data: data, encoding: .utf8) else {
            return ""
        }
        return truncate(s, byteBudget: budget)
    }

    /// Recursively walk the value; if a string field is a long base64-looking
    /// blob (>=256 chars of base64 alphabet), replace it with `{bytes: N}`.
    private static func redactBase64(in value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s):
            if s.count >= 256, looksLikeBase64(s) {
                return .object(["bytes": .number(Double(s.utf8.count))])
            }
            return value
        case .array(let arr):
            return .array(arr.map(redactBase64))
        case .object(let obj):
            var out: [String: JSONValue] = [:]
            for (k, v) in obj {
                // The screenshot method's `data` field is the canonical case.
                if k == "data", case .string(let s) = v, s.count >= 256, looksLikeBase64(s) {
                    out[k] = .object(["bytes": .number(Double(s.utf8.count))])
                } else {
                    out[k] = redactBase64(in: v)
                }
            }
            return .object(out)
        default:
            return value
        }
    }

    private static let base64Alphabet = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")

    private static func looksLikeBase64(_ s: String) -> Bool {
        // Sample at most the first 64 chars to keep this cheap.
        let sample = s.prefix(64)
        return !sample.isEmpty && sample.unicodeScalars.allSatisfy { base64Alphabet.contains($0) }
    }

    /// Truncate a string so its UTF-8 byte length is `<= budget`. If a truncation
    /// falls inside a multi-byte character, walk back to the previous Unicode
    /// scalar boundary so the result remains valid UTF-8, then append an ellipsis.
    private static func truncate(_ s: String, byteBudget: Int) -> String {
        if s.utf8.count <= byteBudget { return s }
        let ellipsis = "..."
        let budgetMinusEllipsis = byteBudget - ellipsis.utf8.count
        guard budgetMinusEllipsis > 0 else { return ellipsis }

        // Take the first `budgetMinusEllipsis` bytes by walking Unicode scalars
        // until adding the next one would exceed the byte budget.
        var cutBytes = 0
        var cutScalars: [Unicode.Scalar] = []
        var truncated = false
        for scalar in s.unicodeScalars {
            let bytes = scalar.utf8.count
            if cutBytes + bytes > budgetMinusEllipsis {
                truncated = true
                break
            }
            cutBytes += bytes
            cutScalars.append(scalar)
        }
        var cut = String(String.UnicodeScalarView(cutScalars))
        if truncated { cut += ellipsis }
        return cut
    }
}

// MARK: - JSONRPCId convenience used by SocketServer

extension JSONRPCId {
    /// Render this id as a string for logging. Matches the shape JSONEncoder
    /// would emit (Int for whole numbers, Double otherwise).
    var requestIDString: String {
        switch self {
        case .string(let s): return s
        case .number(let n):
            if let asInt = Int(exactly: n) {
                return String(asInt)
            }
            return String(n)
        }
    }
}