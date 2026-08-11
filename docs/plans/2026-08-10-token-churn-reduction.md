# Plan: Reduce token churn in macbeth MCP tool outputs

Date: 2026-08-10
Status: plan only — no implementation yet
Context: stats from `~/Library/Caches/macbeth/logs/requests.log` (72 RPCs, 15 methods)
and the smoke-test report at `~/.claude/projects/-Users-wende-projects-macbeth/reports/macbeth-mcp-smoke-test-2026-08-10.md`.

## What the log says is expensive

| Method | Worst observed | Driver |
|---|---|---|
| `screenshot` | 740 KB (one call) | base64 PNG daemon→client (agent sees only a path — OK) |
| `list_windows` global | 61 KB | `includeAllSurfaces` + per-app AX join, no filter |
| `query_tree` | tens of KB | wide trees; `maxDepth` prunes depth, not breadth |
| `extract_text` | KBs per call | `text (conf%, at x,y)` suffix per OCR line |
| `get_element` / `dump_attributes` | pretty-printed JSON | `JSON.stringify(x, null, 2)` indentation waste |

## Scope (user-approved)

1. Regex filters on `list_windows` / `list_menu_bar`
2. Client-side YAML output for structured payloads
3. `query_tree` `maxNodes` cap with truncation marker

Out of scope (deferred): `extract_text` plain-mode params (client-only, can be a
follow-up), generic `maxBytes` budget (protocol change, revisit after 1–3 land).

---

## 1. Regex filters on `list_windows` and `list_menu_bar`

**Precedent:** element locators already take `titlePattern` (`protocol/schema.ts`,
`AX/ElementQuery.swift`). Reuse the name and the semantics.

**Schema** (`protocol/schema.ts`):
- `list_windows` params: add `titlePattern?: string`, matched case-insensitively
  against `title`, `ownerName`, and `bundleId` (one pattern, three fields — a window
  matches if any field matches).
- `list_menu_bar` params: add `titlePattern?: string`, matched against menu item
  titles; non-matching branches are pruned but ancestors of matches are kept (a
  pruned tree that drops "File" because only "File > Export…" matched is useless).

**Daemon:**
- `Methods/ListWindows.swift`: compile one `NSRegularExpression` (or
  `Regex<Substring>` — check Swift 6 availability), filter `WindowDescriptor`s
  before the per-app AX join so filtered-out apps skip the AX round-trip entirely
  (latency win as well as bytes). Invalid pattern → `RPCError.invalidParams` with
  the regex error text.
- `Methods/MenuBar.swift`: `serializeMenuBar` currently emits a flat string. Add a
  filtering pass during serialization: walk items, keep an item if it matches or
  any descendant matches, indent preserved. No schema change to output shape.
- Both: invalid regex must not crash the call — return -32602 with a clear message.

