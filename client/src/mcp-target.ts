import type { QueryStep } from "./types.js";

export type ElementTarget =
  | { query: QueryStep[]; handleId?: never }
  | { handleId: string; query?: never };

/** Validate the MCP convention shared by element tools: exactly one target. */
export function resolveElementTarget(
  query?: QueryStep[],
  handleId?: string
): ElementTarget {
  const hasQuery = Array.isArray(query) && query.length > 0;
  const hasHandle = typeof handleId === "string" && handleId.length > 0;

  if (hasQuery === hasHandle) {
    throw new Error('Provide exactly one of "query" or "handleId"');
  }

  return hasHandle ? { handleId } : { query: query! };
}
