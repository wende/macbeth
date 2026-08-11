# Token Churn Reduction — E2E Test Report

Date: 2026-08-11
Branch: `plan/2026-08-10-token-churn-reduction`
Verdict: ships — but the instrumentation that was supposed to prove it was reading the wrong layer.

Total model-facing cost across 22 real tool calls drops **18.3%** in tokens and 18.7% in bytes, with targeted wins up to 92.6%. Two scenarios get *larger*; both are explained below and one is a real behaviour change outside the plan's stated scope.

---

## 1. Do MCP calls produce logs?

Yes. Each MCP tool call produces one NDJSON record in the daemon's `requests.log` — verified by watching the file grow 72 → 73 lines across a single `list_apps` call:

```
list_apps  ok=True  params=57B  result=1614B  280ms
```

## 2. The logging bug

`requests.log` measures **the wrong layer**. `resultBytes` is documented as "UTF-8 byte count of encoded response" — the JSON-RPC payload leaving the daemon. But the model does not read that payload. `toModelPayload` converts results to YAML **client-side, in `mcp.ts`, after the daemon has already logged.**

So the plan's broadest win — YAML instead of JSON, affecting seven tools — is **completely invisible** to the daemon log. Anything asking "how much context does this tool cost?" from `requests.log` reads a number that was correct before the payload was rewritten.

**Fixed** in `client/src/mcp-usage-log.ts` (commit `f8fc404`): a second log, `mcp.log`, written by the MCP server process at the last point before the payload crosses to the host.

The measurement wraps the **transport**, not the tool handlers. Handlers return content blocks, but byte and token cost is a property of the *serialized* payload, and several tools produce theirs through shared helpers (`toModelPayload`, `runListWindowsTool`) that no single handler owns. Wrapping `send`/`onmessage` measures every tool exactly once, including ones added later, and cannot drift out of sync with the handlers.

Each record separates the two layers that were previously conflated:

```json
{"ts":"2026-08-11T13:38:37.238Z","tool":"query_tree","requestID":"12","ok":true,
 "durationMs":892,"payloadBytes":15240,"textBytes":15122,
 "textTokensEstimated":4821,"imageBytes":0,"blocks":1,"tokenEstimator":"heuristic-v1"}
```

`payloadBytes` is the wire payload (what `requests.log` sees); `textBytes` is what the model actually reads. Image blocks are counted as bytes only — a text heuristic cannot price them, and reporting base64 length as tokens would be a fabricated number.

Honours the same `MACBETH_NO_LOG` / `MACBETH_LOG_DIR` and rotation knobs as the daemon log, so one env var silences both. Every write failure is swallowed: logging must never turn a working tool call into a failed one.

## 3. Token counting

Per the "heuristic only" call: zero new dependencies. `gpt-tokenizer` stayed in `/tmp` as a calibration instrument and never entered the project.

A single bytes÷4 ratio would have been wrong for most real AX content — token density per byte differs about **fourfold** between scripts (Cyrillic ~7.6 B/token, emoji ~2.0). The estimator splits text by script class and bills each at its own measured rate, with special handling for the shapes that tokenize unlike prose: paths, base64 blobs, and digit runs (digits group ~3 per token — `188` is one token, not three).

Rule ordering is load-bearing: the base64 pattern also matches a path's alnum stretches at a much denser rate, so paths are extracted **first**, or `/Users/.../requests.log` gets billed as if it were a hash.

| Validation | Result |
|---|---|
| 132 captured MCP payloads (o200k_base) | **5.9% mean, 20.7% worst** |
| Live re-verification, 22 payloads | **6.4% mean, 19.8% worst** |
| Adversarial single-shape inputs | ≤29% |
| Train vs holdout (⅓ / ⅔ split) | 5.8% vs 5.7% — a fit, not a memorisation |

The train/holdout agreement is the number that matters: coefficients fitted on one third generalize to the rest, so this is not tuned to the benchmark. Every count is reported as `estimated` so nobody mistakes it for billing.

**31 unit tests** cover both modules. Full suite: **198 passed, 33 skipped, 0 failed** — up from 167.

## 4. Before / after

