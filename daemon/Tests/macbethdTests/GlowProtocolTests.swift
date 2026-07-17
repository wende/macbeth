import Testing
import Foundation
@testable import GlowProtocol

// MARK: - Wire protocol

@Test func activateRoundTrips() throws {
    let message = GlowMessage.activate(color: "#BD5CF3", debounceMs: 100)
    let line = try message.encodedLine()
    #expect(line.last == 0x0A) // newline-terminated
    let decoded = try GlowMessage.decode(line: line)
    #expect(decoded == message)
    #expect(decoded.type == .activate)
    #expect(decoded.color == "#BD5CF3")
    #expect(decoded.debounceMs == 100)
}

@Test func deactivateAndShutdownRoundTrip() throws {
    for message in [GlowMessage.deactivate, GlowMessage.shutdown] {
        let decoded = try GlowMessage.decode(line: message.encodedLine())
        #expect(decoded == message)
        #expect(decoded.color == nil)
        #expect(decoded.debounceMs == nil)
    }
}

@Test func captureAnimationMessagesRoundTrip() throws {
    let rect = GlowCaptureRect(x: 12, y: 34, width: 800, height: 600)
    let started = GlowMessage.captureStarted(id: "capture-1", rect: rect)
    let decodedStart = try GlowMessage.decode(line: started.encodedLine())
    #expect(decodedStart == started)
    #expect(decodedStart.rect == rect)

    let finished = GlowMessage.captureFinished(id: "capture-1", success: true)
    let decodedFinish = try GlowMessage.decode(line: finished.encodedLine())
    #expect(decodedFinish == finished)
    #expect(decodedFinish.success == true)
}

@Test func windowFocusMessageRoundTrips() throws {
    let rect = GlowCaptureRect(x: -200, y: 40, width: 640, height: 480)
    let message = GlowMessage.windowFocused(id: "pid:42:window:7", rect: rect)
    let decoded = try GlowMessage.decode(line: message.encodedLine())
    #expect(decoded == message)
    #expect(decoded.type == .focusWindow)
    #expect(decoded.windowId == "pid:42:window:7")
    #expect(decoded.rect == rect)
}

@Test func pointerMoveMessageRoundTrips() throws {
    let point = GlowPointerPoint(x: -120, y: 340)
    let message = GlowMessage.pointerMoved(to: point, action: .fill)
    let decoded = try GlowMessage.decode(line: message.encodedLine())
    #expect(decoded == message)
    #expect(decoded.type == .pointerMove)
    #expect(decoded.point == point)
    #expect(decoded.action == .fill)
}

