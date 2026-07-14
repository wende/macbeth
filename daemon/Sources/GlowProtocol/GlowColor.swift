import Foundation

/// RGBA components in the 0...1 range, parsed from a hex string.
public struct GlowRGBA: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Parse a hex color string into RGBA components.
///
/// Accepts `#RGB`, `#RGBA`, `#RRGGBB`, and `#RRGGBBAA` (the leading `#` is
/// optional). Returns nil for malformed input so callers can fall back to a
/// default rather than crashing.
public func parseGlowColor(_ raw: String) -> GlowRGBA? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard !s.isEmpty, s.allSatisfy({ $0.isHexDigit }) else { return nil }

    // Expand shorthand forms (#RGB / #RGBA) to full width.
    if s.count == 3 || s.count == 4 {
        s = s.map { "\($0)\($0)" }.joined()
    }
    guard s.count == 6 || s.count == 8 else { return nil }
    guard let value = UInt64(s, radix: 16) else { return nil }

    let hasAlpha = s.count == 8
    let r, g, b, a: UInt64
    if hasAlpha {
        r = (value >> 24) & 0xFF
        g = (value >> 16) & 0xFF
        b = (value >> 8) & 0xFF
        a = value & 0xFF
    } else {
        r = (value >> 16) & 0xFF
        g = (value >> 8) & 0xFF
        b = value & 0xFF
        a = 0xFF
    }
    return GlowRGBA(
        red: Double(r) / 255.0,
        green: Double(g) / 255.0,
        blue: Double(b) / 255.0,
        alpha: Double(a) / 255.0
    )
}
