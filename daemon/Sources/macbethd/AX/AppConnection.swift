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
    }

    private var connections: [String: Connection] = [:]
    private let handleTable: HandleTable

    init(handleTable: HandleTable) {
        self.handleTable = handleTable
    }

    /// Connect to an app by name or PID. Returns the connection info.
    func connect(name: String?, pid: Int?) async throws -> Connection {
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

        // Verify the app responds to AX queries
        var roleRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXRoleAttribute as CFString, &roleRef)
        guard result == .success || result == .apiDisabled else {
            throw RPCError.appNotFound(
                "App with PID \(resolvedPid) does not respond to accessibility queries (error: \(result.rawValue))")
        }

        let runningApp = NSRunningApplication(processIdentifier: resolvedPid)
        let handleId = await handleTable.store(SendableElement(appElement), pid: resolvedPid)

        let connection = Connection(
            pid: resolvedPid,
            appElement: SendableElement(appElement),
            bundleId: runningApp?.bundleIdentifier,
            appName: runningApp?.localizedName,
            handleId: handleId
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
