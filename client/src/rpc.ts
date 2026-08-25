import * as net from "node:net";
import { isConnectionError, JsonRpcError, operationTimeoutError } from "./errors.js";
import { ServerHealth, type HealthSnapshot } from "./health.js";

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

interface JsonRpcResponse {
  jsonrpc: string;
  id: number | string | null;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

export { JsonRpcError } from "./errors.js";

// Only methods whose repeated execution is read-only or idempotent may be
// replayed after a broken connection. For every other method, the daemon may
// have completed the side effect before the reply was lost, so the outcome is
// unknown and retrying would risk performing it twice.
//
// `wait_for` is in the set for exists / value_equals / enabled (and the default
// exists path). `value_changes` is not idempotent: a retry samples a new
// baseline, so a successful wait whose reply was dropped becomes a timeout.
const RECONNECT_RETRYABLE_METHODS = new Set([
  "connect_app",
  "dump_attributes",
  "extract_text",
  "get_element",
  "list_apps",
  "list_menu_bar",
  "list_methods",
  "list_windows",
  "pin_handle",
  "query_tree",
  "read_form",
  "screenshot",
  "wait_for",
]);

function isReconnectRetryable(
  method: string,
  params?: Record<string, unknown>,
): boolean {
  if (!RECONNECT_RETRYABLE_METHODS.has(method)) return false;
  if (method !== "wait_for") return true;
  const condition = params?.condition;
  if (typeof condition !== "object" || condition === null) return true;
  return (condition as { kind?: unknown }).kind !== "value_changes";
}

export class JsonRpcClient {
  private socket: net.Socket | null = null;
  private pending = new Map<number, PendingRequest>();
  private nextId = 1;
  private buffer = "";
  private requestTimeout: number;
  private socketPath: string | null = null;
  private onReconnect?: () => Promise<void>;
  private serverHealth: ServerHealth;

  constructor(options?: { timeout?: number; onReconnect?: () => Promise<void> }) {
    this.requestTimeout = options?.timeout ?? 60_000;
    this.onReconnect = options?.onReconnect;
    this.serverHealth = new ServerHealth();
  }

  /** Daemon-connection health. Operation failures, timeouts included, never
   *  make this unhealthy — see {@link ServerHealth}. */
  get health(): HealthSnapshot {
    return this.serverHealth.snapshot;
  }

  async connect(socketPath: string): Promise<void> {
    this.socketPath = socketPath;
    return new Promise((resolve, reject) => {
      const socket = net.createConnection({ path: socketPath }, () => {
        this.socket = socket;
        // Don't keep the process alive just because the socket is open.
        // The event loop stays alive while awaited promises are pending.
        socket.unref();
        resolve();
      });

      socket.on("error", (err) => {
        if (!this.socket) {
          reject(err);
        }
      });

      socket.on("data", (data) => {
        this.buffer += data.toString();
        this.processBuffer();
      });

      socket.on("close", () => {
        for (const [, pending] of this.pending) {
          clearTimeout(pending.timer);
          pending.reject(new Error("Connection closed"));
        }
        this.pending.clear();
        this.socket = null;
      });
    });
  }

  async call<T = unknown>(
    method: string,
    params?: Record<string, unknown>,
    options?: { timeoutMs?: number },
  ): Promise<T> {
    try {
      const result = await this.callOnce<T>(method, params, options?.timeoutMs);
      this.serverHealth.recordSuccess();
      return result;
    } catch (err: unknown) {
      if (
        this.onReconnect
        && isReconnectRetryable(method, params)
        && isConnectionError(err)
      ) {
        this.serverHealth.recordFailure(err);
        await this.onReconnect();
        try {
          const result = await this.callOnce<T>(method, params, options?.timeoutMs);
          this.serverHealth.recordSuccess();
          return result;
        } catch (retryErr: unknown) {
          this.serverHealth.recordFailure(retryErr);
          throw retryErr;
        }
      }
      this.serverHealth.recordFailure(err);
      throw err;
    }
  }

  private async callOnce<T = unknown>(
    method: string,
    params?: Record<string, unknown>,
    timeoutMs?: number,
  ): Promise<T> {
    if (!this.socket) {
      throw new Error("Not connected");
    }

    const id = this.nextId++;
    const request = {
      jsonrpc: "2.0",
      method,
      params: params ?? {},
      id,
    };

    return new Promise<T>((resolve, reject) => {
      const effectiveTimeout = timeoutMs ?? this.requestTimeout;
      const timer = setTimeout(() => {
        // Drop only this request. The socket stays open and later requests keep
        // working, so an operation that runs long is never a transport failure.
        // A late reply for `id` is ignored by processBuffer().
        this.pending.delete(id);
        reject(operationTimeoutError(method, effectiveTimeout));
      }, effectiveTimeout);

      this.pending.set(id, {
        resolve: resolve as (value: unknown) => void,
        reject,
        timer,
      });

      this.socket!.write(JSON.stringify(request) + "\n");
    });
  }

  close(): void {
    if (this.socket) {
      this.socket.destroy();
      this.socket = null;
    }
  }

  get connected(): boolean {
    return this.socket !== null && !this.socket.destroyed;
  }

  get path(): string | null {
    return this.socketPath;
  }

  private processBuffer(): void {
    const lines = this.buffer.split("\n");
    this.buffer = lines.pop() ?? "";

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;

      try {
        const response: JsonRpcResponse = JSON.parse(trimmed);
        if (response.id == null) continue;

        const id =
          typeof response.id === "string"
            ? parseInt(response.id, 10)
            : response.id;
        const pending = this.pending.get(id);
        if (!pending) continue;

        clearTimeout(pending.timer);
        this.pending.delete(id);

        if (response.error) {
          pending.reject(
            new JsonRpcError(
              response.error.code,
              response.error.message,
              response.error.data
            )
          );
        } else {
          pending.resolve(response.result);
        }
      } catch {
        // Skip malformed lines
      }
    }
  }
}
