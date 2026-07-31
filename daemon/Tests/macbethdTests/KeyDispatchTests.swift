import Foundation
import Testing
@testable import macbethd

// MARK: - Dispatch failure

@Test func noPostedEventsIsAttemptedNotDispatched() {
    let diagnosis = diagnoseKeyDispatch(
        requestedKeyDowns: 1,
        postedKeyDowns: 0,
        sessionKeyDownDelta: 0,
        accessibilityTrusted: true,
        targetFrontmost: true,
        hasFocusedElement: true
    )

    #expect(diagnosis.outcome == .attempted)
    #expect(diagnosis.warnings.contains("dispatch-failed"))
    #expect(diagnosis.note.contains("nothing was sent"))
    #expect(!diagnosis.note.lowercased().contains("entered the system event stream"))
}

@Test func partialEventCreationIsReportedAgainstTheRequestedCount() {
    let diagnosis = diagnoseKeyDispatch(
        requestedKeyDowns: 4,
        postedKeyDowns: 2,
        sessionKeyDownDelta: 2,
        accessibilityTrusted: true,
        targetFrontmost: true,
        hasFocusedElement: true
    )

    #expect(diagnosis.outcome == .dispatched)
    #expect(diagnosis.warnings.contains("dispatch-incomplete"))
    #expect(diagnosis.note.contains("2 of 4"))
}

// MARK: - Unverifiable dispatch

@Test func postedEventsWithoutCounterMovementStayAttempted() {
    let diagnosis = diagnoseKeyDispatch(
        requestedKeyDowns: 1,
        postedKeyDowns: 1,
        sessionKeyDownDelta: 0,
        accessibilityTrusted: true,
        targetFrontmost: true,
        hasFocusedElement: true
    )

    #expect(diagnosis.outcome == .attempted)
    #expect(diagnosis.warnings.contains("dispatch-unconfirmed"))
    // An unconfirmed dispatch must not read as a hard failure: an agent that sees
    // "failed" resends, and resent keystrokes are worse than an honest caveat.
    #expect(diagnosis.note.contains("Do not resend blindly"))
}

@Test func missingCounterReadingStaysAttempted() {
    let diagnosis = diagnoseKeyDispatch(
        requestedKeyDowns: 1,
        postedKeyDowns: 1,
        sessionKeyDownDelta: nil,
        accessibilityTrusted: true,
        targetFrontmost: true,
        hasFocusedElement: true
    )

    #expect(diagnosis.outcome == .attempted)
    #expect(diagnosis.warnings.contains("dispatch-unconfirmed"))
}

@Test func counterConfirmationPromotesToDispatched() {
    let diagnosis = diagnoseKeyDispatch(
        requestedKeyDowns: 3,
        postedKeyDowns: 3,
        sessionKeyDownDelta: 3,
        accessibilityTrusted: true,
        targetFrontmost: true,
        hasFocusedElement: true
    )

    #expect(diagnosis.outcome == .dispatched)
    #expect(diagnosis.warnings.isEmpty)
    #expect(diagnosis.note.contains("not verified"))
}

@Test func concurrentTypingInflatingTheCounterStillConfirms() {
    // The session counter also counts a human at the keyboard, so a larger delta
    // than we posted confirms dispatch rather than looking like a mismatch.
    let diagnosis = diagnoseKeyDispatch(
        requestedKeyDowns: 1,
        postedKeyDowns: 1,
        sessionKeyDownDelta: 7,
        accessibilityTrusted: true,
        targetFrontmost: true,
        hasFocusedElement: true
    )

    #expect(diagnosis.outcome == .dispatched)
    #expect(diagnosis.warnings.isEmpty)
}

@Test func partialCounterMovementIsDispatchedButFlagged() {
    let diagnosis = diagnoseKeyDispatch(
        requestedKeyDowns: 5,
        postedKeyDowns: 5,
        sessionKeyDownDelta: 2,
        accessibilityTrusted: true,
        targetFrontmost: true,
        hasFocusedElement: true
    )

    #expect(diagnosis.outcome == .dispatched)
    #expect(diagnosis.warnings.contains("dispatch-partially-confirmed"))
}

@Test func effectVerificationIsNeverClaimed() {
    let combinations: [(Int, Int?, Bool, Bool, Bool)] = [
        (1, 1, true, true, true),
        (1, 9, true, true, false),
        (1, 0, false, false, false),
        (1, nil, true, false, true),
    ]

    for (posted, delta, trusted, frontmost, focused) in combinations {
        let diagnosis = diagnoseKeyDispatch(
            requestedKeyDowns: posted,
            postedKeyDowns: posted,
            sessionKeyDownDelta: delta,
            accessibilityTrusted: trusted,
            targetFrontmost: frontmost,
            hasFocusedElement: focused
        )
        #expect(diagnosis.outcome != .verified)
    }
}

