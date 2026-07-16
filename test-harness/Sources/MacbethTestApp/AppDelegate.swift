import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var modalWindow: NSWindow?
    var statusLabel: NSTextField!
    var nameField: NSTextField!
    var emailField: NSTextField!
    var textView: NSTextView!
    var popupButton: NSPopUpButton!
    var sliderValueLabel: NSTextField!
    var progressIndicator: NSProgressIndicator!
    var checkbox: NSButton!
    var radioGroup: NSMatrix!
    var segmentedControl: NSSegmentedControl!
    var stepperValueLabel: NSTextField!
    var tableView: NSTableView!
    var gatedActionButton: NSButton!
    var tableData: [String] = ["Alice", "Bob", "Charlie", "Diana", "Eve"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        installDemoMenu()

        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Macbeth TestApp"
        // Create a visible key window without explicitly activating the app.
        // Keyboard-driven Macbeth actions activate it explicitly when needed.
        window.makeKeyAndOrderFront(nil)

        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        window.contentView = scrollView

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1250))
        contentView.autoresizingMask = [.width]
        scrollView.documentView = contentView

        var y: CGFloat = 1210

        // MARK: - Header
        let header = NSTextField(labelWithString: "Macbeth UI Control Playground")
        header.font = NSFont.boldSystemFont(ofSize: 18)
        header.frame = NSRect(x: 20, y: y, width: 560, height: 24)
        header.setAccessibilityIdentifier("header-title")
        contentView.addSubview(header)
        y -= 35

        // MARK: - Text Inputs Section
        let textSection = sectionLabel("Text Inputs", y: y, in: contentView)
        y = textSection

        // Name field
        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        contentView.addSubview(nameLabel)

        nameField = NSTextField(frame: NSRect(x: 110, y: y, width: 200, height: 22))
        nameField.placeholderString = "Enter your name"
        nameField.setAccessibilityIdentifier("name-input")
        nameField.setAccessibilityLabel("Name")
        contentView.addSubview(nameField)
        y -= 35

        // Email field
        let emailLabel = NSTextField(labelWithString: "Email:")
        emailLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        contentView.addSubview(emailLabel)

        emailField = NSTextField(frame: NSRect(x: 110, y: y, width: 200, height: 22))
        emailField.placeholderString = "Enter your email"
        emailField.setAccessibilityIdentifier("email-input")
        emailField.setAccessibilityLabel("Email")
        contentView.addSubview(emailField)
        y -= 35

        // Password field (secure)
        let passwordLabel = NSTextField(labelWithString: "Password:")
        passwordLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        contentView.addSubview(passwordLabel)

        let passwordField = NSSecureTextField(frame: NSRect(x: 110, y: y, width: 200, height: 22))
        passwordField.placeholderString = "Enter password"
        passwordField.setAccessibilityIdentifier("password-input")
        passwordField.setAccessibilityLabel("Password")
        contentView.addSubview(passwordField)
        y -= 45

        // Multi-line text view
        let bioLabel = NSTextField(labelWithString: "Bio:")
        bioLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        contentView.addSubview(bioLabel)

        let textContainer = NSScrollView(frame: NSRect(x: 110, y: y - 60, width: 200, height: 80))
        textContainer.hasVerticalScroller = true
        textContainer.setAccessibilityIdentifier("bio-scroll")
        contentView.addSubview(textContainer)

        textView = NSTextView(frame: textContainer.bounds)
        textView.minSize = NSSize(width: 0, height: 80)
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
        textView.string = "Tell us about yourself..."
        textView.setAccessibilityIdentifier("bio-textarea")
        textView.setAccessibilityLabel("Bio")
        textContainer.documentView = textView
        y -= 95

        // MARK: - Buttons Section
        y -= 10
        let buttonSection = sectionLabel("Buttons", y: y, in: contentView)
        y = buttonSection

        let submitButton = NSButton(title: "Submit", target: self, action: #selector(submitClicked))
        submitButton.frame = NSRect(x: 20, y: y, width: 90, height: 32)
        submitButton.setAccessibilityIdentifier("submit-btn")
        submitButton.bezelStyle = .rounded
        contentView.addSubview(submitButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.frame = NSRect(x: 120, y: y, width: 90, height: 32)
        cancelButton.setAccessibilityIdentifier("cancel-btn")
        cancelButton.bezelStyle = .rounded
        contentView.addSubview(cancelButton)

        let modalButton = NSButton(title: "Show Modal", target: self, action: #selector(showModal))
        modalButton.frame = NSRect(x: 220, y: y, width: 100, height: 32)
        modalButton.setAccessibilityIdentifier("modal-btn")
        modalButton.bezelStyle = .rounded
        contentView.addSubview(modalButton)

        let alertButton = NSButton(title: "Show Alert", target: self, action: #selector(showAlert))
        alertButton.frame = NSRect(x: 330, y: y, width: 100, height: 32)
        alertButton.setAccessibilityIdentifier("alert-btn")
        alertButton.bezelStyle = .rounded
        contentView.addSubview(alertButton)
        y -= 45

        // MARK: - Selection Controls Section
        y -= 10
        let selectionSection = sectionLabel("Selection Controls", y: y, in: contentView)
        y = selectionSection

        // Checkbox
        checkbox = NSButton(checkboxWithTitle: "Enable notifications", target: self, action: #selector(checkboxToggled))
        checkbox.frame = NSRect(x: 20, y: y, width: 200, height: 22)
        checkbox.setAccessibilityIdentifier("notifications-checkbox")
        contentView.addSubview(checkbox)
        y -= 35

        // Radio buttons
        let radioLabel = NSTextField(labelWithString: "Theme:")
        radioLabel.frame = NSRect(x: 20, y: y, width: 60, height: 22)
        contentView.addSubview(radioLabel)

        radioControl = NSButton(frame: NSRect(x: 90, y: y, width: 80, height: 22))
        radioControl.title = "Light"
        radioControl.setButtonType(.radio)
        radioControl.target = self
        radioControl.action = #selector(radioChanged)
        radioControl.setAccessibilityIdentifier("theme-light")
        contentView.addSubview(radioControl)

        radioControl2 = NSButton(frame: NSRect(x: 180, y: y, width: 80, height: 22))
        radioControl2.title = "Dark"
        radioControl2.setButtonType(.radio)
        radioControl2.target = self
        radioControl2.action = #selector(radioChanged)
        radioControl2.setAccessibilityIdentifier("theme-dark")
        contentView.addSubview(radioControl2)

        radioControl3 = NSButton(frame: NSRect(x: 270, y: y, width: 80, height: 22))
        radioControl3.title = "Auto"
        radioControl3.setButtonType(.radio)
        radioControl3.state = .on
        radioControl3.target = self
        radioControl3.action = #selector(radioChanged)
        radioControl3.setAccessibilityIdentifier("theme-auto")
        contentView.addSubview(radioControl3)
        y -= 40

        // Popup button (dropdown)
        let popupLabel = NSTextField(labelWithString: "Country:")
        popupLabel.frame = NSRect(x: 20, y: y, width: 70, height: 22)
        contentView.addSubview(popupLabel)

        popupButton = NSPopUpButton(frame: NSRect(x: 100, y: y, width: 180, height: 26))
        popupButton.addItems(withTitles: ["United States", "Canada", "United Kingdom", "Germany", "France", "Poland", "Japan"])
        popupButton.setAccessibilityIdentifier("country-dropdown")
        popupButton.setAccessibilityLabel("Country")
        popupButton.target = self
        popupButton.action = #selector(popupChanged)
        contentView.addSubview(popupButton)
        y -= 50

        // MARK: - Sliders & Steppers Section
        y -= 10
        let sliderSection = sectionLabel("Sliders & Steppers", y: y, in: contentView)
        y = sliderSection

        // Slider
        let sliderLabel = NSTextField(labelWithString: "Volume:")
        sliderLabel.frame = NSRect(x: 20, y: y, width: 60, height: 22)
        contentView.addSubview(sliderLabel)

        let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: self, action: #selector(sliderChanged))
        slider.frame = NSRect(x: 90, y: y, width: 200, height: 22)
        slider.setAccessibilityIdentifier("volume-slider")
        slider.setAccessibilityLabel("Volume")
        contentView.addSubview(slider)

        sliderValueLabel = NSTextField(labelWithString: "50")
        sliderValueLabel.frame = NSRect(x: 300, y: y, width: 60, height: 22)
        sliderValueLabel.setAccessibilityIdentifier("volume-value")
        contentView.addSubview(sliderValueLabel)
        y -= 35

        // Progress bar
        let progressLabel = NSTextField(labelWithString: "Progress:")
        progressLabel.frame = NSRect(x: 20, y: y, width: 60, height: 22)
        contentView.addSubview(progressLabel)

        progressIndicator = NSProgressIndicator(frame: NSRect(x: 90, y: y + 2, width: 200, height: 16))
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.doubleValue = 35
        progressIndicator.setAccessibilityIdentifier("progress-bar")
        contentView.addSubview(progressIndicator)

        let progressButton = NSButton(title: "Advance", target: self, action: #selector(advanceProgress))
        progressButton.frame = NSRect(x: 300, y: y, width: 80, height: 22)
        progressButton.setAccessibilityIdentifier("advance-progress-btn")
        contentView.addSubview(progressButton)
        y -= 35

        // Stepper
        let stepperLabel = NSTextField(labelWithString: "Count:")
        stepperLabel.frame = NSRect(x: 20, y: y, width: 60, height: 22)
        contentView.addSubview(stepperLabel)

        let stepper = NSStepper(frame: NSRect(x: 80, y: y, width: 20, height: 22))
        stepper.minValue = 0
        stepper.maxValue = 100
        stepper.intValue = 5
        stepper.setAccessibilityIdentifier("count-stepper")
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        contentView.addSubview(stepper)

        stepperValueLabel = NSTextField(labelWithString: "5")
        stepperValueLabel.frame = NSRect(x: 110, y: y, width: 50, height: 22)
        stepperValueLabel.setAccessibilityIdentifier("count-value")
        contentView.addSubview(stepperValueLabel)

        // Segmented control
        segmentedControl = NSSegmentedControl(labels: ["Small", "Medium", "Large"], trackingMode: .selectOne, target: self, action: #selector(segmentChanged))
        segmentedControl.frame = NSRect(x: 200, y: y, width: 200, height: 24)
        segmentedControl.selectedSegment = 1
        segmentedControl.setAccessibilityIdentifier("size-segmented")
        contentView.addSubview(segmentedControl)
        y -= 55

        // MARK: - Tabs Section
        y -= 10
        let tabSection = sectionLabel("Tabs", y: y, in: contentView)
        y = tabSection

        let tabView = NSTabView(frame: NSRect(x: 20, y: y - 100, width: 560, height: 110))
        tabView.setAccessibilityIdentifier("settings-tabs")

        // General tab
        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"
        let generalView = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 70))
        let generalCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
        generalCheckbox.frame = NSRect(x: 10, y: 35, width: 200, height: 22)
        generalCheckbox.setAccessibilityIdentifier("launch-login-checkbox")
        generalView.addSubview(generalCheckbox)
        let generalCheckbox2 = NSButton(checkboxWithTitle: "Keep in dock", target: nil, action: nil)
        generalCheckbox2.frame = NSRect(x: 10, y: 10, width: 200, height: 22)
        generalCheckbox2.setAccessibilityIdentifier("keep-dock-checkbox")
        generalView.addSubview(generalCheckbox2)
        generalTab.view = generalView
        tabView.addTabViewItem(generalTab)

        // Appearance tab
        let appearanceTab = NSTabViewItem(identifier: "appearance")
        appearanceTab.label = "Appearance"
        let appearanceView = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 70))
        let fontSizeLabel = NSTextField(labelWithString: "Font size:")
        fontSizeLabel.frame = NSRect(x: 10, y: 35, width: 70, height: 22)
        appearanceView.addSubview(fontSizeLabel)
        let fontSizeSlider = NSSlider(value: 14, minValue: 10, maxValue: 24, target: nil, action: nil)
        fontSizeSlider.frame = NSRect(x: 90, y: 35, width: 200, height: 22)
        fontSizeSlider.setAccessibilityIdentifier("font-size-slider")
        appearanceView.addSubview(fontSizeSlider)
        appearanceTab.view = appearanceView
        tabView.addTabViewItem(appearanceTab)

        // Network tab
        let networkTab = NSTabViewItem(identifier: "network")
        networkTab.label = "Network"
        let networkView = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 70))
        let proxyLabel = NSTextField(labelWithString: "Proxy URL:")
        proxyLabel.frame = NSRect(x: 10, y: 35, width: 70, height: 22)
        networkView.addSubview(proxyLabel)
        let proxyField = NSTextField(frame: NSRect(x: 90, y: 35, width: 300, height: 22))
        proxyField.placeholderString = "http://proxy.example.com:8080"
        proxyField.setAccessibilityIdentifier("proxy-input")
        networkView.addSubview(proxyField)
        networkTab.view = networkView
        tabView.addTabViewItem(networkTab)

        contentView.addSubview(tabView)
        y -= 120

        // MARK: - Table Section
        y -= 10
        let tableSection = sectionLabel("List / Table", y: y, in: contentView)
        y = tableSection

        let tableScrollView = NSScrollView(frame: NSRect(x: 20, y: y - 120, width: 300, height: 120))
        tableScrollView.hasVerticalScroller = true
        tableScrollView.setAccessibilityIdentifier("users-table-scroll")
        contentView.addSubview(tableScrollView)

        tableView = NSTableView(frame: tableScrollView.bounds)
        tableView.setAccessibilityIdentifier("users-table")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Users"
        column.width = 280
        tableView.addTableColumn(column)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 20
        tableScrollView.documentView = tableView

        let addUserButton = NSButton(title: "Add User", target: self, action: #selector(addUser))
        addUserButton.frame = NSRect(x: 340, y: y - 30, width: 90, height: 32)
        addUserButton.setAccessibilityIdentifier("add-user-btn")
        contentView.addSubview(addUserButton)

        let removeUserButton = NSButton(title: "Remove", target: self, action: #selector(removeUser))
        removeUserButton.frame = NSRect(x: 340, y: y - 70, width: 90, height: 32)
        removeUserButton.setAccessibilityIdentifier("remove-user-btn")
        contentView.addSubview(removeUserButton)

        let clearButton = NSButton(title: "Clear All", target: self, action: #selector(clearUsers))
        clearButton.frame = NSRect(x: 340, y: y - 110, width: 90, height: 32)
        clearButton.setAccessibilityIdentifier("clear-users-btn")
        contentView.addSubview(clearButton)
        y -= 140

        // MARK: - Status Section
        y -= 10
        let statusSection = sectionLabel("Status", y: y, in: contentView)
        y = statusSection

        statusLabel = NSTextField(labelWithString: "Status: Ready")
        statusLabel.frame = NSRect(x: 20, y: y, width: 560, height: 22)
        statusLabel.setAccessibilityIdentifier("status-label")
        contentView.addSubview(statusLabel)
        y -= 42

        let enableActionButton = NSButton(title: "Enable Action", target: self, action: #selector(enableGatedAction))
        enableActionButton.frame = NSRect(x: 20, y: y, width: 120, height: 32)
        enableActionButton.setAccessibilityIdentifier("enable-action-btn")
        contentView.addSubview(enableActionButton)

        gatedActionButton = NSButton(title: "Complete Demo", target: self, action: #selector(runGatedAction))
        gatedActionButton.frame = NSRect(x: 155, y: y, width: 120, height: 32)
        gatedActionButton.setAccessibilityIdentifier("gated-action-btn")
        gatedActionButton.isEnabled = false
        contentView.addSubview(gatedActionButton)

    }

    // MARK: - Radio button references
    var radioControl: NSButton!
    var radioControl2: NSButton!
    var radioControl3: NSButton!

    // MARK: - Helpers
    func sectionLabel(_ title: String, y: CGFloat, in view: NSView) -> CGFloat {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.boldSystemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: y, width: 560, height: 18)
        view.addSubview(label)
        return y - 28
    }

    func installDemoMenu() {
        let mainMenu = NSMenu(title: "Main Menu")

        let appMenuItem = NSMenuItem()
        appMenuItem.title = "Macbeth TestApp"
        let appMenu = NSMenu(title: "Macbeth TestApp")
        appMenu.addItem(withTitle: "Quit Macbeth TestApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let demoMenuItem = NSMenuItem()
        demoMenuItem.title = "Demo"
        let demoMenu = NSMenu(title: "Demo")
        let resetItem = NSMenuItem(title: "Reset Demo", action: #selector(resetDemo(_:)), keyEquivalent: "r")
        resetItem.keyEquivalentModifierMask = [.command, .shift]
        resetItem.target = self
        demoMenu.addItem(resetItem)
        demoMenuItem.submenu = demoMenu
        mainMenu.addItem(demoMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions
    @MainActor @objc func submitClicked() {
        statusLabel.stringValue = "Status: Submitted – \(nameField.stringValue), \(emailField.stringValue)"
    }

    @MainActor @objc func cancelClicked() {
        nameField.stringValue = ""
        emailField.stringValue = ""
        statusLabel.stringValue = "Status: Cancelled"
    }

    @MainActor @objc func checkboxToggled(_ sender: NSButton) {
        statusLabel.stringValue = "Status: Notifications \(sender.state == .on ? "enabled" : "disabled")"
    }

    @MainActor @objc func radioChanged(_ sender: NSButton) {
        [radioControl, radioControl2, radioControl3].forEach { $0?.state = .off }
        sender.state = .on
        statusLabel.stringValue = "Status: Theme set to \(sender.title)"
    }

    @MainActor @objc func popupChanged(_ sender: NSPopUpButton) {
        statusLabel.stringValue = "Status: Country selected – \(sender.titleOfSelectedItem ?? "")"
    }

    @MainActor @objc func sliderChanged(_ sender: NSSlider) {
        sliderValueLabel.stringValue = "\(Int(sender.doubleValue))"
        statusLabel.stringValue = "Status: Volume set to \(Int(sender.doubleValue))"
    }

    @MainActor @objc func stepperChanged(_ sender: NSStepper) {
        stepperValueLabel.stringValue = "\(sender.intValue)"
        statusLabel.stringValue = "Status: Count set to \(sender.intValue)"
    }

    @MainActor @objc func segmentChanged(_ sender: NSSegmentedControl) {
        let sizes = ["Small", "Medium", "Large"]
        statusLabel.stringValue = "Status: Size selected – \(sizes[sender.selectedSegment])"
    }

    @MainActor @objc func advanceProgress() {
        let newValue = min(progressIndicator.doubleValue + 10, 100)
        progressIndicator.doubleValue = newValue
        statusLabel.stringValue = "Status: Progress at \(Int(newValue))%"
    }

    @MainActor @objc func addUser() {
        let names = ["Frank", "Grace", "Henry", "Ivy", "Jack"]
        let newName = names.randomElement() ?? "User"
        tableData.append("\(newName) \(Int.random(in: 1...99))")
        tableView.reloadData()
        statusLabel.stringValue = "Status: Added user \(newName)"
    }

    @MainActor @objc func removeUser() {
        if tableData.isEmpty { return }
        tableData.removeLast()
        tableView.reloadData()
        statusLabel.stringValue = "Status: Removed last user"
    }

    @MainActor @objc func clearUsers() {
        tableData.removeAll()
        tableView.reloadData()
        statusLabel.stringValue = "Status: Cleared all users"
    }

    @MainActor @objc func enableGatedAction() {
        gatedActionButton.isEnabled = true
        statusLabel.stringValue = "Status: Complete Demo enabled"
    }

    @MainActor @objc func runGatedAction() {
        statusLabel.stringValue = "Status: Gated action completed"
    }

    @MainActor @objc func resetDemo(_ sender: Any?) {
        nameField.stringValue = ""
        emailField.stringValue = ""
        textView.string = "Tell us about yourself..."
        checkbox.state = .off
        [radioControl, radioControl2].forEach { $0?.state = .off }
        radioControl3.state = .on
        popupButton.selectItem(at: 0)
        tableData = ["Alice", "Bob", "Charlie", "Diana", "Eve"]
        tableView.reloadData()
        gatedActionButton.isEnabled = false
        statusLabel.stringValue = "Status: Demo reset from menu"
    }

    @MainActor @objc func showAlert() {
        let alert = NSAlert()
        alert.messageText = "Confirm Action"
        alert.informativeText = "Are you sure you want to proceed with this action?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        alert.buttons[0].setAccessibilityIdentifier("alert-ok")
        alert.buttons[1].setAccessibilityIdentifier("alert-cancel")
        alert.buttons[2].setAccessibilityIdentifier("alert-delete")
        // NOTE: NSAlert has no setAccessibilityIdentifier; left off intentionally — addressing this is tracked as a separate bug

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            statusLabel.stringValue = "Status: Alert – OK clicked"
        case .alertSecondButtonReturn:
            statusLabel.stringValue = "Status: Alert – Cancel clicked"
        case .alertThirdButtonReturn:
            statusLabel.stringValue = "Status: Alert – Delete clicked"
        default:
            break
        }
    }

    @MainActor @objc func showModal() {
        modalWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        modalWindow?.title = "Modal Dialog"
        modalWindow?.setAccessibilityIdentifier("modal-window")

        let modalContent = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))

        let infoLabel = NSTextField(labelWithString: "This is a modal window")
        infoLabel.frame = NSRect(x: 20, y: 120, width: 260, height: 22)
        infoLabel.alignment = .center
        modalContent.addSubview(infoLabel)

        let modalTextField = NSTextField(frame: NSRect(x: 30, y: 80, width: 240, height: 22))
        modalTextField.placeholderString = "Type something..."
        modalTextField.setAccessibilityIdentifier("modal-text-input")
        modalContent.addSubview(modalTextField)

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeModal))
        closeButton.frame = NSRect(x: 100, y: 30, width: 100, height: 32)
        closeButton.setAccessibilityIdentifier("modal-close-btn")
        closeButton.bezelStyle = .rounded
        modalContent.addSubview(closeButton)

        modalWindow?.contentView = modalContent
        modalWindow?.center()

        NSApp.runModal(for: modalWindow!)
    }

    @MainActor @objc func closeModal() {
        if let modal = modalWindow {
            NSApp.stopModal()
            modal.orderOut(nil)
            modalWindow = nil
        }
        statusLabel.stringValue = "Status: Modal closed"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Table View Data Source & Delegate
extension AppDelegate: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return tableData.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        return tableData[row]
    }
}
