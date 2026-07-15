import Foundation
import GlowProtocol

/// Best-effort driver for the screen-edge glow indicator.
///
/// The daemon itself has no AppKit run loop (it runs an async socket server on
/// the main thread), so the glow lives in a separate lightweight `macbeth-glow`
/// helper. This actor spawns that helper lazily on the first interaction and
/// reuses it afterwards, feeding it newline-delimited `GlowMessage`s over the
/// helper's stdin pipe.
///
/// Every operation is best-effort: if the helper can't be spawned, crashes, or
/// the pipe breaks, the daemon's own work must proceed unaffected — we only log
/// a warning. Interaction signaling must never block or throw into a handler.
actor GlowIndicator {
    struct Config: Sendable {
        var enabled: Bool
        var color: String
        var debounceMs: Int
        /// Optional explicit path to the helper binary (overrides discovery).
        var helperPath: String?
    }

    private let config: Config
    private let verbose: Bool

    private var process: Process?
    private var stdin: FileHandle?
    /// Set once we've permanently given up (e.g. helper binary not found) so we
    /// don't spam spawn attempts on every single action.
    private var disabled: Bool

    init(config: Config, verbose: Bool) {
        self.config = config
        self.verbose = verbose
        self.disabled = !config.enabled
    }

    // MARK: - Interaction lifecycle hooks

    /// Signal that an interaction is starting (or ongoing). Shows the glow and
    /// re-arms the helper's debounce timer. Safe to call very frequently.
    func activityStarted() {
        guard !disabled else { return }
        ensureRunning()
        send(.activate(color: config.color, debounceMs: config.debounceMs))
    }

    /// Signal that an interaction finished. We send another keep-alive so the
    /// debounce window is anchored to when the action *completed*, guaranteeing
    /// the glow lingers ~debounceMs past the last action. The actual fade-out is
    /// debounced inside the helper.
    func activityEnded() {
        guard !disabled else { return }
        guard process != nil else { return } // never spawn just to end
        send(.activate(color: config.color, debounceMs: config.debounceMs))
    }

    /// Tear down the helper (used on daemon shutdown).
    func shutdown() {
        guard process != nil else { return }
        send(.shutdown)
        // Dropping our references closes the pipe's write end, so the helper also
        // sees EOF and exits even if the shutdown message was missed.
        stdin = nil
        process = nil
    }

    // MARK: - Helper lifecycle

    private func ensureRunning() {
        if let proc = process, proc.isRunning { return }
        // Stale reference (helper died) — drop it and respawn.
        process = nil
        stdin = nil

        guard let path = resolveHelperPath() else {
            warn("glow helper binary not found; disabling indicator for this session")
            disabled = true
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = [
            "--color", config.color,
            "--debounce-ms", String(config.debounceMs),
        ]
        let inPipe = Pipe()
        proc.standardInput = inPipe
        // Let the helper's own stderr flow through for diagnostics.
        proc.standardOutput = FileHandle.nullDevice

        // Reap and reset when the helper exits so the next action respawns it.
        // Only Sendable values (pids, status ints) cross into the actor.
        proc.terminationHandler = { [weak self] finished in
            let pid = finished.processIdentifier
            let status = finished.terminationStatus
            Task { await self?.helperTerminated(pid: pid, status: status) }
        }

        do {
            try proc.run()
        } catch {
            // The binary exists but couldn't launch (permissions, sandboxing,
            // etc.) — unlikely to recover this session. Give up like a missing
            // binary so we don't re-attempt and warn on every interaction.
            warn("failed to spawn glow helper; disabling indicator for this session: \(error.localizedDescription)")
            disabled = true
            return
        }

        process = proc
        stdin = inPipe.fileHandleForWriting
        if verbose { warn("spawned glow helper (pid \(proc.processIdentifier))") }
    }

    private func helperTerminated(pid: Int32, status: Int32) {
        // Only clear if this is still the current process (avoid racing a respawn).
        if process?.processIdentifier == pid {
            process = nil
            stdin = nil
            if verbose {
                warn("glow helper exited (status \(status)); will respawn on next action")
            }
        }
    }

    private func send(_ message: GlowMessage) {
        guard let handle = stdin else { return }
        do {
            let line = try message.encodedLine()
            // SIGPIPE is ignored process-wide, so a dead reader surfaces as a
            // thrown EPIPE here instead of killing the daemon.
            try handle.write(contentsOf: line)
        } catch {
            // Broken pipe / helper gone. Drop the handle; ensureRunning() will
            // respawn on the next interaction. Never propagate to the caller.
            stdin = nil
            process = nil
            if verbose { warn("glow pipe write failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Helper discovery

    private func resolveHelperPath() -> String? {
        var candidates: [String] = []
        if let explicit = config.helperPath { candidates.append(explicit) }

        // Primary: a sibling of the running daemon executable (build-daemon.sh
        // copies both into client/bin, and `swift build` emits both into the
        // same .build/<config> directory).
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let dir = exe.deletingLastPathComponent()
            candidates.append(dir.appendingPathComponent("macbeth-glow").path)
        }
        let argv0 = CommandLine.arguments.first ?? ""
        if !argv0.isEmpty {
            let dir = URL(fileURLWithPath: argv0).resolvingSymlinksInPath().deletingLastPathComponent()
            candidates.append(dir.appendingPathComponent("macbeth-glow").path)
        }

        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func warn(_ message: String) {
        fputs("[macbethd] glow: \(message)\n", stderr)
    }
}
