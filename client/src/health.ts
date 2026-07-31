import {
  isClientWaitTimeout,
  isOperationTimeout,
  isTransportFailure,
  JsonRpcError,
} from "./errors.js";

export type FailureKind = "transport" | "operation_timeout" | "operation";

export interface HealthSnapshot {
  /** False only after `failureThreshold` consecutive transport failures. */
  healthy: boolean;
  /** Transport failures since the last proof that the daemon is reachable. */
  consecutiveTransportFailures: number;
  transportFailures: number;
  operationTimeouts: number;
  operationErrors: number;
  successes: number;
  lastFailureKind: FailureKind | null;
}

/**
 * Tracks whether the *daemon connection* is healthy, deliberately separating
 * that from whether individual operations succeed.
 *
 * Only transport failures — a dead socket, a daemon that will not start — count
 * against health. A script that blows its deadline, an element that is not
 * found, a menu item that is disabled: those are answers, not outages, and they
 * must never accumulate into "the server is down". This mirrors what MCP hosts
 * do with tool results versus protocol errors, and is why repeated
 * `run_applescript` timeouts leave `connect_app` working.
 */
export class ServerHealth {
  private readonly failureThreshold: number;
  private consecutiveTransportFailures = 0;
  private transportFailures = 0;
  private operationTimeouts = 0;
  private operationErrors = 0;
  private successes = 0;
  private lastFailureKind: FailureKind | null = null;

  constructor(options?: { failureThreshold?: number }) {
    this.failureThreshold = options?.failureThreshold ?? 3;
  }

  /** A completed call: the daemon is reachable. */
  recordSuccess(): void {
    this.successes += 1;
    this.consecutiveTransportFailures = 0;
  }

  /** Classify a failed call and update health accordingly. */
  recordFailure(err: unknown): FailureKind {
    if (isTransportFailure(err)) {
      this.transportFailures += 1;
      this.consecutiveTransportFailures += 1;
      this.lastFailureKind = "transport";
      return "transport";
    }

    if (isOperationTimeout(err)) {
      this.operationTimeouts += 1;
      this.lastFailureKind = "operation_timeout";
      // A daemon-reported timeout arrived over the socket, so the transport is
      // provably alive. A client-side deadline proves nothing either way, so it
      // leaves the transport counter untouched rather than clearing it.
      if (!isClientWaitTimeout(err)) this.consecutiveTransportFailures = 0;
      return "operation_timeout";
    }

    this.operationErrors += 1;
    this.lastFailureKind = "operation";
    if (err instanceof JsonRpcError) this.consecutiveTransportFailures = 0;
    return "operation";
  }

  get healthy(): boolean {
    return this.consecutiveTransportFailures < this.failureThreshold;
  }

  get snapshot(): HealthSnapshot {
    return {
      healthy: this.healthy,
      consecutiveTransportFailures: this.consecutiveTransportFailures,
      transportFailures: this.transportFailures,
      operationTimeouts: this.operationTimeouts,
      operationErrors: this.operationErrors,
      successes: this.successes,
      lastFailureKind: this.lastFailureKind,
    };
  }
}
