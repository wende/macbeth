import type { MacbethClient } from "./client.js";

export type PinHandleResult = Awaited<ReturnType<MacbethClient["pinHandle"]>>;

export interface PinHandleDeps {
  pinHandle: (ids: string | string[]) => Promise<PinHandleResult>;
}

export interface PinHandleToolParams {
  handleId?: string;
  handleIds?: string[];
}

interface ToolResult {
  // The MCP SDK's tool-result type is open-ended; the index signature keeps this
  // assignable to it without importing the SDK here.
  [key: string]: unknown;
  content: Array<{ type: "text"; text: string }>;
  isError?: boolean;
}

const fail = (text: string): ToolResult => ({
  content: [{ type: "text", text }],
  isError: true,
});

/** MCP surface for `pin_handle`. Split out of `mcp.ts` so the argument guards and the
 *  bulk result rendering are testable without standing up an MCP server. */
export async function runPinHandleTool(
  deps: PinHandleDeps,
  { handleId, handleIds }: PinHandleToolParams,
): Promise<ToolResult> {
  // `!handleIds` does not catch `[]` — an empty array is truthy in JS, and the daemon
  // would quietly re-route it to the singular path and reject it with a confusing message.
  if (!handleId && (!handleIds || handleIds.length === 0)) {
    return fail("Provide either handleId or a non-empty handleIds.");
  }
  if (handleId && handleIds) {
    return fail("Provide either handleId or handleIds, not both.");
  }

  const result = await deps.pinHandle(handleIds ?? handleId!);
  if (!("results" in result)) {
    return { content: [{ type: "text", text: `Pinned handle: ${result.handleId}` }] };
  }

  const entries = Object.entries(result.results);
  const lines = entries.map(([id, v]) =>
    v === true ? `${id}: pinned` : `${id}: ${(v as { error: string }).error}`,
  );
  // A batch where nothing pinned is a failure, not a report — without isError an agent
  // reads a list of error strings as a successful tool call.
  const nonePinned = entries.every(([, v]) => v !== true);
  return { content: [{ type: "text", text: lines.join("\n") }], isError: nonePinned };
}
