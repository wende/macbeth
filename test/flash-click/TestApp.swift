// FlashClickTestApp — a minimal AppKit app for exercising the flash-click path.
//
// It exposes two clickable targets:
//   1. A custom NSView ("canvas") that draws a filled rectangle and increments a
//      counter on mouseDown, but deliberately advertises NO AXPress action
//      (plain NSView, not accessible) — so an AX-based click cannot drive it and
//      the "auto" strategy must escalate to the flash click.
//   2. A standard NSButton, which exposes AXPress normally.
//
// Click state is published in the window title so an automation harness can read
// it back over the Accessibility API:
//   "FlashClickTestApp — canvas:<N> button:<M>"
//
// Run (macOS only, requires a GUI session):
//   swift test/flash-click/TestApp.swift
//
// This cannot run in CI (needs a window server + Accessibility permissions).

import AppKit

final class CanvasView: NSView {
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    // The view IS visible to Accessibility (so a locator can find it and read a
    // real frame), but it advertises the neutral "group" role and NO actions —
    // in particular no AXPress. That is the whole point: AXPress cannot drive
    // this view, so the "auto" strategy must escalate to the flash click.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "canvas" }
    override func accessibilityIdentifier() -> String { "canvas" }
    override func accessibilityActionNames() -> [NSAccessibility.Action] { [] }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill()
        bounds.fill()
        let label = "click me (canvas)"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 14),
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attrs
        )
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var canvasClicks = 0
    var buttonClicks = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 420, height: 260),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = titleString()

        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]

        let canvas = CanvasView(frame: NSRect(x: 40, y: 40, width: 340, height: 120))
        canvas.onClick = { [weak self] in
            guard let self else { return }
            self.canvasClicks += 1
            self.window.title = self.titleString()
        }
        content.addSubview(canvas)

        let button = NSButton(frame: NSRect(x: 140, y: 180, width: 140, height: 32))
        button.title = "Normal Button"
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(buttonPressed)
        content.addSubview(button)

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        window.center()
        self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func buttonPressed() {
        buttonClicks += 1
        window.title = titleString()
    }

    func titleString() -> String {
        "FlashClickTestApp — canvas:\(canvasClicks) button:\(buttonClicks)"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