@Test func decodesMinimalActivateWithoutConfig() throws {
    let json = Data(#"{"type":"activate"}"#.utf8)
    let decoded = try GlowMessage.decode(line: json)
    #expect(decoded.type == .activate)
    #expect(decoded.color == nil)
    #expect(decoded.debounceMs == nil)
}

@Test func wireFormatIsStable() throws {
    let line = try GlowMessage.shutdown.encodedLine()
    let text = String(data: line, encoding: .utf8)
    #expect(text == "{\"type\":\"shutdown\"}\n")
}

// MARK: - Debounce logic

@Test func debounceKeepsActiveWithinWindow() {
    var tracker = GlowActivityTracker(debounceMs: 1500)
    let t0 = Date(timeIntervalSinceReferenceDate: 0)

    #expect(tracker.isActive(at: t0) == false)

    let becameActive = tracker.poke(at: t0)
    #expect(becameActive == true)
    #expect(tracker.isActive(at: t0.addingTimeInterval(1.0)) == true)
    #expect(tracker.isActive(at: t0.addingTimeInterval(1.4)) == true)
}

@Test func debounceExpiresAfterWindow() {
    var tracker = GlowActivityTracker(debounceMs: 1500)
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    tracker.poke(at: t0)

    #expect(tracker.isActive(at: t0.addingTimeInterval(1.5)) == false)
    #expect(tracker.isActive(at: t0.addingTimeInterval(2.0)) == false)
}

@Test func rapidBurstStaysContinuous() {
    // 50 pokes 10ms apart, then check the glow is still lit 1.4s after the last
    // one and only the very first poke reported an idle→active transition.
    var tracker = GlowActivityTracker(debounceMs: 1500)
    let start = Date(timeIntervalSinceReferenceDate: 0)

    var transitions = 0
    var last = start
    for i in 0..<50 {
        last = start.addingTimeInterval(Double(i) * 0.01)
        if tracker.poke(at: last) { transitions += 1 }
    }

    #expect(transitions == 1) // no flicker: single activation for the whole burst
    #expect(tracker.isActive(at: last.addingTimeInterval(1.4)) == true)
    #expect(tracker.isActive(at: last.addingTimeInterval(1.6)) == false)
}

@Test func fadeOutDeadlineTracksLastPoke() {
    var tracker = GlowActivityTracker(debounceMs: 1500)
    #expect(tracker.fadeOutDeadline() == nil)

    let t0 = Date(timeIntervalSinceReferenceDate: 100)
    tracker.poke(at: t0)
    #expect(tracker.fadeOutDeadline() == t0.addingTimeInterval(1.5))

    let t1 = t0.addingTimeInterval(0.5)
    tracker.poke(at: t1)
    #expect(tracker.fadeOutDeadline() == t1.addingTimeInterval(1.5))
}

@Test func resetForcesIdle() {
    var tracker = GlowActivityTracker(debounceMs: 1500)
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    tracker.poke(at: t0)
    tracker.reset()
    #expect(tracker.isActive(at: t0) == false)
    #expect(tracker.fadeOutDeadline() == nil)
}

// MARK: - Color parsing

@Test func defaultGlowUsesBrandAccent() {
    #expect(glowDefaultColor == "#8B3342")
    #expect(glowDefaultDebounceMs == 400)
    #expect(glowWindowFadeDuration == 0.1)
    #expect(glowCapturePresentationDuration > glowCaptureScanDuration)
}

@Test func fadeDelayRefreshesForAnotherEndRequest() {
    var tracker = GlowActivityTracker(debounceMs: 400)
    let firstEnd = Date(timeIntervalSinceReferenceDate: 10)
    tracker.poke(at: firstEnd)
    #expect(tracker.fadeOutDeadline() == firstEnd.addingTimeInterval(0.4))

    let secondEnd = firstEnd.addingTimeInterval(0.075)
    tracker.poke(at: secondEnd)
    #expect(tracker.fadeOutDeadline() == secondEnd.addingTimeInterval(0.4))
    #expect(tracker.isActive(at: firstEnd.addingTimeInterval(0.11)))
}

@Test func parsesSixDigitHex() {
    let rgba = parseGlowColor("#BD5CF3")
    #expect(rgba != nil)
    #expect(abs((rgba?.red ?? 0) - 0xBD / 255.0) < 0.0001)
    #expect(abs((rgba?.green ?? 0) - 0x5C / 255.0) < 0.0001)
    #expect(abs((rgba?.blue ?? 0) - 0xF3 / 255.0) < 0.0001)
    #expect(rgba?.alpha == 1.0)
}

@Test func parsesShorthandAndAlpha() {
    #expect(parseGlowColor("#fff") == GlowRGBA(red: 1, green: 1, blue: 1, alpha: 1))
    let half = parseGlowColor("#00000080")
    #expect(half != nil)
    #expect(abs((half?.alpha ?? 0) - 0x80 / 255.0) < 0.0001)
}

@Test func rejectsMalformedHex() {
    #expect(parseGlowColor("nope") == nil)
    #expect(parseGlowColor("#12") == nil)
    #expect(parseGlowColor("#GGGGGG") == nil)
    #expect(parseGlowColor("") == nil)
}
