import { describe, expect, it, vi } from "vitest";
import { runWithActivity } from "../mcp-activity.js";

describe("runWithActivity", () => {
  it("ends the activity after a successful operation", async () => {
    const begin = vi.fn().mockResolvedValue("token-1");
    const end = vi.fn().mockResolvedValue(undefined);
    const operation = vi.fn().mockResolvedValue("done");

    await expect(runWithActivity({ begin, end }, operation)).resolves.toBe("done");
    expect(begin).toHaveBeenCalledOnce();
    expect(operation).toHaveBeenCalledOnce();
    expect(end).toHaveBeenCalledWith("token-1");
  });

  it("ends the activity when the operation fails", async () => {
    const end = vi.fn().mockResolvedValue(undefined);
    const failure = new Error("operation failed");

    await expect(runWithActivity(
      { begin: vi.fn().mockResolvedValue("token-2"), end },
      async () => { throw failure; },
    )).rejects.toBe(failure);
    expect(end).toHaveBeenCalledWith("token-2");
  });

  it("keeps signaling best-effort", async () => {
    const onSignalError = vi.fn();
    const operation = vi.fn().mockResolvedValue("still ran");

    await expect(runWithActivity(
      {
        begin: vi.fn().mockRejectedValue(new Error("no daemon")),
        end: vi.fn(),
      },
      operation,
      onSignalError,
    )).resolves.toBe("still ran");
    expect(operation).toHaveBeenCalledOnce();
    expect(onSignalError).toHaveBeenCalledOnce();
  });
});
