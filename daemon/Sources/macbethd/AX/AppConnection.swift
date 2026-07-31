@preconcurrency import ApplicationServices
import AppKit
import Foundation

/// Manages connections to running applications via their AXUIElement.
actor AppConnectionManager {
    enum MatchKind: String, Sendable {
        case pid
        case appHandle = "app_handle"
        case exactName = "exact_name"
        case declaredAlias = "declared_alias"
        case bundleIdentifier = "bundle_identifier"
        case partialName = "partial_name"
        case partialAlias = "partial_alias"
        case partialBundleIdentifier = "partial_bundle_identifier"
    }

    struct Resolution: Sendable {
        let requestedName: String?
        let matchKind: MatchKind
        let matchedValue: String
    }

    struct Connection: Sendable {
        let pid: pid_t
        let appElement: SendableElement
        let bundleId: String?
        let appName: String?
        let aliases: [String]
        let handleId: String
        let runtime: AppRuntime
        let manualAccessibilityStatus: String
        let webContentReadiness: WebContentReadiness?
    }

    struct ConnectResult: Sendable {
        let connection: Connection
        let resolution: Resolution
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

    /// Connect to an app by app handle, name, or PID. Returns the connection info.
    ///
    /// - Parameter appHandle: A handle returned by an earlier `connect`. Reconnecting by
    ///   handle skips name resolution entirely, so a caller that already resolved an
    ///   ambiguous name keeps addressing the same process.
    /// - Parameter readyTimeoutMs: For Electron apps, how long to wait for Chromium
    ///   to build its accessibility tree after enabling it (default 3000ms).
    func connect(
        name: String? = nil,
        pid: Int? = nil,
        appHandle: String? = nil,
        readyTimeoutMs: Int? = nil
    ) async throws -> ConnectResult {
        let runningApp: NSRunningApplication
        let resolution: Resolution

        if let appHandle {
            runningApp = try await resolveHandle(appHandle)
            resolution = Resolution(
                requestedName: appHandle,
                matchKind: .appHandle,
                matchedValue: appHandle
            )
        } else if let pid {
            guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
                throw RPCError.appNotFound("No running app with PID \(pid)")
            }
            runningApp = app
            resolution = Resolution(
                requestedName: nil,
                matchKind: .pid,
                matchedValue: String(pid)
            )
        } else if let name {
            guard let match = findApp(byName: name) else {
                throw RPCError.appNotFound("No running app matching \"\(name)\"")
            }
            runningApp = match.app
            resolution = Resolution(
                requestedName: name,
                matchKind: match.kind,
                matchedValue: match.value
            )
        } else {
            throw RPCError.invalidParams("Must provide 'appHandle', 'name', or 'pid'")
        }
        let resolvedPid = runningApp.processIdentifier

        // Reuse an existing connection, but refresh Electron readiness. Callers that
        // reconnect after a slow Chromium tree build must not keep seeing a stale
        // empty_web_area from the first attempt. Only wait again when the caller
        // explicitly passes readyTimeoutMs — default reuse is a single inspect.
        if let existing = connections.values.first(where: { $0.pid == resolvedPid }) {
            if existing.runtime == .native {
                return ConnectResult(connection: existing, resolution: resolution)
            }

            let manualResult = enableManualAccessibility(existing.appElement.element)
            let manualStatus = manualResult == .success
                ? "accepted"
                : "rejected_\(manualResult.rawValue)"
            let readiness = await waitForWebContent(
                existing.appElement,
                timeout: TimeInterval(readyTimeoutMs ?? 0) / 1000.0
            )
            let refreshed = Connection(
                pid: existing.pid,
                appElement: existing.appElement,
                bundleId: existing.bundleId,
                appName: existing.appName,
                aliases: existing.aliases,
                handleId: existing.handleId,
                runtime: existing.runtime,
                manualAccessibilityStatus: manualStatus,
                webContentReadiness: readiness
            )
            connections[existing.handleId] = refreshed
            return ConnectResult(connection: refreshed, resolution: resolution)
        }

        let appElement = AXUIElementCreateApplication(resolvedPid)

        // Cap per-message AX waits so a sluggish target app can't stall a tree walk
        // or pin the dispatch thread for the default ~6s per call.
        AXUIElementSetMessagingTimeout(appElement, 1.5)

        // Verify the app responds to AX queries. `apiDisabled` means the whole API is off
        // (missing permission), which the daemon reports separately at startup — every
        // other failure means this specific process is not automatable through AX.
        var roleRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXRoleAttribute as CFString, &roleRef)
        guard result == .success || result == .apiDisabled else {
            let info = axErrorInfo(result)
            let label = runningApp.localizedName ?? runningApp.bundleIdentifier ?? "PID \(resolvedPid)"
            throw RPCError.appNotFound(
                "\(label) (pid \(resolvedPid)) is running but is not reachable through the "
                    + "Accessibility API. \(info.summary)",
                data: info.json
            )
        }

        let runtime = detectRuntime(pid: resolvedPid)

        // Electron/Chromium keeps its accessibility tree disabled until an assistive
        // technology client is detected. Setting AXManualAccessibility tells it to build
        // the full tree for third-party AT tools. It's a no-op on apps that don't
        // recognise the attribute, so we also send it for `.unknown` runtimes.
        var manualAccessibilityStatus = "not_attempted"
        var webContentReadiness: WebContentReadiness?
        if runtime != .native {
            let manualResult = enableManualAccessibility(appElement)
            manualAccessibilityStatus = manualResult == .success
                ? "accepted"
                : "rejected_\(manualResult.rawValue)"
            webContentReadiness = await waitForWebContent(
                SendableElement(appElement),
                timeout: TimeInterval(readyTimeoutMs ?? 3000) / 1000.0
            )
        }

        let handleId = await handleTable.store(SendableElement(appElement), pid: resolvedPid)

        let connection = Connection(
            pid: resolvedPid,
            appElement: SendableElement(appElement),
            bundleId: runningApp.bundleIdentifier,
            appName: runningApp.localizedName,
            aliases: appAliases(runningApp),
            handleId: handleId,
            runtime: runtime,
            manualAccessibilityStatus: manualAccessibilityStatus,
            webContentReadiness: webContentReadiness
        )
        connections[handleId] = connection
        return ConnectResult(connection: connection, resolution: resolution)
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

    /// Resolve an app handle back to its running process, evicting the connection if the
    /// app has since quit. Handles are daemon-local, so an unknown one is a caller error
    /// worth explaining rather than a silent re-resolution by name.
    private func resolveHandle(_ appHandle: String) async throws -> NSRunningApplication {
        guard let connection = connections[appHandle] else {
            throw RPCError.appNotFound(
                "Unknown app handle \"\(appHandle)\". App handles are daemon-local and are dropped "
                    + "when the app quits or the daemon restarts. Call connect_app again with "
                    + "'name' or 'pid'."
            )
        }
        guard isProcessAlive(connection.pid),
              let app = NSRunningApplication(processIdentifier: connection.pid) else {
            connections.removeValue(forKey: appHandle)
            await handleTable.removeHandles(forPid: connection.pid)
            throw RPCError.appNotFound(
                "App handle \"\(appHandle)\" pointed at \(connection.appName ?? "an app") "
                    + "(pid \(connection.pid)), which is no longer running. Call connect_app again "
                    + "with 'name' or 'pid'."
            )
        }
        return app
    }

    private struct AppMatch {
        let app: NSRunningApplication
        let kind: MatchKind
        let value: String
    }

    private nonisolated func findApp(byName name: String) -> AppMatch? {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        let lowered = name.lowercased()

        if let exact = apps.first(where: { $0.localizedName?.lowercased() == lowered }) {
            return AppMatch(app: exact, kind: .exactName, value: exact.localizedName ?? name)
        }
        for app in apps {
            if let alias = appAliases(app).first(where: { $0.lowercased() == lowered }) {
                return AppMatch(app: app, kind: .declaredAlias, value: alias)
            }
        }
        if let bundle = apps.first(where: { $0.bundleIdentifier?.lowercased() == lowered }) {
            return AppMatch(
                app: bundle,
                kind: .bundleIdentifier,
                value: bundle.bundleIdentifier ?? name
            )
        }
        if let partial = apps.first(where: { $0.localizedName?.lowercased().contains(lowered) == true }) {
            return AppMatch(app: partial, kind: .partialName, value: partial.localizedName ?? name)
        }
        for app in apps {
            if let alias = appAliases(app).first(where: { $0.lowercased().contains(lowered) }) {
                return AppMatch(app: app, kind: .partialAlias, value: alias)
            }
        }
        if let bundle = apps.first(where: { $0.bundleIdentifier?.lowercased().contains(lowered) == true }) {
            return AppMatch(
                app: bundle,
                kind: .partialBundleIdentifier,
                value: bundle.bundleIdentifier ?? name
            )
        }
        return nil
    }
}
