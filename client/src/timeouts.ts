/**
 * Bounds for caller-configurable script execution deadlines.
 *
 * These mirror `ScriptTimeout` in
 * `daemon/Sources/macbethd/Methods/ScriptExecution.swift` — the daemon clamps
 * independently, so a hand-written RPC call cannot ask for an unbounded run.
 */
export const SCRIPT_TIMEOUT = {
  defaultMs: 30_000,
  minMs: 100,
  maxMs: 300_000,
  /** Extra time the client waits so the daemon can report its own timeout. */
  clientGraceMs: 2_000,
} as const;

/** Clamp a requested script timeout into the supported range. */
export function clampScriptTimeoutMs(requestedMs?: number): number {
  if (requestedMs === undefined || !Number.isFinite(requestedMs)) {
    return SCRIPT_TIMEOUT.defaultMs;
  }
  return Math.min(
    Math.max(Math.round(requestedMs), SCRIPT_TIMEOUT.minMs),
    SCRIPT_TIMEOUT.maxMs
  );
}

/** Convert the MCP tool's seconds-based `timeout` into a clamped millisecond value. */
export function scriptTimeoutFromSeconds(seconds?: number): number {
  if (seconds === undefined || !Number.isFinite(seconds)) {
    return SCRIPT_TIMEOUT.defaultMs;
  }
  return clampScriptTimeoutMs(seconds * 1_000);
}

/**
 * How long the client waits for the daemon's reply. Always longer than the
 * daemon's own deadline so a script that overruns is reported as the daemon's
 * typed timeout rather than as a silent client-side one.
 */
export function scriptRequestTimeoutMs(timeoutMs: number): number {
  return timeoutMs + SCRIPT_TIMEOUT.clientGraceMs;
}
