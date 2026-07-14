# Flash-click integration test

Local-only, manual test for the coordinate "flash click" fallback. **It cannot
run in CI** — it needs a macOS GUI session, a window server, and Accessibility
permission granted to `macbethd` (CI has none of these).

## What it covers

1. **auto escalates to flash** — a custom `NSView` ("canvas") is visible to the
   Accessibility API but advertises no `AXPress` action, so the default `auto`
   strategy must fall through to the flash click for the click to register.
2. **Restoration** — with TextEdit frontmost, a flash click returns focus to
   TextEdit afterwards.
3. **Minimized target** — the flash un-minimizes the window, clicks, and
   re-minimizes it.
4. **Forced flash** — `strategy: "flash"` drives a normal `AXPress`-capable
   button.
5. **Regression** — the default path still uses `AXPress` on a native button
   (no focus steal).

## Running

```bash
# 1. Build daemon + client
./scripts/build-daemon.sh
cd client && npm run build && cd ..

# 2. Launch the test app (leave it running in another terminal)
swift test/flash-click/TestApp.swift

# 3. Run the harness
node test/flash-click/run.mjs
```

Grant Accessibility permission to the daemon (and, on first run, to your
terminal) in System Settings → Privacy & Security → Accessibility.

## Files

- `TestApp.swift` — minimal AppKit app. Publishes click counts in its window
  title (`FlashClickTestApp — canvas:<N> button:<M>`) so the harness can read
  them back over AX.
- `run.mjs` — the harness. Asserts on observable effects (counters, frontmost
  app, minimized state).
