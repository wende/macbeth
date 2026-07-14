import AppKit
import GlowProtocol

// MARK: - Argument parsing

var colorArg = glowDefaultColor
var debounceMsArg = glowDefaultDebounceMs

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--color":
        if let value = argIterator.next() { colorArg = value }
    case "--debounce-ms":
        if let value = argIterator.next(), let ms = Int(value) { debounceMsArg = ms }
    case "--help", "-h":
        fputs("""
        Usage: macbeth-glow [options]

        Internal helper for macbethd: draws a screen-edge glow while the daemon
        is interacting with the system. Reads newline-delimited JSON commands on
        stdin ({"type":"activate"|"deactivate"|"shutdown"}); exits on EOF.

        Options:
          --color <hex>          Glow color (default: \(glowDefaultColor))
          --debounce-ms <int>    Keep-alive window after last action (default: \(glowDefaultDebounceMs))
          --help, -h             Show this help

        """, stderr)
        exit(0)
    default:
        // Ignore unknown args so future daemon versions stay compatible.
        break
    }
}

let resolvedRGBA = parseGlowColor(colorArg) ?? parseGlowColor(glowDefaultColor)!

/// App delegate: wires stdin input to the overlay controller once the app has
/// finished launching (so windows and the run loop exist).
@MainActor
final class GlowAppDelegate: NSObject, NSApplicationDelegate {
    private let controller: OverlayController
    private var reader: StdinLineReader?

    init(rgba: GlowRGBA, debounceMs: Int) {
        controller = OverlayController(rgba: rgba, debounceMs: debounceMs)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()

        let controller = self.controller
        let reader = StdinLineReader(
            onMessage: { message in
                Task { @MainActor in controller.handle(message) }
            },
            onEOF: {
                Task { @MainActor in NSApp.terminate(nil) }
            }
        )
        reader.start()
        self.reader = reader
    }
}

let app = NSApplication.shared
// .accessory: no Dock icon, no menu bar — a headless helper.
app.setActivationPolicy(.accessory)
let delegate = GlowAppDelegate(rgba: resolvedRGBA, debounceMs: debounceMsArg)
app.delegate = delegate
app.run()
