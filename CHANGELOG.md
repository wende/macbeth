# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.4] - 2026-08-02

### Added
- `press_key` / `press_keys` report a verifiable three-tier outcome (attempted,
  dispatched, verified) instead of an unconditional `{"success": true}`.
  ([#43](https://github.com/wende/macbeth/pull/43))
- `list_windows`'s `app` filter is now optional, so listing every window-owning app
  is a single call. ([#42](https://github.com/wende/macbeth/pull/42))
- `connect_app` accepts an `appHandle` to re-address a previously discovered app, and
  `list_apps` / `connect_app` report real AX failure reasons instead of bare error codes.
  ([#37](https://github.com/wende/macbeth/pull/37))
- Element handles from `query_tree` stay stable across repeated tree walks (keyed on
  AX identity) instead of getting a new id on every call.
  ([#40](https://github.com/wende/macbeth/pull/40))

### Fixed
- Isolated `run_applescript` timeouts from server health tracking, so a script that hits
  its own deadline no longer trips the daemon's health/circuit-breaker state.
  ([#38](https://github.com/wende/macbeth/pull/38))
- Kept the interaction glow continuous across app hand-offs instead of blanking out
  between tool calls that target different apps. ([#24](https://github.com/wende/macbeth/pull/24))
- `macbeth mcp` (and `serve`/`server`/`start`) now fail with a message pointing at the
  correct no-argument command instead of a bare "Unknown command".
  ([#41](https://github.com/wende/macbeth/pull/41))

## [0.2.3] - 2026-07-30

### Added
- Read-only multi-window discovery, with window discovery defaults aligned to the
  protocol schema. ([#23](https://github.com/wende/macbeth/pull/23))

### Changed
- Broadened Electron/Chromium bundle detection, switched menu selection to native
  Accessibility instead of System Events, ran AppleScript/JXA in a killable worker
  with a daemon-enforced deadline, sped up OCR, and added a capture glow indicator
  for background screenshots.
  ([#20](https://github.com/wende/macbeth/pull/20), [#25](https://github.com/wende/macbeth/pull/25))
- Replaced OSAScript 25ms polling with a deadline race for script execution.
  ([#26](https://github.com/wende/macbeth/pull/26))

## [0.2.2] - 2026-07-22

### Added
- Published Macbeth to the MCP Registry, with the marketplace icon wired into the
  Registry entry. ([#22](https://github.com/wende/macbeth/pull/22))
- Vercel preview deployments. ([#19](https://github.com/wende/macbeth/pull/19))
- `doctor` now emits a paste-to-your-agent fix block on failure, and the MCP docs
  gained a one-liner install and smoke-test walkthrough.
  ([#16](https://github.com/wende/macbeth/pull/16))

### Changed
- Repositioned README/landing content around macOS computer use, with a refreshed
  walkthrough asset, social preview, and secured external links.
  ([#19](https://github.com/wende/macbeth/pull/19))
- Slimmed the README into an MCP and test-tool landing page, and clarified Screen
  Recording guidance in the developing guide. ([#17](https://github.com/wende/macbeth/pull/17))
- Sharpened on-demand Screen Recording guidance. ([#21](https://github.com/wende/macbeth/pull/21))

### Fixed
- MiniMax review diffing against the PR base tip instead of stale diffs.
  ([#15](https://github.com/wende/macbeth/pull/15))

## [0.2.1] - 2026-07-18

### Added
- `macbeth update` self-update command. ([#14](https://github.com/wende/macbeth/pull/14))
- Landing page with GitHub Pages deployment and a refreshed README hero design.
  ([#10](https://github.com/wende/macbeth/pull/10))
- Interaction outline coverage for background and keyboard-driven foreground paths.
  ([#8](https://github.com/wende/macbeth/pull/8))

### Fixed
- Screenshot scaling on non-Retina displays. ([#12](https://github.com/wende/macbeth/pull/12))
- Query descent ordering and a connection leak in the daemon.
  ([#9](https://github.com/wende/macbeth/pull/9))
- npm release publishing.

## [0.2.0] - 2026-07-17

### Added
- Electron app support, including click/fill handling tuned for Chromium's
  accessibility quirks. ([#1](https://github.com/wende/macbeth/pull/1))
- Screen-edge glow indicator for active system interaction.
  ([#2](https://github.com/wende/macbeth/pull/2))
- Safe mouse click restoration and idle-wait support.
  ([#6](https://github.com/wende/macbeth/pull/6))
- MCP-only visibility demo and interaction overlays.
  ([#7](https://github.com/wende/macbeth/pull/7))
- macOS GitHub Actions Accessibility CI prototype and expanded native/Electron test
  apps. ([#4](https://github.com/wende/macbeth/pull/4), [#5](https://github.com/wende/macbeth/pull/5))

## [0.1.0] - 2026-05-21

### Added
- Initial release: Swift daemon (`macbethd`) driving macOS apps through the
  Accessibility API, a TypeScript client over JSON-RPC, and an MCP server for
  LLM agents.
