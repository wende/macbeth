import Foundation

/// Default accent color for the glow (a vivid but balanced violet).
public let glowDefaultColor = "#A855F7"

/// Default delay between the final activity ending and the glow beginning to
/// fade. A new activity during this window cancels the pending fade.
public let glowDefaultDebounceMs = 100

/// A window rectangle in CoreGraphics global coordinates (origin at the
/// top-left of the primary display), as reported by ScreenCaptureKit.
public struct GlowCaptureRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A point in CoreGraphics/Accessibility global coordinates (top-left origin).
public struct GlowPointerPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The interaction represented by the synthetic presentation pointer.
public enum GlowPointerAction: String, Codable, Sendable {
    case click
    case fill
    case interact
}

/// The IPC message exchanged between the daemon and the `macbeth-glow` helper.
///
/// The wire format is one JSON object per line (newline-delimited), matching the
/// framing the rest of macbeth already uses on its RPC socket. Only the daemon
/// sends messages; the helper never replies.
///
/// Examples:
/// ```
/// {"type":"activate","color":"#A855F7","debounceMs":100}
/// {"type":"deactivate"}
/// {"type":"focusWindow","rect":{"x":0,"y":0,"width":800,"height":600}}
/// {"type":"pointerMove","point":{"x":120,"y":240},"action":"click"}
/// {"type":"captureStart","captureId":"...","rect":{"x":0,"y":0,"width":800,"height":600}}
/// {"type":"captureFinish","captureId":"...","success":true}
/// {"type":"shutdown"}
/// ```
public struct GlowMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Interaction started (or is ongoing) — show the glow and cancel any
        /// pending fade. Optional `color`/`debounceMs` update configuration.
        case activate
        /// The daemon reports idle — schedule a debounced fade-out.
        case deactivate
        /// Keep a subtle outline around the most recently addressed window.
        case focusWindow
        /// Move the recording-only synthetic pointer to an interaction target.
        case pointerMove
        /// Focus and scan the target window while ScreenCaptureKit captures it.
        case captureStart
        /// Play the success/failure snap and dissolve the capture overlay.
        case captureFinish
        /// Tear down overlays and exit the helper process.
        case shutdown
    }

    public var type: Kind
    /// Optional hex color (e.g. "#A855F7"). Only meaningful on `.activate`.
    public var color: String?
    /// Optional debounce window in milliseconds. Only meaningful on `.activate`.
    public var debounceMs: Int?
    /// Correlates capture start/finish messages when screenshots overlap.
    public var captureId: String?
    /// Target window bounds. Only meaningful on `.captureStart`.
    public var rect: GlowCaptureRect?
    /// Interaction target. Only meaningful on `.pointerMove`.
    public var point: GlowPointerPoint?
    /// Pointer affordance shown on arrival. Only meaningful on `.pointerMove`.
    public var action: GlowPointerAction?
    /// Capture result. Only meaningful on `.captureFinish`.
    public var success: Bool?

    public init(
        type: Kind,
        color: String? = nil,
        debounceMs: Int? = nil,
        captureId: String? = nil,
        rect: GlowCaptureRect? = nil,
        point: GlowPointerPoint? = nil,
        action: GlowPointerAction? = nil,
        success: Bool? = nil
    ) {
        self.type = type
        self.color = color
        self.debounceMs = debounceMs
        self.captureId = captureId
        self.rect = rect
        self.point = point
        self.action = action
        self.success = success
    }

    public static let deactivate = GlowMessage(type: .deactivate)
    public static let shutdown = GlowMessage(type: .shutdown)

    public static func activate(color: String? = nil, debounceMs: Int? = nil) -> GlowMessage {
        GlowMessage(type: .activate, color: color, debounceMs: debounceMs)
    }

    public static func captureStarted(id: String, rect: GlowCaptureRect) -> GlowMessage {
        GlowMessage(type: .captureStart, captureId: id, rect: rect)
    }

    public static func captureFinished(id: String, success: Bool) -> GlowMessage {
        GlowMessage(type: .captureFinish, captureId: id, success: success)
    }

    public static func windowFocused(rect: GlowCaptureRect) -> GlowMessage {
        GlowMessage(type: .focusWindow, rect: rect)
    }

    public static func pointerMoved(
        to point: GlowPointerPoint,
        action: GlowPointerAction
    ) -> GlowMessage {
        GlowMessage(type: .pointerMove, point: point, action: action)
    }

    // MARK: - Wire encoding

    /// Encode to a single newline-terminated line ready to write to the pipe.
    ///
    /// `JSONEncoder` is not `Sendable`, so under Swift 6 strict concurrency it
    /// can't be shared via a `static let`; instantiate it locally instead. The
    /// object is lightweight and these calls are infrequent.
    public func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A) // '\n'
        return data
    }

    /// Decode a single line (with or without a trailing newline).
    public static func decode(line: Data) throws -> GlowMessage {
        try JSONDecoder().decode(GlowMessage.self, from: line)
    }
}
