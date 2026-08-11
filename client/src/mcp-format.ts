import { stringify } from "yaml";

/**
 * Format a structured value as the model-facing payload for an MCP tool result.
 *
 * YAML trims roughly 30–45% off pretty-printed JSON of the same shape and
 * handles ambiguous scalars (free-text AX values like `Yes`, `null`, `~`,
 * dates, or strings containing `: ` / ` #` / newlines) without changing type.
 * `lineWidth: 0` keeps long values on one line so paths and titles stay
 * copy-pasteable.
 *
 * Wire protocol and request log stay JSON-RPC / NDJSON — only this single
 * point converts payloads that the model will read.
 */
export function toModelPayload(value: unknown): string {
  return stringify(value, { indent: 2, lineWidth: 0 });
}