import { describe, expect, it } from "vitest";

import {
  isClientWaitTimeout,
  isConnectionError,
  isOperationTimeout,
  isTransportFailure,
  JsonRpcError,
  operationTimeoutError,
  RPC_ERROR_CODES,
} from "../errors.js";
import { ServerHealth } from "../health.js";
import {
  ACTION_TIMEOUT,
  actionRequestTimeoutMs,
  actionTimeoutFromSeconds,
  clampActionTimeoutMs,
  clampScriptTimeoutMs,
  scriptRequestTimeoutMs,
  scriptTimeoutFromSeconds,
  SCRIPT_TIMEOUT,
} from "../timeouts.js";

describe("UI action timeout bounds", () => {
  it("clamps action budgets and converts seconds", () => {
    expect(clampActionTimeoutMs()).toBe(ACTION_TIMEOUT.defaultMs);
    expect(clampActionTimeoutMs(-1)).toBe(ACTION_TIMEOUT.minMs);
    expect(clampActionTimeoutMs(Number.POSITIVE_INFINITY)).toBe(ACTION_TIMEOUT.defaultMs);
    expect(actionTimeoutFromSeconds(120)).toBe(120_000);
    expect(actionTimeoutFromSeconds(10_000)).toBe(ACTION_TIMEOUT.maxMs);
  });

  it("keeps the transport alive beyond the daemon action budget", () => {
    expect(actionRequestTimeoutMs(120_000)).toBe(
      120_000 + ACTION_TIMEOUT.clientGraceMs
    );
  });
});

describe("script timeout bounds", () => {
  it("defaults to 30s when no timeout is requested", () => {
    expect(clampScriptTimeoutMs()).toBe(SCRIPT_TIMEOUT.defaultMs);
    expect(clampScriptTimeoutMs(Number.NaN)).toBe(SCRIPT_TIMEOUT.defaultMs);
    expect(scriptTimeoutFromSeconds()).toBe(SCRIPT_TIMEOUT.defaultMs);
  });

  it("clamps requests into the supported range", () => {
    expect(clampScriptTimeoutMs(0)).toBe(SCRIPT_TIMEOUT.minMs);
    expect(clampScriptTimeoutMs(-1_000)).toBe(SCRIPT_TIMEOUT.minMs);
    expect(clampScriptTimeoutMs(10 * SCRIPT_TIMEOUT.maxMs)).toBe(SCRIPT_TIMEOUT.maxMs);
    expect(scriptTimeoutFromSeconds(10_000)).toBe(SCRIPT_TIMEOUT.maxMs);
  });

  it("honours budgets well past the 30s default", () => {
    expect(clampScriptTimeoutMs(45_000)).toBe(45_000);
    expect(scriptTimeoutFromSeconds(120)).toBe(120_000);
    expect(scriptTimeoutFromSeconds(300)).toBe(SCRIPT_TIMEOUT.maxMs);
  });

  it("waits longer than the daemon so the daemon reports the timeout", () => {
    expect(scriptRequestTimeoutMs(45_000)).toBeGreaterThan(45_000);
    expect(scriptRequestTimeoutMs(45_000)).toBe(45_000 + SCRIPT_TIMEOUT.clientGraceMs);
  });
});

describe("failure classification", () => {
  it("treats a client-side deadline as a typed operation timeout", () => {
    const err = operationTimeoutError("run_applescript", 32_000);
    expect(err).toBeInstanceOf(JsonRpcError);
    expect(err.code).toBe(RPC_ERROR_CODES.timeout);
    expect(isOperationTimeout(err)).toBe(true);
    expect(isClientWaitTimeout(err)).toBe(true);
    expect(isTransportFailure(err)).toBe(false);
    expect(isConnectionError(err)).toBe(false);
  });

  it("treats a daemon-reported timeout as an operation failure, not a server fault", () => {
    const err = new JsonRpcError(RPC_ERROR_CODES.timeout, "OSA script execution timed out");
    expect(isOperationTimeout(err)).toBe(true);
    expect(isClientWaitTimeout(err)).toBe(false);
    expect(isTransportFailure(err)).toBe(false);
  });

  it("treats broken sockets and dead daemons as transport failures", () => {
    for (const message of [
      "Not connected",
      "Connection closed",
      "connect ECONNREFUSED /tmp/macbeth.sock",
      "write EPIPE",
      "Daemon failed to start: socket not created",
    ]) {
      expect(isTransportFailure(new Error(message))).toBe(true);
    }
  });

  it("does not retry-reconnect on a daemon startup failure", () => {
    // ensureRunning() already reports this; reconnecting would only loop.
    expect(isConnectionError(new Error("Daemon failed to start: boom"))).toBe(false);
  });
});

describe("ServerHealth", () => {
  it("stays healthy through repeated operation timeouts", () => {
    const health = new ServerHealth();

    for (let i = 0; i < 10; i++) {
      expect(health.recordFailure(operationTimeoutError("run_applescript", 30_000)))
        .toBe("operation_timeout");
    }

    expect(health.healthy).toBe(true);
    expect(health.snapshot.consecutiveTransportFailures).toBe(0);
    expect(health.snapshot.operationTimeouts).toBe(10);
    expect(health.snapshot.transportFailures).toBe(0);
  });

  it("stays healthy through ordinary operation errors", () => {
    const health = new ServerHealth();
    const notFound = new JsonRpcError(RPC_ERROR_CODES.elementNotFound, "no such button");

    for (let i = 0; i < 5; i++) expect(health.recordFailure(notFound)).toBe("operation");

    expect(health.healthy).toBe(true);
    expect(health.snapshot.operationErrors).toBe(5);
  });

  it("opens only after consecutive transport failures", () => {
    const health = new ServerHealth({ failureThreshold: 3 });

    health.recordFailure(new Error("Connection closed"));
    health.recordFailure(new Error("connect ECONNREFUSED"));
    expect(health.healthy).toBe(true);

    health.recordFailure(new Error("Not connected"));
    expect(health.healthy).toBe(false);
    expect(health.snapshot.lastFailureKind).toBe("transport");
  });

  it("recovers as soon as a call succeeds again", () => {
    const health = new ServerHealth({ failureThreshold: 2 });
    health.recordFailure(new Error("Connection closed"));
    health.recordFailure(new Error("Connection closed"));
    expect(health.healthy).toBe(false);

    health.recordSuccess();
    expect(health.healthy).toBe(true);
    expect(health.snapshot.consecutiveTransportFailures).toBe(0);
  });

  it("counts a daemon-reported error as proof the transport works", () => {
    const health = new ServerHealth({ failureThreshold: 2 });
    health.recordFailure(new Error("Connection closed"));

    // The daemon answered — the socket is demonstrably alive again.
    health.recordFailure(new JsonRpcError(RPC_ERROR_CODES.timeout, "script timed out"));
    expect(health.snapshot.consecutiveTransportFailures).toBe(0);

    health.recordFailure(new Error("Connection closed"));
    expect(health.healthy).toBe(true);
  });
});
