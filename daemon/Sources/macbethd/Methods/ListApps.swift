@preconcurrency import ApplicationServices
import AppKit

enum AppRuntime: String, Sendable {
    case native
    case electron
    case unknown
}

/// Whether a running app can currently be driven through the Accessibility API.
///
/// "Running" and "automatable" are different things: launchers, helper processes, and
/// apps that never implement AX show up in the process list but refuse every request.
/// `list_apps` reports this so callers do not discover it only when `connect_app` fails.
enum AXReadiness: String, Sendable {
    /// The app answered an accessibility probe.
    case connectable
    /// The whole API is off because macbeth lacks Accessibility permission.
    case permissionRequired = "permission_required"
    /// The app is running but refuses accessibility requests.
    case notConnectable = "not_connectable"
}

struct AppAccessibility: Sendable, Equatable {
    let readiness: AXReadiness
    /// Explanation of the probe failure; `nil` when the app is connectable.
    let error: AXErrorInfo?

    var json: JSONValue {
        var fields: [String: JSONValue] = [
            "status": .string(readiness.rawValue),
            "connectable": .bool(readiness == .connectable),
        ]
        if let error {
            fields["axCode"] = .number(Double(error.code))
            fields["axError"] = .string(error.name)
            fields["explanation"] = .string(error.explanation)
            fields["nextAction"] = .string(error.nextAction)
        }
        return .object(fields)
    }
}

struct AppInfo: Sendable {
    let name: String
    let pid: Int32
    let bundleId: String?
    let aliases: [String]
    let runtime: AppRuntime
    let accessibility: AppAccessibility
}

/// Classify the result of an accessibility probe.
func classifyAccessibility(probe: AXError) -> AppAccessibility {
    switch probe {
    case .success:
        return AppAccessibility(readiness: .connectable, error: nil)
    case .apiDisabled:
        return AppAccessibility(readiness: .permissionRequired, error: axErrorInfo(probe))
    default:
        return AppAccessibility(readiness: .notConnectable, error: axErrorInfo(probe))
    }
}

/// Ask an app for its AX role — the same check `connect_app` performs, with a tighter
/// messaging timeout so one unresponsive process cannot stall the whole listing.
func probeAccessibility(pid: pid_t, timeout: Float = 0.25) -> AXError {
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, timeout)
    var role: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
}

/// List running GUI applications, probing each one for accessibility readiness.
///
/// - Parameter probe: Accessibility probe, injectable for tests.
func listApps(probe: (pid_t) -> AXError = { probeAccessibility(pid: $0) }) -> [AppInfo] {
    NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .compactMap { app in
            guard let name = app.localizedName else { return nil }
            return AppInfo(
                name: name,
                pid: app.processIdentifier,
                bundleId: app.bundleIdentifier,
                aliases: appAliases(app),
                runtime: detectRuntime(app),
                accessibility: classifyAccessibility(probe: probe(app.processIdentifier))
            )
        }
}

/// Alternate display names declared by an application bundle. LaunchServices uses
/// these aliases for discovery even though `NSRunningApplication.localizedName`
/// reports only the current product name.
func appAliases(_ app: NSRunningApplication) -> [String] {
    guard let info = app.bundleURL.flatMap({ Bundle(url: $0)?.infoDictionary }) else {
        return []
    }
    return (info["CFBundleAlternateNames"] as? [String]) ?? []
}

/// Detect whether an app is native, Electron, etc.
func detectRuntime(_ app: NSRunningApplication) -> AppRuntime {
    let info = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
    return detectRuntime(
        bundleURL: app.bundleURL,
        bundleIdentifier: app.bundleIdentifier,
        infoDictionary: info
    )
}

/// Testable runtime detector that also recognises branded Electron distributions.
/// Some vendors rename `Electron Framework.framework`, but Electron still writes the
/// `ElectronAsarIntegrity` marker into the host bundle's Info.plist.
func detectRuntime(
    bundleURL: URL?,
    bundleIdentifier: String?,
    infoDictionary: [String: Any]?
) -> AppRuntime {
    if let bundleURL {
        let electronFramework = bundleURL
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        if FileManager.default.fileExists(atPath: electronFramework.path) {
            return .electron
        }

        // Branded distributions rename Electron Framework.framework (e.g. "Codex
        // Framework.framework") but still ship Chromium's Helper (Renderer) app
        // beside a *Framework.framework bundle.
        if hasBrandedElectronFrameworkLayout(bundleURL) {
            return .electron
        }
    }

    if infoDictionary?["ElectronAsarIntegrity"] != nil {
        return .electron
    }

    // Electron also stamps ChromiumBaseVersion into Info.plist even when asar
    // integrity metadata is absent (unpacked / custom packaging).
    if infoDictionary?["ChromiumBaseVersion"] != nil {
        return .electron
    }

    // A development Electron process launched from node_modules may have no
    // bundleURL even though LaunchServices still reports Electron's generic bundle
    // identifier. Keep it on the Electron path so accessibility setup and the
    // keyboard-aware fill strategy are applied.
    if bundleIdentifier == "com.github.Electron" {
        return .electron
    }

    // Could detect other runtimes (Qt, Java, etc.) here in the future
    return .native
}

/// True when Contents/Frameworks looks like a renamed Electron/Chromium layout.
func hasBrandedElectronFrameworkLayout(_ bundleURL: URL) -> Bool {
    let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else {
        return false
    }
    let hasRendererHelper = names.contains { $0.contains("Helper (Renderer)") }
    let hasFramework = names.contains {
        $0.hasSuffix("Framework.framework") && $0 != "Electron Framework.framework"
    }
    return hasRendererHelper && hasFramework
}

/// Detect the runtime of the app owning a given PID.
func detectRuntime(pid: pid_t) -> AppRuntime {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return .unknown }
    return detectRuntime(app)
}

/// Convert app list to JSON-RPC result.
func listAppsResult() -> JSONValue {
    listAppsResult(apps: listApps())
}

/// Serialize an app list. Split from discovery so the wire format is testable without
/// a running desktop session.
func listAppsResult(apps: [AppInfo]) -> JSONValue {
    let entries = apps.map { app -> JSONValue in
        .object([
            "name": .string(app.name),
            "pid": .number(Double(app.pid)),
            "bundleId": app.bundleId.map { .string($0) } ?? .null,
            "aliases": .array(app.aliases.map { .string($0) }),
            "runtime": .string(app.runtime.rawValue),
            "accessibility": app.accessibility.json,
        ])
    }
    return .object(["apps": .array(entries)])
}
