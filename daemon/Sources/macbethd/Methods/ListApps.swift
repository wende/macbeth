import AppKit

enum AppRuntime: String, Sendable {
    case native
    case electron
    case unknown
}

struct AppInfo: Sendable {
    let name: String
    let pid: Int32
    let bundleId: String?
    let aliases: [String]
    let runtime: AppRuntime
}

/// List running GUI applications.
func listApps() -> [AppInfo] {
    NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .compactMap { app in
            guard let name = app.localizedName else { return nil }
            return AppInfo(
                name: name,
                pid: app.processIdentifier,
                bundleId: app.bundleIdentifier,
                aliases: appAliases(app),
                runtime: detectRuntime(app)
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
    }

    if infoDictionary?["ElectronAsarIntegrity"] != nil {
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

/// Detect the runtime of the app owning a given PID.
func detectRuntime(pid: pid_t) -> AppRuntime {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return .unknown }
    return detectRuntime(app)
}

/// Convert app list to JSON-RPC result.
func listAppsResult() -> JSONValue {
    let apps = listApps().map { app -> JSONValue in
        .object([
            "name": .string(app.name),
            "pid": .number(Double(app.pid)),
            "bundleId": app.bundleId.map { .string($0) } ?? .null,
            "aliases": .array(app.aliases.map { .string($0) }),
            "runtime": .string(app.runtime.rawValue),
        ])
    }
    return .object(["apps": .array(apps)])
}
