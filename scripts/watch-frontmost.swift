import AppKit
import Foundation

struct FrontmostEvent: Encodable {
    let timestampMs: Int64
    let pid: Int32
    let name: String
}

func emit(_ application: NSRunningApplication?) {
    guard let application else { return }
    let event = FrontmostEvent(
        timestampMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
        pid: application.processIdentifier,
        name: application.localizedName ?? "Unknown"
    )
    guard let data = try? JSONEncoder().encode(event) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

let workspace = NSWorkspace.shared
let observer = workspace.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil,
    queue: .main
) { notification in
    let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication
    emit(application)
}

emit(workspace.frontmostApplication)
RunLoop.main.run()
workspace.notificationCenter.removeObserver(observer)
