@preconcurrency import ApplicationServices
import AppKit
import Foundation

/// Manages connections to running applications via their AXUIElement.
actor AppConnectionManager {
    struct Connection: Sendable {
        let pid: pid_t
        let appElement: SendableElement
        let bundleId: String?
        let appName: String?
        let handleId: String
        let runtime: AppRuntime
    }

    private var connections: [String: Connection] = [:]
    private let handleTable: HandleTable
    private let isProcessAlive: @Sendable (pid_t) -> Bool

    /// - Parameter isProcessAlive: Liveness probe for a connected app, injectable for tests.
    init(
        handleTable: HandleTable,
        isProcessAlive: @escaping @Sendable (pid_t) -> Bool = { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return !app.isTerminated
        }
    ) {
        self.handleTable = handleTable
        self.isProcessAlive = isProcessAlive
    }

    /// Drop connections whose target app has quit, along with their handles.
    ///
    /// Without this, `connections` only ever grows: entries are added on `connect` and
    /// nothing removes them, so a long-lived daemon cycling through short-lived apps
    /// retains a `Connection` and its app handle per app, forever.
    func evictTerminatedApps() async {
        let dead = connections.filter { !isProcessAlive($0.value.pid) }
        guard !dead.isEmpty else { return }

        for (handleId, connection) in dead {
            connections.removeValue(forKey: handleId)
            await handleTable.removeHandles(forPid: connection.pid)
            vlog("Evicted connection \(handleId) for terminated pid \(connection.pid)")
        }
    }

    /// Number of live connections.
    var connectionCount: Int { connections.count }

    #if DEBUG
    /// Register a connection without a live app behind it. Tests only — `connect`
    /// requires an AX-responsive process, which a unit test has no way to provide.
    func seedForTesting(_ connection: Connection) {
        connections[connection.handleId] = connection
    }
    #endif

    /// Connect to an app by name or PID. Returns the connection info.
    ///
    /// - Parameter readyTimeoutMs: For Electron apps, how long to wait for Chromium
    ///   to build its accessibility tree after enabling it (default 3000ms).
    func connect(name: String?, pid: Int?, readyTimeoutMs: Int? = nil) async throws -> Connection {
        let resolvedPid: pid_t

        if let pid {
            resolvedPid = pid_t(pid)
        } else if let name {
            guard let app = findApp(byName: name) else {
                throw RPCError.appNotFound("No running app matching \"\(name)\"")
            }
            resolvedPid = app.processIdentifier
        } else {
            throw RPCError.invalidParams("Must provide 'name' or 'pid'")
        }

        // Check if already connected
        if let existing = connections.values.first(where: { $0.pid == resolvedPid }) {
            return existing
        }

        let appElement = AXUIElementCreateApplication(resolvedPid)

        // Cap per-message AX waits so a sluggish target app can't stall a tree walk
        // or pin the dispatch thread for the default ~6s per call.
        AXUIElementSetMessagingTimeout(appElement, 1.5)

        // Verify the app responds to AX queries
        var roleRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXRoleAttribute as CFString, &roleRef)
        guard result == .success || result == .apiDisabled else {
            throw RPCError.appNotFound(
                "App with PID \(resolvedPid) does not respond to accessibility queries (error: \(result.rawValue))")
        }

        let runtime = detectRuntime(pid: resolvedPid)

        // Electron/Chromium keeps its accessibility tree disabled until an assistive
        // technology client is detected. Setting AXManualAccessibility tells it to build
        // the full tree for third-party AT tools. It's a no-op on apps that don't
        // recognise the attribute, so we also send it for `.unknown` runtimes.
        if runtime != .native {
            enableManualAccessibility(appElement)
            await waitForWebContent(
                SendableElement(appElement),
                timeout: TimeInterval(readyTimeoutMs ?? 3000) / 1000.0
            )
        }

        let runningApp = NSRunningApplication(processIdentifier: resolvedPid)
        let handleId = await handleTable.store(SendableElement(appElement), pid: resolvedPid)

        let connection = Connection(
            pid: resolvedPid,
            appElement: SendableElement(appElement),
            bundleId: runningApp?.bundleIdentifier,
            appName: runningApp?.localizedName,
            handleId: handleId,
            runtime: runtime
        )
        connections[handleId] = connection
        return connection
    }

    /// Get a connection by handle ID.
    func get(_ handleId: String) -> Connection? {
        connections[handleId]
    }

    /// Get the AXUIElement for an app handle.
    func getElement(_ handleId: String) -> SendableElement? {
        connections[handleId]?.appElement
    }

    /// Bring the connected app to the front so HID-posted keyboard events land there.
    func activate(_ handleId: String) async {
        guard let connection = connections[handleId] else { return }

        if let app = NSRunningApplication(processIdentifier: connection.pid) {
            _ = await MainActor.run {
                app.activate(options: [])
            }
        }

        let appElement = AXUIElementCreateApplication(connection.pid)
        AXUIElementPerformAction(appElement, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, true as CFBoolean)

        for _ in 0..<10 {
            if let app = NSRunningApplication(processIdentifier: connection.pid), app.isActive {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private nonisolated func findApp(byName name: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        let lowered = name.lowercased()

        if let exact = apps.first(where: { $0.localizedName?.lowercased() == lowered }) {
            return exact
        }
        if let partial = apps.first(where: { $0.localizedName?.lowercased().contains(lowered) == true }) {
            return partial
        }
        if let bundle = apps.first(where: { $0.bundleIdentifier?.lowercased().contains(lowered) == true }) {
            return bundle
        }
        return nil
    }
}
