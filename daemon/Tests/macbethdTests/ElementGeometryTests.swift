import CoreGraphics
import Testing
@testable import macbethd

@Test func elementCenterComputesMidpoint() throws {
    let center = try ElementGeometry.center(
        position: CGPoint(x: 100, y: 200),
        size: CGSize(width: 40, height: 20)
    )
    #expect(center == CGPoint(x: 120, y: 210))
}

@Test func elementCenterRejectsDegenerateAndNonFiniteFrames() {
    #expect(throws: ElementGeometry.GeometryError.self) {
        _ = try ElementGeometry.center(
            position: CGPoint(x: 10, y: 10), size: CGSize(width: 0, height: 20))
    }
    #expect(throws: ElementGeometry.GeometryError.self) {
        _ = try ElementGeometry.center(
            position: CGPoint(x: CGFloat.infinity, y: 10), size: CGSize(width: 20, height: 20))
    }
}

@Test func elementCenterAcceptsNegativeDisplayCoordinates() throws {
    let center = try ElementGeometry.center(
        position: CGPoint(x: -1920, y: -300),
        size: CGSize(width: 200, height: 100)
    )
    #expect(center == CGPoint(x: -1820, y: -250))
}

@Test func pointerTargetMustBelongToControlledWindow() {
    let window = CGRect(x: 400, y: 200, width: 900, height: 700)
    #expect(ElementGeometry.isPlausibleInteraction(
        point: CGPoint(x: 700, y: 500), inside: window
    ))
    #expect(ElementGeometry.isPlausibleInteraction(
        point: CGPoint(x: 380, y: 190), inside: window
    ))
    #expect(!ElementGeometry.isPlausibleInteraction(
        point: CGPoint(x: 0, y: 0), inside: window
    ))
}

@Test func windowIdentityMatchesScreenCaptureWindowIdentity() {
    #expect(
        ElementGeometry.windowIdentity(pid: 123, windowNumber: 456)
            == "pid:123:window:456"
    )
    #expect(
        ElementGeometry.windowIdentity(pid: 123, windowNumber: 456)
            != ElementGeometry.windowIdentity(pid: 123, windowNumber: 457)
    )
}
