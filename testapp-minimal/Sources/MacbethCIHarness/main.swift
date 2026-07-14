import AppKit
import Foundation

// MARK: - Constants (the e2e test depends on these strings verbatim)

let kWindowTitle = "Macbeth CI Harness"
let kNameFieldID = "ci-name-input"
let kNameFieldInitialValue = "initial-name"
let kStatusLabelID = "ci-status-label"
let kStatusInitialValue = "ready"
let kSubmitButtonID = "ci-submit-btn"
let kSubmitButtonLabel = "Submit"

final class HarnessDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var nameField: NSTextField!
    var statusLabel: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 200, y: 200, width: 360, height: 140)
        let win = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = kWindowTitle
        win.isReleasedWhenClosed = false
        self.window = win

        let content = NSView(frame: frame)

        let nameField = NSTextField(frame: NSRect(x: 20, y: 80, width: 320, height: 24))
        nameField.stringValue = kNameFieldInitialValue
        nameField.setAccessibilityIdentifier(kNameFieldID)
        nameField.setAccessibilityLabel("Name")
        content.addSubview(nameField)
        self.nameField = nameField

        let submitButton = NSButton(
            title: kSubmitButtonLabel,
            target: self,
            action: #selector(submitClicked)
        )
        submitButton.frame = NSRect(x: 20, y: 40, width: 100, height: 28)
        submitButton.bezelStyle = .rounded
        submitButton.setAccessibilityIdentifier(kSubmitButtonID)
        submitButton.setAccessibilityLabel(kSubmitButtonLabel)
        content.addSubview(submitButton)

        let status = NSTextField(labelWithString: kStatusInitialValue)
        status.frame = NSRect(x: 20, y: 14, width: 320, height: 20)
        status.setAccessibilityIdentifier(kStatusLabelID)
        status.setAccessibilityLabel("Status")
        content.addSubview(status)
        self.statusLabel = status

        win.contentView = content
        win.makeKeyAndOrderFront(nil)
        win.center()

        NSApp.activate(ignoringOtherApps: true)

        // Stdout marker for the harness side of the smoke check.
        FileHandle.standardOutput.write(Data("ci-harness-ready\n".utf8))
    }

    @MainActor @objc func submitClicked() {
        let name = nameField.stringValue
        statusLabel.stringValue = "submitted:\(name)"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = HarnessDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()