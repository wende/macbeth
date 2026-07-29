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
