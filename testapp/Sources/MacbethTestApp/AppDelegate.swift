import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusLabel: NSTextField!
    var nameField: NSTextField!
    var emailField: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create window
        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 400, height: 350),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacbethTest"
        window.makeKeyAndOrderFront(nil)

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        var y: CGFloat = 290

        // Name label + field
        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 20, y: y, width: 60, height: 22)
        contentView.addSubview(nameLabel)

        nameField = NSTextField(frame: NSRect(x: 90, y: y, width: 280, height: 22))
        nameField.placeholderString = "Enter name"
        nameField.setAccessibilityIdentifier("name-input")
        nameField.setAccessibilityLabel("Name")
        contentView.addSubview(nameField)

        y -= 40

        // Email label + field
        let emailLabel = NSTextField(labelWithString: "Email:")
        emailLabel.frame = NSRect(x: 20, y: y, width: 60, height: 22)
        contentView.addSubview(emailLabel)

        emailField = NSTextField(frame: NSRect(x: 90, y: y, width: 280, height: 22))
        emailField.placeholderString = "Enter email"
        emailField.setAccessibilityIdentifier("email-input")
        emailField.setAccessibilityLabel("Email")
        contentView.addSubview(emailField)

        y -= 50

        // Buttons
        let submitButton = NSButton(title: "Submit", target: self, action: #selector(submitClicked))
        submitButton.frame = NSRect(x: 90, y: y, width: 100, height: 32)
        submitButton.setAccessibilityIdentifier("submit-btn")
        contentView.addSubview(submitButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.frame = NSRect(x: 200, y: y, width: 100, height: 32)
        cancelButton.setAccessibilityIdentifier("cancel-btn")
        contentView.addSubview(cancelButton)

        y -= 50

        // Tab view
        let tabView = NSTabView(frame: NSRect(x: 20, y: y - 60, width: 360, height: 100))

        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"
        let generalView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 60))
        let checkbox = NSButton(checkboxWithTitle: "Enable notifications", target: nil, action: nil)
        checkbox.frame = NSRect(x: 10, y: 20, width: 200, height: 22)
        generalView.addSubview(checkbox)
        generalTab.view = generalView
        tabView.addTabViewItem(generalTab)

        let advancedTab = NSTabViewItem(identifier: "advanced")
        advancedTab.label = "Advanced"
        let advancedView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 60))
        let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
        slider.frame = NSRect(x: 10, y: 20, width: 200, height: 22)
        slider.setAccessibilityLabel("Volume")
        advancedView.addSubview(slider)
        advancedTab.view = advancedView
        tabView.addTabViewItem(advancedTab)

        contentView.addSubview(tabView)

        y -= 120

        // Status label
        statusLabel = NSTextField(labelWithString: "Status: Ready")
        statusLabel.frame = NSRect(x: 20, y: y, width: 360, height: 22)
        statusLabel.setAccessibilityIdentifier("status-label")
        contentView.addSubview(statusLabel)

        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor @objc func submitClicked() {
        statusLabel.stringValue = "Status: Submitted (\(nameField.stringValue))"
    }

    @MainActor @objc func cancelClicked() {
        nameField.stringValue = ""
        emailField.stringValue = ""
        statusLabel.stringValue = "Status: Cancelled"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
