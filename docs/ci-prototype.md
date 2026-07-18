# macOS CI prototype (experimental)

Workflow: [`.github/workflows/macos-accessibility-prototype.yml`](../.github/workflows/macos-accessibility-prototype.yml).

Opt-in via `workflow_dispatch` only — separate from `tests.yml`. Proves end-to-end Macbeth on a GitHub-hosted `macos-15` runner without human interaction.

## Trigger

1. Push a branch that contains the workflow.
2. Actions → **macOS Accessibility Prototype** → **Run workflow**.
3. Optional: `skip_grant_script`, `grant_verbose`.
4. Pass or fail both upload a diagnostic artifact.

## What it does

1. Builds `macbethd` under `$RUNNER_TEMP`.
2. `macbethd --check-permissions` (baseline — usually denied).
3. `scripts/ci-grant-macos-permissions.sh` writes Accessibility + Screen Recording into the **user** TCC DB by cloning a `/bin/bash` row.
4. Re-checks permissions.
5. Builds/launches `test/testapp-minimal/`.
6. `scripts/ci-e2e-test.mjs` — connect, read field, fill, click, assert status label.

User TCC is enough for `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()`. The system TCC DB on the signed system volume is not modified.

## Do not run the grant script on a developer machine

The script rewrites `~/Library/Application Support/com.apple.TCC/TCC.db`, restarts `tccd`, and clones TCC entries. Safe only on ephemeral GHA runners. On a personal Mac, grant permissions through System Settings.

## Diagnostics

Artifact `macbeth-ci-prototype-diag`:

| File | Meaning |
|---|---|
| `env.txt` | macOS version, console user, GUI session |
| `tcc-inspect.txt` | User TCC reachability / clone from bash |
| `preflight-before.txt` / `preflight-after.txt` | Permissions before/after grant |
| `grant-script.log` | Full TCC injection log |
| `harness.stdout.log` / `.stderr.log` | Harness launch |
| `e2e-test.log` | Connect / fill / click / assert trace |
| `post-run.txt` | Final TCC + harness alive |
| `result.json` | `pass` / `fail` payload |

Likely failures: grant rejected (schema/tccd), no GUI session, harness crash without WindowServer, path mismatch on Accessibility identity, fill/click blocked, status assertion (click did not fire).

The prototype is evidence-first; it is allowed to fail.
