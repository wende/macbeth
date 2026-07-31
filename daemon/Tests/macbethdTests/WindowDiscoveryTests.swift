import CoreGraphics
import Testing
@testable import macbethd

@Test func usableCaptureFrameAcceptsNormalAndOffSpaceWindows() {
    #expect(isUsableCaptureFrame(CGRect(x: 120, y: 80, width: 900, height: 700)))
    #expect(isUsableCaptureFrame(CGRect(x: -1800, y: 100, width: 900, height: 700)))
}

@Test func usableCaptureFrameRejectsScreenCaptureKitSentinels() {
    #expect(!isUsableCaptureFrame(CGRect(x: -15000, y: 16116, width: 1, height: 1)))
    #expect(!isUsableCaptureFrame(CGRect(x: 0, y: 0, width: 0, height: 700)))
    #expect(!isUsableCaptureFrame(
        CGRect(x: CGFloat.infinity, y: 0, width: 900, height: 700)
    ))
}

@Test func displayEdgeStripRejectsMenuBarButKeepsCompactWindows() {
    let displays = [
        CGRect(x: 0, y: 0, width: 1728, height: 1117),
        CGRect(x: -1920, y: -200, width: 1920, height: 1080),
    ]
    #expect(isDisplayEdgeStrip(
        CGRect(x: 0, y: 0, width: 1728, height: 33),
        displayFrames: displays
    ))
    #expect(isDisplayEdgeStrip(
        CGRect(x: -1920, y: -200, width: 1920, height: 24),
        displayFrames: displays
    ))
    #expect(!isDisplayEdgeStrip(
        CGRect(x: 100, y: 100, width: 500, height: 50),
        displayFrames: displays
    ))
}

@Test func descendantProcessWalkHandlesChildrenAndCycles() {
    let parents: [pid_t: pid_t] = [300: 200, 200: 100, 400: 999, 500: 600, 600: 500]
    #expect(isDescendantProcess(300, of: 100, parentOf: { parents[$0] }))
    #expect(isDescendantProcess(100, of: 100, parentOf: { parents[$0] }))
    #expect(!isDescendantProcess(400, of: 100, parentOf: { parents[$0] }))
    #expect(!isDescendantProcess(500, of: 100, parentOf: { parents[$0] }))
}

@Test func selectDefaultWindowIDPrefersOnScreenCapturableWindows() {
    let candidates: [(windowID: UInt32, isOnScreen: Bool, capturable: Bool)] = [
        (1, true, false),   // menu-bar / bookkeeping — ignored
        (2, false, true),   // off-space capturable
        (3, true, true),    // preferred default
        (4, true, true),
    ]
    #expect(selectDefaultWindowID(from: candidates) == 3)
}

@Test func selectDefaultWindowIDFallsBackToOffScreenCapturable() {
    let candidates: [(windowID: UInt32, isOnScreen: Bool, capturable: Bool)] = [
        (10, true, false),
        (11, false, true),
        (12, false, true),
    ]
    #expect(selectDefaultWindowID(from: candidates) == 11)
}

@Test func selectDefaultWindowIDReturnsNilWhenNothingCapturable() {
    let candidates: [(windowID: UInt32, isOnScreen: Bool, capturable: Bool)] = [
        (1, true, false),
        (2, false, false),
    ]
    #expect(selectDefaultWindowID(from: candidates) == nil)
}

// MARK: - list_windows payload

private let testDisplays = [CGRect(x: 0, y: 0, width: 1728, height: 1117)]

private func testWindow(
    _ id: UInt32,
    pid: pid_t,
    app: String,
    bundle: String? = nil,
    title: String? = nil,
    frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600),
    layer: Int = 0,
    onScreen: Bool = true,
    active: Bool = false
) -> WindowDescriptor {
    WindowDescriptor(
        windowID: id,
        ownerPID: pid,
        ownerName: app,
        bundleID: bundle,
        title: title,
        frame: frame,
        layer: layer,
        isOnScreen: onScreen,
        isActive: active
    )
}

private func listedWindowIDs(_ payload: JSONValue) -> [UInt32] {
    (payload["windows"]?.arrayValue ?? []).compactMap {
        $0["windowId"]?.intValue.map { UInt32($0) }
    }
}

@Test func listWindowsPayloadHandlesNoWindows() {
    let payload = listWindowsPayload(
        [],
        displayFrames: testDisplays,
        defaultWindowIDs: [],
        accessibility: [:]
    )
    #expect(payload["windows"] == JSONValue.array([]))
}

