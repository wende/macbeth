import Foundation
import ScreenCaptureKit

/// Register the list_windows RPC method.
///
/// `appHandle` is optional: with one, the listing is scoped to that app and its
/// helper processes; without one, it covers every app that owns a window, so
/// "is app X open, and what is it showing?" costs a single call and never needs
/// an accessibility-tree walk.
func registerListWindows(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager
) {
    Task {
        await dispatcher.register(method: "list_windows") { params in
            let obj = params?.objectValue
            let includeAllSurfaces = obj?["includeAllSurfaces"]?.boolValue ?? false
            let titlePattern = obj?["titlePattern"]?.stringValue

            var connection: AppConnectionManager.Connection?
            if let appHandle = obj?["appHandle"]?.stringValue {
                guard let found = await appManager.get(appHandle) else {
                    throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
                }
                connection = found
            }

            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
            } catch {
                throw screenCaptureContentError(error)
            }

            let displayFrames = content.displays.map(\.frame)
            let descriptors: [WindowDescriptor]
            let defaultWindowIDs: Set<UInt32>
            if let connection {
                descriptors = ownedWindows(in: content, rootedAt: connection.pid)
                // Scoped listings keep the existing rule: the default is the
                // window screenshot/OCR capture for the *connected* app, never
                // one hosted by a helper process.
                let scopedDefault = findDefaultRootWindow(
                    in: content, ownedBy: connection.pid)?.windowID
                defaultWindowIDs = scopedDefault.map { Set([$0]) } ?? []
            } else {
                descriptors = content.windows.map { WindowDescriptor($0) }
                defaultWindowIDs = defaultWindowIDsByOwner(
                    among: descriptors, displayFrames: displayFrames)
            }

            var listed = listedWindows(
                descriptors,
                displayFrames: displayFrames,
                includeAllSurfaces: includeAllSurfaces
            )
            // Filter *before* the AX join: filtered-out owners skip the per-app
            // round trip entirely (latency win as well as byte win). Compile once.
            if let pattern = titlePattern, !pattern.isEmpty {
                listed = try windowsMatchingTitlePattern(listed, pattern: pattern)
            }
            // Enrich only what is being returned: each unique owner costs one
            // bounded round trip to a possibly busy app.
            let accessibility = accessibilityWindowMetadata(
                forPIDs: listed.compactMap(\.ownerPID))

            return listWindowsPayload(
                listed,
                displayFrames: displayFrames,
                defaultWindowIDs: defaultWindowIDs,
                accessibility: accessibility
            )
        }
    }
}
