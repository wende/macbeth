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
                runtime: detectRuntime(app)
            )
        }
}

/// Detect whether an app is native, Electron, etc.
private func detectRuntime(_ app: NSRunningApplication) -> AppRuntime {
    guard let bundleURL = app.bundleURL else { return .unknown }
    let frameworksURL = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
    if FileManager.default.fileExists(atPath: frameworksURL.path) {
        return .electron
    }
    // Could detect other runtimes (Qt, Java, etc.) here in the future
    return .native
}

/// Convert app list to JSON-RPC result.
func listAppsResult() -> JSONValue {
    let apps = listApps().map { app -> JSONValue in
        .object([
            "name": .string(app.name),
            "pid": .number(Double(app.pid)),
            "bundleId": app.bundleId.map { .string($0) } ?? .null,
            "runtime": .string(app.runtime.rawValue),
        ])
    }
    return .object(["apps": .array(apps)])
}
