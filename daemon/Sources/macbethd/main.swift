import AppKit
import Foundation

// Initialize NSApplication so CoreGraphics/ScreenCaptureKit can connect to the window server.
// Without this, CGS_REQUIRE_INIT asserts on screenshot capture.
let _ = NSApplication.shared

// MARK: - Argument parsing

var socketPath: String?
var verbose = false

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--socket-path":
        socketPath = args.next()
    case "--verbose", "-v":
        verbose = true
    case "--help", "-h":
        fputs("""
        Usage: macbethd [options]

        Options:
          --socket-path <path>  Unix socket path (default: $TMPDIR/macbeth-<uid>.sock)
          --verbose, -v         Enable verbose logging
          --help, -h            Show this help

        """, stderr)
        exit(0)
    default:
        fputs("Unknown argument: \(arg)\n", stderr)
        exit(1)
    }
}

// Default socket path
let resolvedSocketPath = socketPath
    ?? ProcessInfo.processInfo.environment["TMPDIR"].map { "\($0)macbeth-\(getuid()).sock" }
    ?? "/tmp/macbeth-\(getuid()).sock"

// MARK: - Permission check

if !checkAccessibilityPermissions(prompt: true) {
    printPermissionGuidance()
    fputs("\nStarting anyway — some operations may fail without permissions.\n\n", stderr)
}

// MARK: - Setup core components

let handleTable = HandleTable()
let appManager = AppConnectionManager(handleTable: handleTable)
let dispatcher = Dispatcher()

// Start handle expiration timer
let expirationTask = Task {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        await handleTable.expireStale()
    }
}

// Register RPC methods
await dispatcher.register(method: "list_apps") { _ in
    listAppsResult()
}

registerConnectApp(dispatcher: dispatcher, appManager: appManager)
registerQueryTree(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable)
registerGetElement(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable)
registerClick(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable)
registerFill(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable)
registerPressKey(dispatcher: dispatcher)
registerWaitFor(dispatcher: dispatcher, appManager: appManager, handleTable: handleTable)
registerScreenshot(dispatcher: dispatcher, appManager: appManager)

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