**Client:** pass params through `client.ts` + `mcp.ts` schemas; update tool
descriptions to advertise the filter ("pass `app` AND `titlePattern` to keep the
result small").

**Tests:**
- Daemon: `ListWindows` filter unit tests where possible (descriptor filtering is
  on `WindowDescriptor`, which exists precisely to be testable — see CLAUDE.md
  "Window listing"); regex edge cases (invalid pattern, empty match, unicode).
- Client: vitest for param plumbing and schema validation.

## 2. Client-side YAML output

**Boundary (hard):** wire protocol stays JSON-RPC 2.0 newline-delimited JSON;
request log stays NDJSON. Only the *model-facing payload strings* in MCP tool
results change.

**Where:** `client/src/mcp.ts` response formatting, using the `yaml` npm package
(client already has deps; daemon stays zero-dependency — no hand-rolled Swift YAML
emitter, which is the correctness minefield: free-text AX values like `Yes`,
`null`, `~`, `2026-08-10`, embedded `: ` / ` #` / newlines silently change type if
quoting is off. `yaml` handles this correctly).

**New module:** `client/src/mcp-format.ts` —
```ts
export function toModelPayload(value: unknown): string
```
- `yaml.stringify(value, { indent: 2, lineWidth: 0 })` (`lineWidth: 0` = never
  hard-wrap long strings — wrapping breaks copy/paste of paths and titles).
- Single place to flip format later; unit-test against hostile fixtures (strings
  that look like YAML scalars, emoji, newlines, very long values).

**Converted tools** (payloads currently `JSON.stringify(x, null, 2)` or structured):
`get_element`, `dump_attributes`, `screenshot` result (mcp-screenshot.ts),
`list_windows` (when it returns structured rows — keep the compact text lines for
the simple per-app path if they're already tighter), `list_apps`, `press_key`/
`press_keys` results, `wait_for` failure lists.

**Left as-is:** `query_tree` text format (already denser than YAML), menu-bar text,
`extract_text` line format (addressed by its own follow-up), `run_applescript`
stdout passthrough.

**Doc note:** agents read YAML but still write JSON params (MCP input schemas are
JSON Schema). Add one line to the core skill (`skills/macbeth/SKILL.md`) saying
outputs are YAML — this heads off models occasionally pasting YAML back as params.

**Tests:** `client/src/__tests__/mcp-format.test.ts` — round-trip hostile strings,
assert no `JSON.stringify(..., null, 2)` remains in mcp result paths (grep-style
test or refactor makes it structurally impossible).

## 3. `query_tree` `maxNodes` cap

**Schema:** `queryTree` params add `maxNodes?: number` (default: unlimited to
preserve behavior; MCP tool description recommends e.g. 500 for orientation).

**Daemon** (`AX/TreeWalker.swift`):
- The walk is recursive with a pass-through for skipped elements; thread a mutable
  budget through it. Cleanest with an actor or a `final class NodeBudget: @unchecked
  Sendable` box (the walk is sequential per call, so a simple class box is safe —
  but audit: if the walk ever goes concurrent, this breaks. Comment it).
- When budget hits zero: stop descending, and mark the *parent* node so the
  serializer can emit `[truncated: ~N more descendants — re-query with handleId h_X,
  maxDepth Y]`. "N more" can be a cheap `AXChildren` count without recursing.
- `AXNode` gains `truncatedChildren: Int?` (nil = complete).

**Serializer** (`AX/TreeSerializer.swift`): both text and JSON formats emit the
marker; text format appends the re-query hint line so agents know the next step
without docs.

**Ordering guarantee (important):** `TreeWalker` is also the handle-minter (every
walked node gets `h_N`). Truncation must not leave handles unminted for visible
nodes — budget exhaustion is the only skip, and the marker always carries the
parent handle so the drill-down path works.

**Client/MCP:** pass `maxNodes` through; tool description updates ("start with
maxDepth 2–3 + maxNodes 300 for orientation, then drill in by handleId").

**Tests:** Swift tests for budget exhaustion at 0/1/N, pass-through-skipped-element
interaction, marker contents; vitest for plumbing.

---

## Implementation order

1. **Regex filters** — smallest, self-contained, immediate byte win on
   `list_windows` (61 KB → KBs).
2. **YAML output** — pure client, no daemon rebuild; biggest across-the-board win
   (~30–45% on structured payloads vs pretty-printed JSON).
3. **`maxNodes`** — touches the walker (most delicate); do last with the others
   already landed.

Each step ships independently: schema additions are additive/optional, YAML is
presentation-only, `maxNodes` defaults to current behavior.

## Verification

- `cd client && npm test` + `cd daemon && swift test` after each step.
- Rebuild daemon (`./scripts/build-daemon.sh`), restart, re-run a mini sweep of
  `list_windows` / `query_tree` / `get_element`, then diff the request log's
  `resultBytes` against the 2026-08-10 baseline — the log makes the savings
  measurable end-to-end. Target: `list_windows` filtered < 1 KB, `get_element`
  YAML ≤ 60% of previous bytes, `query_tree` capped at the marker.