@Test func listWindowsPayloadReportsWindowsFromMultipleApps() {
    let windows = [
        testWindow(1, pid: 100, app: "Unity", bundle: "com.unity3d.UnityEditor", title: "Sample Scene"),
        testWindow(2, pid: 100, app: "Unity", bundle: "com.unity3d.UnityEditor", title: "Console"),
        testWindow(3, pid: 200, app: "Finder", bundle: "com.apple.finder", title: "Documents"),
    ]
    let payload = listWindowsPayload(
        windows,
        displayFrames: testDisplays,
        defaultWindowIDs: defaultWindowIDsByOwner(among: windows, displayFrames: testDisplays),
        accessibility: [:]
    )

    #expect(listedWindowIDs(payload) == [1, 2, 3])
    let entries = payload["windows"]?.arrayValue ?? []
    #expect(entries[0]["ownerName"] == JSONValue.string("Unity"))
    #expect(entries[0]["bundleId"] == JSONValue.string("com.unity3d.UnityEditor"))
    #expect(entries[0]["title"] == JSONValue.string("Sample Scene"))
    #expect(entries[0]["kind"] == JSONValue.string("window"))
    #expect(entries[0]["capturable"] == JSONValue.bool(true))
    // One default per owning process, so a per-app answer never needs a second call.
    #expect(entries[0]["default"] == JSONValue.bool(true))
    #expect(entries[1]["default"] == JSONValue.bool(false))
    #expect(entries[2]["default"] == JSONValue.bool(true))
}

@Test func defaultWindowIDsByOwnerPrefersOnScreenWindowPerApp() {
    let windows = [
        testWindow(1, pid: 100, app: "Unity", onScreen: false),
        testWindow(2, pid: 100, app: "Unity"),
        testWindow(3, pid: 200, app: "Finder", onScreen: false),
    ]
    #expect(defaultWindowIDsByOwner(among: windows, displayFrames: testDisplays) == [2, 3])
}

@Test func listedWindowsFiltersNonWindowSurfacesByDefault() {
    let windows = [
        testWindow(1, pid: 100, app: "Steam", title: "Library"),
        testWindow(2, pid: 100, app: "Steam", frame: CGRect(x: -15000, y: 16116, width: 1, height: 1)),
        testWindow(3, pid: 300, app: "SystemUIServer", frame: CGRect(x: 0, y: 0, width: 1728, height: 33)),
        testWindow(4, pid: 400, app: "Dock", layer: 20),
    ]

    let filtered = listedWindows(windows, displayFrames: testDisplays, includeAllSurfaces: false)
    #expect(filtered.map(\.windowID) == [1])

    let all = listedWindows(windows, displayFrames: testDisplays, includeAllSurfaces: true)
    #expect(all.map(\.windowID) == [1, 2, 3, 4])

    let payload = listWindowsPayload(
        all,
        displayFrames: testDisplays,
        defaultWindowIDs: [],
        accessibility: [:]
    )
    let kinds = (payload["windows"]?.arrayValue ?? []).compactMap { $0["kind"]?.stringValue }
    #expect(kinds == ["window", "bookkeeping", "menu_bar", "overlay"])
}

@Test func listWindowsPayloadMergesAccessibilityMetadata() {
    let windows = [
        testWindow(1, pid: 100, app: "Notes", title: "Notes"),
        testWindow(2, pid: 100, app: "Notes", title: "Untitled"),
    ]
    let payload = listWindowsPayload(
        windows,
        displayFrames: testDisplays,
        defaultWindowIDs: [1],
        accessibility: [
            1: AXWindowMetadata(role: "AXWindow", subrole: "AXStandardWindow", minimized: false),
            2: AXWindowMetadata(role: "AXWindow", subrole: "AXDialog", minimized: true),
        ]
    )

    let entries = payload["windows"]?.arrayValue ?? []
    #expect(entries[0]["role"] == JSONValue.string("AXWindow"))
    #expect(entries[0]["subrole"] == JSONValue.string("AXStandardWindow"))
    #expect(entries[0]["minimized"] == JSONValue.bool(false))
    #expect(entries[1]["subrole"] == JSONValue.string("AXDialog"))
    #expect(entries[1]["minimized"] == JSONValue.bool(true))
}

@Test func listWindowsPayloadReportsUnknownAccessibilityStateAsNull() {
    let payload = listWindowsPayload(
        [testWindow(9, pid: 100, app: "Unity")],
        displayFrames: testDisplays,
        defaultWindowIDs: [],
        accessibility: [:]
    )

    let entry = payload["windows"]?[0]
    #expect(entry?["role"] == JSONValue.null)
    #expect(entry?["subrole"] == JSONValue.null)
    // Null, not false: an app with no AX window for this surface has not told us
    // the window is on the desk.
    #expect(entry?["minimized"] == JSONValue.null)
}
