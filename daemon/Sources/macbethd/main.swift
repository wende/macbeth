import AppKit
import Foundation
import GlowProtocol

// MARK: - Early argument parsing for --check-permissions
//
// This flag is handled before any side effects (NSApplication.shared, socket
// creation) so CI scripts can probe permissions without triggering a window
// server connection.

for arg in CommandLine.arguments.dropFirst() {
    if arg == "--check-permissions" {
        runPermissionsCheck()
    }
}

// Initialize NSApplication so CoreGraphics/ScreenCaptureKit can connect to the window server.
// Without this, CGS_REQUIRE_INIT asserts on screenshot capture.
let _ = NSApplication.shared

// The glow helper communicates over a pipe; a dead reader must surface as a
// thrown EPIPE (handled in GlowIndicator), never a process-killing signal.
signal(SIGPIPE, SIG_IGN)

// MARK: - Argument parsing

var socketPath: String?
var verbose = false
var glowDisabled = false
var noLog = false
var logDir: String?
var logMaxFileMB: Int?
var logMaxFiles: Int?

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--socket-path":
        socketPath = args.next()
    case "--verbose", "-v":
        verbose = true
    case "--no-glow":
        glowDisabled = true
    case "--no-log":
        noLog = true
    case "--log-dir":
        logDir = args.next()
    case "--log-max-file-mb":
        if let v = args.next(), let n = Int(v) { logMaxFileMB = n }
    case "--log-max-files":
        if let v = args.next(), let n = Int(v) { logMaxFiles = n }
    case "--check-permissions":
        // Already handled above; skip silently.
        continue
    case "--help", "-h":
        fputs("""
        Usage: macbethd [options]

        Options:
          --socket-path <path>  Unix socket path (default: $TMPDIR/macbeth-<uid>.sock)
          --verbose, -v         Enable verbose logging
          --no-glow             Disable window interaction overlays
          --no-log              Disable persistent RPC request/response audit log
          --log-dir <path>      Override audit log directory (default: $Caches/macbeth/logs)
          --log-max-file-mb <n> Rotate the audit log when it exceeds N megabytes (default 5)
          --log-max-files <n>   Keep at most N rotated audit log files (default 10)
          --check-permissions   Print Accessibility + Screen Recording status, then exit
          --help, -h            Show this help

        Environment variables (CLI flags take precedence):
          MACBETH_NO_LOG              1|true|yes|on to disable the audit log
          MACBETH_LOG_DIR             audit log directory
          MACBETH_LOG_MAX_FILE_MB     per-file size cap before rotation
          MACBETH_LOG_MAX_FILES       maximum number of rotated files to keep

        """, stderr)
        exit(0)
    default:
        fputs("Unknown argument: \(arg)\n", stderr)
        exit(1)
    }
}

// Publish the verbose flag for module-wide diagnostic logging.
verboseLogging = verbose

// Default socket path
let resolvedSocketPath = socketPath
    ?? ProcessInfo.processInfo.environment["TMPDIR"].map { "\($0)macbeth-\(getuid()).sock" }
    ?? "/tmp/macbeth-\(getuid()).sock"

// MARK: - Permission check

if !checkAccessibilityPermissions(prompt: true) {
    printPermissionGuidance()
    fputs("\nStarting anyway — some operations may fail without permissions.\n\n", stderr)
}

// MARK: - Glow indicator configuration

// Environment overrides (CLI --no-glow takes precedence):
//   MACBETH_GLOW=0|false|off       disable the indicator
//   MACBETH_GLOW_COLOR=#RRGGBB     accent color (default #8B3342)
//   MACBETH_GLOW_DEBOUNCE_MS=<int> refreshable highlight hold (default 400)
//   MACBETH_GLOW_HELPER=<path>     explicit path to the macbeth-glow binary
let env = ProcessInfo.processInfo.environment
func envDisablesGlow() -> Bool {
    guard let raw = env["MACBETH_GLOW"]?.lowercased() else { return false }
    return ["0", "false", "off", "no"].contains(raw)
}
let glowConfig = GlowIndicator.Config(
    enabled: !glowDisabled && !envDisablesGlow(),
    color: env["MACBETH_GLOW_COLOR"] ?? glowDefaultColor,
    debounceMs: env["MACBETH_GLOW_DEBOUNCE_MS"].flatMap { Int($0) } ?? glowDefaultDebounceMs,
    helperPath: env["MACBETH_GLOW_HELPER"]
)
let glow = GlowIndicator(config: glowConfig, verbose: verbose)

// MARK: - Setup core components

let handleTable = HandleTable()
let appManager = AppConnectionManager(handleTable: handleTable)
let dispatcher = Dispatcher()

// Start handle expiration timer
let expirationTask = Task {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        await handleTable.expireStale()
        await appManager.evictTerminatedApps()
    }
}

// Register RPC methods
await dispatcher.register(method: "list_apps") { _ in
    listAppsResult()
}