Both stacks were driven over **real MCP stdio**, as an agent would — not through the daemon log, which as established cannot see the YAML conversion. Branch-only parameters (`titlePattern`, `maxNodes`) are dropped on the baseline arm, so each baseline call is the one an agent would actually have made before this branch.

UI state drifts between runs (windows open and close, titles change), so a single baseline-then-branch pair would conflate drift with effect. Runs are **interleaved A/B/A/B ×3** with the daemon killed and re-pinned between arms; the table reports medians. Within-arm spread came out at ~0.

| Scenario | Base T | Branch T | Δ tokens |
|---|---|---|---|
| list_windows_filtered | 9,648 | 718 | **−92.6%** |
| list_menu_bar_filtered | 1,197 | 127 | **−89.4%** |
| query_tree_finder_orient | 9,260 | 4,882 | **−47.3%** |
| get_element_actmon | 52 | 35 | −32.7% |
| get_element_finder | 56 | 38 | −32.1% |
| screenshot_finder | 69 | 56 | −18.8% |
| list_windows_all_surfaces | 26,681 | 21,706 | −18.6% |
| list_windows_global | 9,959 | 8,118 | −18.5% |
| dump_attributes_finder | 1,058 | 939 | −11.2% |
| query_tree_actmon_capped | 6,836 | 6,128 | −10.4% |
| query_tree_messages_capped | 6,378 | 5,752 | −9.8% |
| query_tree_finder_capped | 5,561 | 5,105 | −8.2% |
| list_daemon_methods | 116 | 114 | −1.7% |
| query_tree_messages_d8 | 6,378 | 6,351 | −0.4% |
| query_tree_finder_d8 | 9,260 | 9,250 | −0.1% |
| query_tree_actmon_d8 | 6,835 | 6,829 | −0.1% |
| list_apps / list_menu_bar / read_form | — | — | 0.0% |
| **query_tree_finder_d5** | 5,561 | 5,695 | **+2.4%** |
| **query_tree_finder_json** | 15,877 | 16,374 | **+3.1%** |
| **TOTAL** | **123,000** | **100,435** | **−18.3%** |

### Plan-target scorecard

| Target | Actual | |
|---|---|---|
| filtered `list_windows` < 1 KB | 2.1 KB | miss on bytes (−92.6% tokens) |
| `get_element` YAML ≤ 60% of previous bytes | 75% (120/160) | miss |
| `query_tree` capped at the truncation marker | marker emitted, −47.3% | pass |

The two misses are threshold misses, not direction misses — both payloads shrank substantially (the filtered call by 92.6% in tokens). Reported against the criteria as written rather than against a softer bar.

## 5. Two things got bigger

**`query_tree_finder_d5` +2.4% — a real behaviour change, out of scope.** Not noise. `expandPassThrough` in `TreeWalker.swift` was made **recursive**, and it surfaces 12 additional real nodes (button +4, cell +9, focused +9, split_group −1) with zero truncation markers. That is a genuine quality gain — previously-hidden controls are now visible — but it costs tokens, and it is not part of the plan's stated three-item scope. Worth an explicit decision rather than silent inclusion.

**`query_tree_finder_json` +3.1% — unexplained.** The JSON output path got larger on the branch. Not investigated; low impact, but it should not have moved at all.

## 6. Notes

- `maxNodes` only pays off when the tree exceeds the budget: capped scenarios at depth 8 save 8–47%, while uncapped depth-8 calls are unchanged (−0.1%). The orient case (depth 8, `maxNodes: 300`) is where the cap earns its keep at −47.3%.
- The MCP SDK's stdio client strips all but an allowlist (`HOME`/`PATH`/`SHELL`/`TERM`/`USER`) from the child env. That is a harness detail, not a product issue — the default log path needs no env var — but it silently swallowed `MACBETH_LOG_DIR` during verification and cost a debugging round.

## Open questions for the reviewer

- The `expandPassThrough` recursion change needs a scope decision (keep as a quality win, or split out).
- The JSON-format +3.1% is unexplained.
- `get_element` misses the plan's ≤60%-of-previous-bytes target at 75%.
- New `mcp.log` instrumentation lives on the same branch — fold it in or split into a separate PR?
