import Foundation

/// Default accent color for the glow (a vivid but balanced violet).
public let glowDefaultColor = "#A855F7"

/// Default debounce window: keep the glow alive this many milliseconds after the
/// last interaction so a rapid burst of actions reads as one continuous glow.
public let glowDefaultDebounceMs = 1500

/// The IPC message exchanged between the daemon and the `macbeth-glow` helper.
///
/// The wire format is one JSON object per line (newline-delimited), matching the
/// framing the rest of macbeth already uses on its RPC socket. Only the daemon
/// sends messages; the helper never replies.
///
/// Examples:
/// ```
/// {"type":"activate","color":"#A855F7","debounceMs":1500}
/// {"type":"deactivate"}
/// {"type":"shutdown"}
/// ```
public struct GlowMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Interaction started (or is ongoing) — show the glow and (re)arm the
        /// debounce timer. Optional `color`/`debounceMs` update configuration.
        case activate
        /// The daemon reports idle — begin the (debounced) fade-out.
        case deactivate
        /// Tear down overlays and exit the helper process.
        case shutdown
    }

    public var type: Kind
    /// Optional hex color (e.g. "#A855F7"). Only meaningful on `.activate`.
    public var color: String?
    /// Optional debounce window in milliseconds. Only meaningful on `.activate`.
    public var debounceMs: Int?

    public init(type: Kind, color: String? = nil, debounceMs: Int? = nil) {
        self.type = type
        self.color = color
        self.debounceMs = debounceMs
    }

    public static let deactivate = GlowMessage(type: .deactivate)
    public static let shutdown = GlowMessage(type: .shutdown)

    public static func activate(color: String? = nil, debounceMs: Int? = nil) -> GlowMessage {
        GlowMessage(type: .activate, color: color, debounceMs: debounceMs)
    }

    // MARK: - Wire encoding

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Encode to a single newline-terminated line ready to write to the pipe.
    public func encodedLine() throws -> Data {
        var data = try GlowMessage.encoder.encode(self)
        data.append(0x0A) // '\n'
        return data
    }

    /// Decode a single line (with or without a trailing newline).
    public static func decode(line: Data) throws -> GlowMessage {
        try decoder.decode(GlowMessage.self, from: line)
    }
}
