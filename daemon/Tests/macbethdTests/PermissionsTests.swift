import Foundation
import Testing
@testable import macbethd

private struct CaptureContentTestError: LocalizedError {
    var errorDescription: String? { "capture service unavailable" }
}

@Test func deniedScreenCaptureProvidesHostAppGuidance() {
    let error = screenCaptureContentError(
        CaptureContentTestError(),
        permissionGranted: false,
        settingsOpened: true
    ).toJSONRPC()

    #expect(error.code == -32002)
    #expect(error.message.contains("System Settings was opened"))
    #expect(error.message.contains("app that launched Macbeth"))
    #expect(error.message.contains("fully quit and relaunch"))
}

@Test func authorizedScreenCaptureFailurePreservesSystemError() {
    let error = screenCaptureContentError(
        CaptureContentTestError(),
        permissionGranted: true,
        settingsOpened: false
    ).toJSONRPC()

    #expect(error.code == -32004)
    #expect(error.message.contains("capture service unavailable"))
    #expect(!error.message.contains("Screen Recording permission"))
}

@Test func deniedScreenCaptureDoesNotClaimSettingsOpenedWhenItFailed() {
    let error = screenCaptureContentError(
        CaptureContentTestError(),
        permissionGranted: false,
        settingsOpened: false
    ).toJSONRPC()

    #expect(error.code == -32002)
    #expect(error.message.contains("Open System Settings"))
    #expect(!error.message.contains("System Settings was opened"))
}