// MARK: - Target caveats

@Test func noFocusedTargetIsAnnotatedWithoutFailingTheCall() {
    let diagnosis = diagnoseKeyDispatch(
        requestedKeyDowns: 1,
        postedKeyDowns: 1,
        sessionKeyDownDelta: 1,
        accessibilityTrusted: true,
        targetFrontmost: true,
        hasFocusedElement: false
    )

    #expect(diagnosis.outcome == .dispatched)
    #expect(diagnosis.warnings.contains("no-focused-element"))
    #expect(diagnosis.note.contains("window level"))
}

@Test func backgroundTargetWarnsThatAnotherAppMayHaveReceivedTheKeys() {
    let diagnosis = diagnoseKeyDispatch(
        requestedKeyDowns: 1,
        postedKeyDowns: 1,
        sessionKeyDownDelta: 1,
        accessibilityTrusted: true,
        targetFrontmost: false,
        hasFocusedElement: true
    )

    #expect(diagnosis.outcome == .dispatched)
    #expect(diagnosis.warnings.contains("target-not-frontmost"))
    #expect(diagnosis.note.contains("another app may have received them"))
}

@Test func untrustedProcessGetsActionablePermissionGuidance() {
    let diagnosis = diagnoseKeyDispatch(
        requestedKeyDowns: 1,
        postedKeyDowns: 1,
        sessionKeyDownDelta: 0,
        accessibilityTrusted: false,
        targetFrontmost: true,
        hasFocusedElement: true
    )

    #expect(diagnosis.outcome == .attempted)
    #expect(diagnosis.warnings.contains("accessibility-not-trusted"))
    #expect(diagnosis.note.contains("Privacy & "))
}

// MARK: - Evidence plumbing

@Test func counterDeltaSurvivesUInt32Wraparound() {
    #expect(sessionKeyDownDelta(before: 10, after: 13) == 3)
    #expect(sessionKeyDownDelta(before: UInt32.max - 1, after: 1) == 3)
    #expect(sessionKeyDownDelta(before: 5, after: 5) == 0)
}

@Test func longFocusedValuesAreTruncated() {
    let long = String(repeating: "x", count: 500)
    let truncated = truncateFocusedValue(long)

    #expect(truncated.count == 121)
    #expect(truncated.hasSuffix("…"))
    #expect(truncateFocusedValue("short") == "short")
}

// MARK: - Result payload

@Test func resultPayloadReportsTierAndKeepsLegacyFields() {
    let diagnosis = diagnoseKeyDispatch(
        requestedKeyDowns: 2,
        postedKeyDowns: 2,
        sessionKeyDownDelta: 2,
        accessibilityTrusted: true,
        targetFrontmost: true,
        hasFocusedElement: true
    )
    let payload = keyDispatchResultJSON(
        diagnosis: diagnosis,
        requestedKeyDowns: 2,
        postedKeyDowns: 2,
        sessionKeyDownDelta: 2,
        accessibilityTrusted: true,
        target: .unknown,
        extra: ["count": .number(2)]
    ).objectValue

    #expect(payload?["success"] == .bool(true))
    #expect(payload?["outcome"] == .string("dispatched"))
    #expect(payload?["dispatched"] == .bool(true))
    #expect(payload?["verified"] == .bool(false))
    #expect(payload?["count"] == .number(2))
    #expect(payload?["keysPosted"] == .number(2))
}

@Test func failedDispatchPayloadIsNotSuccessful() {
    let diagnosis = diagnoseKeyDispatch(
        requestedKeyDowns: 1,
        postedKeyDowns: 0,
        sessionKeyDownDelta: 0,
        accessibilityTrusted: true,
        targetFrontmost: true,
        hasFocusedElement: true
    )
    let payload = keyDispatchResultJSON(
        diagnosis: diagnosis,
        requestedKeyDowns: 1,
        postedKeyDowns: 0,
        sessionKeyDownDelta: 0,
        accessibilityTrusted: true,
        target: .unknown,
        extraWarnings: ["app-handle-unknown"]
    ).objectValue

    #expect(payload?["success"] == .bool(false))
    #expect(payload?["outcome"] == .string("attempted"))
    #expect(payload?["dispatched"] == .bool(false))
    if case .array(let warnings)? = payload?["warnings"] {
        #expect(warnings.contains(.string("app-handle-unknown")))
        #expect(warnings.contains(.string("dispatch-failed")))
    } else {
        Issue.record("warnings missing from payload")
    }
}
