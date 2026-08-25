import { isOperationTimeout, JsonRpcError, RPC_ERROR_NAMES } from "./errors.js";
import { SCRIPT_TIMEOUT } from "./timeouts.js";

export interface ToolContent {
  type: "text";
  text: string;
}

export interface ToolResult {
  content: ToolContent[];
  isError?: boolean;
  [key: string]: unknown;
}

export function formatError(prefix: string, err: unknown): string {
  if (err instanceof JsonRpcError) {
    const kind = RPC_ERROR_NAMES[err.code] ?? `error_${err.code}`;
    let msg = `${prefix} [${kind}]: ${err.message}`;
    if (err.data && typeof err.data === "object") {
      const d = err.data as Record<string, unknown>;
      if (d.osaErrorNumber != null) msg += ` (OSA error ${d.osaErrorNumber})`;
      if (d.phase != null) msg += ` (phase: ${d.phase})`;
      if (d.durationMs != null) msg += ` (duration: ${d.durationMs}ms)`;
    }
    return msg;
  }
  return `${prefix}: ${err instanceof Error ? err.message : String(err)}`;
}

/**
 * Format a script failure. A timeout is scoped to the call that hit it: say so
 * explicitly and point at the knob, so the caller raises `timeout` instead of
 * treating the whole server as broken and retrying blindly.
 */
export function formatScriptError(err: unknown, timeoutSeconds: number): string {
  const base = formatError("Script failed", err);
  if (!isOperationTimeout(err)) return base;
  return `${base}\nThe script exceeded its ${timeoutSeconds}s budget and was stopped. `
    + "Only this call failed — the Macbeth server and every other tool are unaffected. "
    + `Re-run with a larger 'timeout' (up to ${SCRIPT_TIMEOUT.maxMs / 1_000}s) if the work `
    + "legitimately takes longer.";
}

export function fail(text: string): ToolResult {
  return { content: [{ type: "text", text }], isError: true };
}

export function ok(text: string): ToolResult {
  return { content: [{ type: "text", text }] };
}
