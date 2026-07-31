import Testing
import Foundation
@preconcurrency import ApplicationServices
@testable import macbethd

// MARK: - AX error explanations

@Test func explainsCannotCompleteWithARecoveryPath() {
    let info = axErrorInfo(code: -25204)

    #expect(info.code == -25204)
    #expect(info.name == "cannot_complete")
    #expect(info.explanation.contains("did not answer"))
    #expect(info.nextAction.contains("extract_text"))
    #expect(info.summary.contains("AX error -25204 (cannot_complete)"))
}

@Test func explainsMissingAccessibilityPermission() {
    let info = axErrorInfo(code: -25211)

    #expect(info.name == "api_disabled")
    #expect(info.nextAction.contains("Accessibility"))
}

@Test func unknownAXCodesStillGetAnExplanationAndAction() {
    let info = axErrorInfo(code: -99999)

    #expect(info.code == -99999)
    #expect(info.name == "unknown")
    #expect(!info.explanation.isEmpty)
    #expect(!info.nextAction.isEmpty)
}

@Test func axErrorInfoAcceptsAXErrorValues() {
    #expect(axErrorInfo(AXError.cannotComplete).name == "cannot_complete")
    #expect(axErrorInfo(AXError.invalidUIElement).name == "invalid_ui_element")
    #expect(axErrorInfo(AXError.success).name == "success")
}

// MARK: - Readiness classification

@Test func classifiesARespondingAppAsConnectable() {
    let result = classifyAccessibility(probe: .success)

    #expect(result.readiness == .connectable)
    #expect(result.error == nil)
}

@Test func classifiesARunningButUnreachableAppAsNotConnectable() {
    let result = classifyAccessibility(probe: .cannotComplete)

    #expect(result.readiness == .notConnectable)
    #expect(result.error?.code == -25204)
    #expect(result.error?.name == "cannot_complete")
}

@Test func classifiesADisabledAPISeparatelyFromAnUnreachableApp() {
    let result = classifyAccessibility(probe: .apiDisabled)

    // A missing permission is a macbeth-wide problem, not evidence about this app.
    #expect(result.readiness == .permissionRequired)
    #expect(result.error?.name == "api_disabled")
}

// MARK: - list_apps wire format

private func makeApp(
    name: String,
    pid: pid_t,
    probe: AXError
) -> AppInfo {
    AppInfo(
        name: name,
        pid: pid,
        bundleId: "com.example.\(name.lowercased())",
        aliases: [],
        runtime: .native,
        accessibility: classifyAccessibility(probe: probe)
    )
}

private func appEntries(_ result: JSONValue) -> [JSONValue] {
    result.objectValue?["apps"]?.arrayValue ?? []
}

@Test func listAppsDistinguishesConnectableFromRunningOnlyApps() {
    let result = listAppsResult(apps: [
        makeApp(name: "Finder", pid: 100, probe: .success),
        makeApp(name: "UnityHub", pid: 200, probe: .cannotComplete),
    ])

    let apps = appEntries(result)
    #expect(apps.count == 2)

    let finder = apps[0].objectValue?["accessibility"]?.objectValue
    #expect(finder?["status"]?.stringValue == "connectable")
    #expect(finder?["connectable"]?.boolValue == true)
    #expect(finder?["axCode"] == nil)

    let hub = apps[1].objectValue?["accessibility"]?.objectValue
    #expect(hub?["status"]?.stringValue == "not_connectable")
    #expect(hub?["connectable"]?.boolValue == false)
}

@Test func listAppsExplainsWhyARunningAppIsNotConnectable() {
    let result = listAppsResult(apps: [
        makeApp(name: "UnityHub", pid: 200, probe: .cannotComplete)
    ])

    let accessibility = appEntries(result).first?.objectValue?["accessibility"]?.objectValue
    #expect(accessibility?["axCode"]?.numberValue == -25204)
    #expect(accessibility?["axError"]?.stringValue == "cannot_complete")
    #expect(accessibility?["explanation"]?.stringValue?.isEmpty == false)
    #expect(accessibility?["nextAction"]?.stringValue?.isEmpty == false)
}

@Test func listAppsKeepsExistingFields() {
    let result = listAppsResult(apps: [
        makeApp(name: "Finder", pid: 100, probe: .success)
    ])

    let app = appEntries(result).first?.objectValue
    #expect(app?["name"]?.stringValue == "Finder")
    #expect(app?["pid"]?.numberValue == 100)
    #expect(app?["bundleId"]?.stringValue == "com.example.finder")
    #expect(app?["runtime"]?.stringValue == "native")
}

// MARK: - connect_app errors

@Test func connectingByUnknownHandleExplainsHandleLifetime() async {
    let table = HandleTable(ttl: 60)
    let manager = AppConnectionManager(handleTable: table, isProcessAlive: { _ in true })

    do {
        _ = try await manager.connect(appHandle: "h_999")
        Issue.record("Expected connect to reject an unknown handle")
    } catch let error as RPCError {
        guard case .appNotFound(let message, _) = error else {
            Issue.record("Expected appNotFound, got \(error)")
            return
        }
        #expect(message.contains("h_999"))
        #expect(message.contains("daemon-local"))
        #expect(message.contains("connect_app"))
    } catch {
        Issue.record("Expected RPCError, got \(error)")
    }
}

@Test func connectingByHandleForADeadAppSaysSoAndEvicts() async {
    let table = HandleTable(ttl: 60)
    let processes = MutableProcessSet(alive: [4242])
    let manager = AppConnectionManager(
        handleTable: table,
        isProcessAlive: { processes.isAlive($0) }
    )
    await manager.seedForTesting(
        AppConnectionManager.Connection(
            pid: 4242,
            appElement: SendableElement(AXUIElementCreateSystemWide()),
            bundleId: "com.example.gone",
            appName: "Gone",
            aliases: [],
            handleId: "h_7",
            runtime: .native,
            manualAccessibilityStatus: "not_attempted",
            webContentReadiness: nil
        )
    )
    processes.terminate(4242)

    do {
        _ = try await manager.connect(appHandle: "h_7")
        Issue.record("Expected connect to fail for a terminated app")
    } catch let error as RPCError {
        guard case .appNotFound(let message, _) = error else {
            Issue.record("Expected appNotFound, got \(error)")
            return
        }
        #expect(message.contains("Gone"))
        #expect(message.contains("no longer running"))
    } catch {
        Issue.record("Expected RPCError, got \(error)")
    }

    #expect(await manager.connectionCount == 0)
}

@Test func connectingWithNoTargetNamesEveryAcceptedForm() async {
    let manager = AppConnectionManager(handleTable: HandleTable(ttl: 60))

    do {
        _ = try await manager.connect()
        Issue.record("Expected connect to reject an empty target")
    } catch let error as RPCError {
        guard case .invalidParams(let message) = error else {
            Issue.record("Expected invalidParams, got \(error)")
            return
        }
        #expect(message.contains("appHandle"))
        #expect(message.contains("name"))
        #expect(message.contains("pid"))
    } catch {
        Issue.record("Expected RPCError, got \(error)")
    }
}

/// Liveness probe backing store for the handle-eviction test.
private final class MutableProcessSet: @unchecked Sendable {
    private let lock = NSLock()
    private var alive: Set<pid_t>

    init(alive: Set<pid_t>) { self.alive = alive }

    func terminate(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        alive.remove(pid)
    }

    func isAlive(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return alive.contains(pid)
    }
}
