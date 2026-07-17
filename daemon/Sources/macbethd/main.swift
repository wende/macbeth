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

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--socket-path":
        socketPath = args.next()
    case "--verbose", "-v":
        verbose = true
    case "--no-glow":
        glowDisabled = true
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
          --check-permissions   Print Accessibility + Screen Recording status, then exit
          --help, -h            Show this help

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
registerQueryTree(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable)
registerGetElement(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable)
registerClick(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable, glow: glow)
registerFill(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable, glow: glow)
registerPressKey(dispatcher: dispatcher, appManager: appManager, glow: glow)
registerPressKeys(dispatcher: dispatcher, appManager: appManager, glow: glow)
registerWaitFor(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable)
registerScreenshot(dispatcher: dispatcher, appManager: appManager, glow: glow)
registerRunAppleScript(dispatcher: dispatcher, glow: glow)
registerReadForm(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable)
registerExtractText(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable, glow: glow)
registerGlowActivity(dispatcher: dispatcher, glow: glow)

await dispatcher.register(method: "pin_handle") { params in
    guard let obj = params?.objectValue,
          let handleId = obj["handleId"]?.stringValue else {
        throw RPCError.invalidParams("Missing 'handleId'")
    }
    let pinned = await handleTable.pin(handleId)
    if !pinned { throw RPCError.elementNotFound("Handle not found: \(handleId)") }
    return .object(["pinned": .bool(true), "handleId": .string(handleId)])
}

await dispatcher.register(method: "unpin_handle") { params in
    guard let obj = params?.objectValue,
          let handleId = obj["handleId"]?.stringValue else {
        throw RPCError.invalidParams("Missing 'handleId'")
    }
    let unpinned = await handleTable.unpin(handleId)
    if !unpinned { throw RPCError.elementNotFound("Handle not found: \(handleId)") }
    return .object(["pinned": .bool(false), "handleId": .string(handleId)])
}

// Debug: dump all attributes of an element
await dispatcher.register(method: "dump_attributes") { params in
    guard let obj = params?.objectValue,
          let handleId = obj["handleId"]?.stringValue else {
        throw RPCError.invalidParams("Missing 'handleId'")
    }
    guard let resolved = await handleTable.resolve(handleId) else {
        throw RPCError.elementNotFound("Handle expired: \(handleId)")
    }
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

let server = SocketServer(socketPath: resolvedSocketPath, dispatcher: dispatcher, verbose: verbose)

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
