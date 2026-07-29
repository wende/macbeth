import Foundation
import ScreenCaptureKit

func registerListWindows(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager
) {
    Task {
        await dispatcher.register(method: "list_windows") { params in
            guard let obj = params?.objectValue,
                  let appHandle = obj["appHandle"]?.stringValue else {
                throw RPCError.invalidParams("Missing 'appHandle'")
            }
            guard let connection = await appManager.get(appHandle) else {
                throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
            }

            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
            } catch {
                throw screenCaptureContentError(error)
            }

            let ownerPIDs = windowOwnerPIDs(in: content, rootedAt: connection.pid)
            let owned = content.windows.filter {
                $0.owningApplication.map { ownerPIDs.contains($0.processID) } == true
            }
            let displayFrames = content.displays.map(\.frame)
            let defaultID = findDefaultRootWindow(in: content, ownedBy: connection.pid)?.windowID
            let windows = owned.map {
                windowJSON($0, displayFrames: displayFrames, isDefault: $0.windowID == defaultID)
            }
            return .object(["windows": .array(windows)])
        }
    }
}
