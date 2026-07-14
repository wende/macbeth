import CoreGraphics
import Testing
@testable import macbethd

@Test func clickCenterComputesMidpoint() throws {
    let center = try clickCenter(position: CGPoint(x: 100, y: 200), size: CGSize(width: 40, height: 20))
    #expect(center.x == 120)
    #expect(center.y == 210)
}

@Test func clickCenterRejectsZeroSize() {
    // Zero-size frame must be rejected — never click at (0,0) / a degenerate point.
    #expect(throws: FrameGeometryError.self) {
        _ = try clickCenter(position: CGPoint(x: 10, y: 10), size: CGSize(width: 0, height: 0))
    }
    #expect(throws: FrameGeometryError.self) {
        _ = try clickCenter(position: CGPoint(x: 10, y: 10), size: CGSize(width: 40, height: 0))
    }
    #expect(throws: FrameGeometryError.self) {
        _ = try clickCenter(position: CGPoint(x: 10, y: 10), size: CGSize(width: 0, height: 20))
    }
}

@Test func clickCenterAcceptsNegativeCoordinates() throws {
    // Displays positioned left of / above the main display produce legitimate
    // negative global coordinates. These must pass validation (no flip math,
    // no rejection).
    let center = try clickCenter(position: CGPoint(x: -1920, y: -300), size: CGSize(width: 200, height: 100))
    #expect(center.x == -1820)
    #expect(center.y == -250)
}

@Test func clickStrategyParsingDefaultsToAuto() {
    #expect(ClickStrategy.parse(nil) == .auto)
    #expect(ClickStrategy.parse("nonsense") == .auto)
    #expect(ClickStrategy.parse("auto") == .auto)
    #expect(ClickStrategy.parse("ax") == .ax)
    #expect(ClickStrategy.parse("flash") == .flash)
}
