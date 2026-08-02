import { describe, it, expect } from "vitest";
import {
  isRecoverableHandleError,
  isTransportFailure,
  staleHandleReason,
  JsonRpcError,
  RPC_ERROR_CODES,
  RPC_ERROR_NAMES,
} from "../errors.js";

const stale = (reason: string) =>
  new JsonRpcError(
    RPC_ERROR_CODES.staleHandle,
    `Handle h_7 is no longer usable (stale-element, reason: ${reason}).`,
    { reason, handleId: "h_7" }
  );

describe("handle lifecycle errors", () => {
  it("names the handle error codes for agents", () => {
    expect(RPC_ERROR_NAMES[RPC_ERROR_CODES.staleHandle]).toBe("stale_handle");
    expect(RPC_ERROR_NAMES[RPC_ERROR_CODES.unknownHandle]).toBe("unknown_handle");
  });

  it("treats every stale reason as recoverable", () => {
    for (const reason of ["expired", "destroyed", "recycled", "app_terminated"]) {
      expect(isRecoverableHandleError(stale(reason))).toBe(true);
      expect(staleHandleReason(stale(reason))).toBe(reason);
    }
  });

  it("treats an unknown handle as recoverable for callers holding a query path", () => {
    const err = new JsonRpcError(
      RPC_ERROR_CODES.unknownHandle,
      "Unknown handle h_7: this daemon never issued it.",
      { reason: "never_issued" }
    );
    expect(isRecoverableHandleError(err)).toBe(true);
  });

  it("still recognises the pre-typed-code daemon errors", () => {
    // An updated client talking to an older daemon binary: both cases arrived as
    // element_not_found with a marker in the message.
    expect(isRecoverableHandleError(
      new JsonRpcError(RPC_ERROR_CODES.elementNotFound, "Handle expired: h_7")
    )).toBe(true);
    expect(isRecoverableHandleError(
      new JsonRpcError(
        RPC_ERROR_CODES.elementNotFound,
        "Element reference is no longer valid (stale-element; the app likely re-rendered)."
      )
    )).toBe(true);
  });

  it("does not treat unrelated failures as recoverable handle errors", () => {
    expect(isRecoverableHandleError(
      new JsonRpcError(RPC_ERROR_CODES.elementNotFound, "No element matching {role=button}")
    )).toBe(false);
    expect(isRecoverableHandleError(
      new JsonRpcError(RPC_ERROR_CODES.actionFailed, "AXPress unsupported")
    )).toBe(false);
    expect(isRecoverableHandleError(new Error("Connection closed"))).toBe(false);
    expect(staleHandleReason(new Error("boom"))).toBeUndefined();
  });

  it("keeps handle errors out of the server-health signal", () => {
    // A retired handle is a result, not a broken daemon: counting it as a transport
    // failure would trip an MCP host's circuit breaker over an ordinary re-render.
    expect(isTransportFailure(stale("destroyed"))).toBe(false);
    expect(isTransportFailure(
      new JsonRpcError(RPC_ERROR_CODES.unknownHandle, "Unknown handle h_7")
    )).toBe(false);
  });
});
