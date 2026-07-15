import Foundation

/// Pure, timer-free state machine for the glow's debounce behavior.
///
/// The helper "pokes" this tracker on every `activate` message. The glow is
/// considered visible from the first poke until `debounce` has elapsed with no
/// further poke. Rapid bursts of pokes therefore produce one continuous active
/// window (no flicker), and the glow lingers for `debounce` after the last
/// action before fading out.
///
/// Keeping this logic separate from AppKit makes it directly unit-testable.
public struct GlowActivityTracker: Sendable {
    /// Debounce window in seconds.
    public var debounce: TimeInterval

    /// Timestamp of the most recent poke, or nil if idle.
    public private(set) var lastPoke: Date?

    public init(debounceMs: Int = glowDefaultDebounceMs) {
        self.debounce = TimeInterval(max(0, debounceMs)) / 1000.0
        self.lastPoke = nil
    }

    /// Register an interaction. Returns true if this poke transitioned the
    /// tracker from idle → active (i.e. the glow should fade in now).
    @discardableResult
    public mutating func poke(at now: Date = Date()) -> Bool {
        let wasActive = isActive(at: now)
        lastPoke = now
        return !wasActive
    }

    /// Request an immediate fade-out (the daemon explicitly reported idle).
    public mutating func reset() {
        lastPoke = nil
    }

    /// Whether the glow should currently be visible.
    public func isActive(at now: Date = Date()) -> Bool {
        guard let last = lastPoke else { return false }
        return now.timeIntervalSince(last) < debounce
    }

    /// The moment the glow should fade out if no further poke arrives, or nil
    /// when idle. The helper schedules a one-shot timer for this instant; there
    /// are no repeating timers while idle, so CPU use drops to ~0.
    public func fadeOutDeadline() -> Date? {
        lastPoke?.addingTimeInterval(debounce)
    }
}
