import Foundation

/// Macbeth brand burgundy (#8B3342) — the accent used for all glow effects.
public let MACBETH_BURGUNDY = "#8B3342"

/// Default accent color for the glow.
public let glowDefaultColor = MACBETH_BURGUNDY

/// Default fully-visible hold after the final activity ends. The controlled
/// window then fades over `glowWindowFadeDuration`; a new activity cancels
/// either phase and refreshes the lifecycle.
public let glowDefaultDebounceMs = 400

/// Duration of the controlled-window highlight's fade-out.
public let glowWindowFadeDuration: TimeInterval = 0.1

/// Duration of one complete top-to-bottom screenshot scan.
public let glowCaptureScanDuration: TimeInterval = 0.9

/// Minimum time the capture overlay remains in its scanning phase. This is a
/// little longer than one scan so the bottom edge is visibly crossed before
/// the completion snap interrupts the animation.
public let glowCapturePresentationDuration: TimeInterval = 0.95

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
/// {"type":"activate","color":"#8B3342","debounceMs":400}
/// {"type":"deactivate"}
/// {"type":"focusWindow","windowId":"123:456","rect":{"x":0,"y":0,"width":800,"height":600}}
/// {"type":"pointerMove","point":{"x":120,"y":240},"action":"click"}
/// {"type":"captureStart","captureId":"...","rect":{"x":0,"y":0,"width":800,"height":600}}
/// {"type":"captureFinish","captureId":"...","success":true}
/// {"type":"shutdown"}
/// ```
public struct GlowMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Interaction started (or is ongoing) — keep the highlight and cancel any
        /// pending fade. Optional `color`/`debounceMs` update configuration.
        case activate
        /// The daemon reports idle — hold, then schedule the highlight fade-out.
        case deactivate
        /// Create or refresh the subtle outline for one addressed window.
        case focusWindow
        /// Move the synthetic presentation pointer to an interaction target.
        case pointerMove
        /// Focus and scan the target window while ScreenCaptureKit captures it.
        case captureStart
        /// Play the success/failure snap and dissolve the capture overlay.
        case captureFinish
        /// Tear down overlays and exit the helper process.
        case shutdown
    }

    public var type: Kind
    /// Optional hex color (e.g. "#8B3342"). Only meaningful on `.activate`.
    public var color: String?
    /// Optional debounce window in milliseconds. Only meaningful on `.activate`.
    public var debounceMs: Int?
    /// Correlates capture start/finish messages when screenshots overlap.
    public var captureId: String?
    /// Stable process-local identity of the controlled window. This lets the
    /// helper retain independent outlines when several windows are in use.
    public var windowId: String?
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
        windowId: String? = nil,
        rect: GlowCaptureRect? = nil,
        point: GlowPointerPoint? = nil,
        action: GlowPointerAction? = nil,
        success: Bool? = nil
    ) {
        self.type = type
        self.color = color
        self.debounceMs = debounceMs
        self.captureId = captureId
        self.windowId = windowId
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

    public static func windowFocused(id: String, rect: GlowCaptureRect) -> GlowMessage {
        GlowMessage(type: .focusWindow, windowId: id, rect: rect)
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
