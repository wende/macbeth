# Electron integration test

An end-to-end test of macbeth's Electron support against a **real** Electron app. It is
**local-only and macOS-only** — it needs a window server and Accessibility permissions
granted to the launching terminal, so it does not run in CI.

## What it covers

The fixture (`fixture/`) is a minimal Electron app with:

- A counter button whose count is shown in an AX-readable heading.
- A text input whose value is mirrored into a separate heading **only on real `input`
  events**. A plain AX value write does not fire input events, so the mirror stays stale —
  this is what catches the "AX write succeeds but framework state goes stale" failure mode.

`run.mjs` drives it and asserts:

1. `connect` reports `runtime: electron` and `query_tree` contains a `web_area` within the
   readiness timeout.
2. Clicking the button increments the counter (read back through AX).
3. `fill` (auto strategy) updates the mirrored state — proving keystrokes were synthesized,
   not just an AX value written.
4. Forced `strategy: "keyboard"` (fill) and `strategy: "mouse"` (click) both work.

## Run it

```bash
cd client
npm install --force          # --force: package.json pins os=darwin
npm run build

cd test-electron/fixture
npm install                  # downloads Electron (~100MB), local to the fixture

cd ..
node run.mjs                 # or, from client/:  npm run test:electron
```

Grant the terminal Accessibility permission when macOS prompts, then re-run.