registerConnectApp(dispatcher: dispatcher, appManager: appManager, glow: glow)
registerListWindows(dispatcher: dispatcher, appManager: appManager)
registerQueryTree(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable)
registerGetElement(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable)
registerClick(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable, glow: glow)
registerFill(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable, glow: glow)
registerPressKey(dispatcher: dispatcher, appManager: appManager, glow: glow)
registerPressKeys(dispatcher: dispatcher, appManager: appManager, glow: glow)
registerWaitFor(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable)
registerScreenshot(dispatcher: dispatcher, appManager: appManager, glow: glow)
registerRunAppleScript(dispatcher: dispatcher, glow: glow)
registerMenuBarMethods(dispatcher: dispatcher, appManager: appManager)
registerReadForm(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable)
registerExtractText(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable, glow: glow)
registerGlowActivity(dispatcher: dispatcher, glow: glow)

await dispatcher.register(method: "pin_handle") { params in
    guard let obj = params?.objectValue,
          let handleId = obj["handleId"]?.stringValue else {
        throw RPCError.invalidParams("Missing 'handleId'")
    }
    let pinned = await handleTable.pin(handleId)
    if !pinned { throw handleLookupError(handleId, await handleTable.classify(handleId)) }
    return .object(["pinned": .bool(true), "handleId": .string(handleId)])
}

await dispatcher.register(method: "unpin_handle") { params in
    guard let obj = params?.objectValue,
          let handleId = obj["handleId"]?.stringValue else {
        throw RPCError.invalidParams("Missing 'handleId'")
    }
    let unpinned = await handleTable.unpin(handleId)
    if !unpinned { throw handleLookupError(handleId, await handleTable.classify(handleId)) }
    return .object(["pinned": .bool(false), "handleId": .string(handleId)])
}

// Debug: dump all attributes of an element
await dispatcher.register(method: "dump_attributes") { params in
    guard let obj = params?.objectValue,
          let handleId = obj["handleId"]?.stringValue else {
        throw RPCError.invalidParams("Missing 'handleId'")
    }
    let resolved = try await resolveLiveHandle(handleId, in: handleTable)
    let attrs = dumpAttributes(resolved.element)
    return .object(attrs)
}

// Introspection for MCP surface-parity checks. The closure resolves the list at
// call time, after every registration (including this one) has completed.
await dispatcher.register(method: "list_methods") { _ in
    let methods = await dispatcher.registeredMethods()
    return .object(["methods": .array(methods.map { .string($0) })])
}

// MARK: - Start server

// Audit log configuration. CLI flags win over env vars, which win over defaults.
func envFlag(_ name: String) -> Bool {
    guard let raw = ProcessInfo.processInfo.environment[name]?.lowercased() else { return false }
    return ["1", "true", "yes", "on"].contains(raw)
}

func envInt(_ name: String) -> Int? {
    ProcessInfo.processInfo.environment[name].flatMap { Int($0) }
}

let resolvedLogMaxFileMB = logMaxFileMB ?? envInt("MACBETH_LOG_MAX_FILE_MB") ?? 5
let resolvedLogMaxFiles = logMaxFiles ?? envInt("MACBETH_LOG_MAX_FILES") ?? 10
// Treat empty-string env vars as unset — a missing-key dictionary subscript
// returns nil, but a present-but-empty one returns Some(""), which `if let`
// happily unwraps and would otherwise silently point the audit log at the
// current directory. A Node spawn that forwards "MACBETH_LOG_DIR: \"\"" when
// the caller hasn't set it is a common way to hit this.
let resolvedLogDir: String? = {
    if let explicit = logDir { return explicit }
    if let raw = ProcessInfo.processInfo.environment["MACBETH_LOG_DIR"] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    return nil
}()

let requestLogger: RequestLogger?
if noLog || envFlag("MACBETH_NO_LOG") {
    requestLogger = nil
} else {
    let url: URL?
    if let dirString = resolvedLogDir {
        url = URL(fileURLWithPath: dirString, isDirectory: true)
    } else {
        url = try? RequestLogger.defaultDirectory()
    }
    if let url, let logger = try? RequestLogger(
        directory: url,
        maxFileBytes: resolvedLogMaxFileMB * 1024 * 1024,
        maxFiles: resolvedLogMaxFiles
    ) {
        requestLogger = logger
    } else {
        fputs("[macbethd] Request log disabled: could not open \(url?.path ?? "<unresolved>")\n", stderr)
        requestLogger = nil
    }
}

let server = SocketServer(
    socketPath: resolvedSocketPath,
    dispatcher: dispatcher,
    verbose: verbose,
    requestLogger: requestLogger
)

// Signal handling for graceful shutdown
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let shutdownTask = Task {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        sigintSource.setEventHandler { continuation.resume() }
        sigtermSource.setEventHandler { continuation.resume() }
        sigintSource.resume()
        sigtermSource.resume()
    }
    fputs("\n[macbethd] Shutting down...\n", stderr)
    await glow.shutdown()
    unlink(resolvedSocketPath)
    exit(0)
}

fputs("[macbethd] Starting on \(resolvedSocketPath)\n", stderr)

do {
    try await server.start()
} catch {
    fputs("[macbethd] Fatal: \(error)\n", stderr)
    exit(1)
}
