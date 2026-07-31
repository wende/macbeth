/**
 * Error types shared by the RPC layer, the health tracker and the MCP layer.
 *
 * The distinction this module encodes is the one that matters for MCP hosts:
 * an *operation* failure (including a timeout) is the result of one call and
 * says nothing about the server, while a *transport* failure means the daemon
 * connection itself is broken. Hosts open their circuit breaker on the latter,
 * so operation timeouts must never be reported in a way that looks like it.
 */

/** JSON-RPC error codes used by the daemon (see `RPCError` in the Swift sources). */
export const RPC_ERROR_CODES = {
  elementNotFound: -32000,
  timeout: -32001,
  permissionDenied: -32002,
  appNotFound: -32003,
  actionFailed: -32004,
  menuItemNotFound: -32005,
  menuItemDisabled: -32006,
  appBusy: -32007,
  scriptFailed: -32008,
  axLookupFailed: -32009,
} as const;

/** Agent-readable names for the codes above, used when formatting MCP errors. */
export const RPC_ERROR_NAMES: Record<number, string> = {
  [RPC_ERROR_CODES.elementNotFound]: "element_not_found",
  [RPC_ERROR_CODES.timeout]: "timeout",
  [RPC_ERROR_CODES.permissionDenied]: "permission_denied",
  [RPC_ERROR_CODES.appNotFound]: "app_not_found",
  [RPC_ERROR_CODES.actionFailed]: "action_failed",
  [RPC_ERROR_CODES.menuItemNotFound]: "menu_item_not_found",
  [RPC_ERROR_CODES.menuItemDisabled]: "menu_item_disabled",
  [RPC_ERROR_CODES.appBusy]: "app_busy",
  [RPC_ERROR_CODES.scriptFailed]: "script_failed",
  [RPC_ERROR_CODES.axLookupFailed]: "ax_lookup_failed",
};

export class JsonRpcError extends Error {
  code: number;
  data?: unknown;

  constructor(code: number, message: string, data?: unknown) {
    super(message);
    this.name = "JsonRpcError";
    this.code = code;
    this.data = data;
  }
}

/**
 * Build the typed timeout raised when a call outlives its client-side deadline
 * without any daemon response. `phase: "client_wait"` marks it as a local
 * deadline rather than one the daemon reported.
 */
export function operationTimeoutError(
  method: string,
  timeoutMs: number
): JsonRpcError {
  return new JsonRpcError(
    RPC_ERROR_CODES.timeout,
    `Operation timed out: ${method} did not respond within ${timeoutMs}ms. `
    + "Only this call failed; the daemon connection is still usable.",
    { phase: "client_wait", method, timeoutMs }
  );
}

/** True for any typed timeout — daemon-enforced or client-side. */
export function isOperationTimeout(err: unknown): boolean {
  return err instanceof JsonRpcError && err.code === RPC_ERROR_CODES.timeout;
}

/** True only for a timeout the client raised because no response ever arrived. */
export function isClientWaitTimeout(err: unknown): boolean {
  if (!isOperationTimeout(err)) return false;
  const data = (err as JsonRpcError).data;
  return typeof data === "object"
    && data !== null
    && (data as { phase?: unknown }).phase === "client_wait";
}

const CONNECTION_ERROR_CODES = ["ECONNREFUSED", "ENOENT", "EPIPE", "ECONNRESET"];

/**
 * True when the socket to the daemon is unusable and a reconnect is worth
 * attempting. A `JsonRpcError` is never a connection error: receiving one
 * proves the daemon answered.
 */
export function isConnectionError(err: unknown): boolean {
  if (err instanceof JsonRpcError) return false;
  if (!(err instanceof Error)) return false;
  const msg = err.message;
  return msg === "Not connected"
    || msg === "Connection closed"
    || CONNECTION_ERROR_CODES.some((code) => msg.includes(code));
}

/**
 * True when a failure is evidence that the daemon/transport is unhealthy,
 * as opposed to a call that legitimately failed or ran out of time.
 */
export function isTransportFailure(err: unknown): boolean {
  if (err instanceof JsonRpcError) return false;
  if (isConnectionError(err)) return true;
  return err instanceof Error && err.message.startsWith("Daemon failed to start");
}
