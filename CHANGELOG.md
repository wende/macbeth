# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.4] - 2026-08-02

### Added
- `press_key` / `press_keys` report a verifiable three-tier outcome (attempted,
  dispatched, verified) instead of an unconditional `{"success": true}`.
- `list_windows`'s `app` filter is now optional, so listing every window-owning app
  is a single call.
- `connect_app` accepts an `appHandle` to re-address a previously discovered app, and
  `list_apps` / `connect_app` report real AX failure reasons instead of bare error codes.
- Element handles from `query_tree` stay stable across repeated tree walks (keyed on
  AX identity) instead of getting a new id on every call.

### Fixed
- Isolated `run_applescript` timeouts from server health tracking, so a script that hits
  its own deadline no longer trips the daemon's health/circuit-breaker state.
- Kept the interaction glow continuous across app hand-offs instead of blanking out
  between tool calls that target different apps.
- `macbeth mcp` (and `serve`/`server`/`start`) now fail with a message pointing at the
  correct no-argument command instead of a bare "Unknown command".

## [0.2.3] - 2026-07-30

### Added
- Read-only multi-window discovery, with window discovery defaults aligned to the
  protocol schema.

### Changed
- Replaced OSAScript 25ms polling with a deadline race for script execution.
- Sped up OCR and added a capture glow indicator for background screenshots.

## [0.2.2] - 2026-07-22

### Added
- Published Macbeth to the MCP Registry, with the marketplace icon wired into the
  Registry entry.
- Vercel preview deployments.
- `doctor` now emits a paste-to-your-agent fix block on failure.

### Changed
- Repositioned README/landing content around macOS computer use, with a refreshed
  walkthrough asset and social preview.
- Secured external website links.

### Fixed
- MiniMax review diffing against the PR base tip instead of stale diffs.

## [0.2.1] - 2026-07-18

### Added
- `macbeth update` self-update command.
- Landing page with GitHub Pages deployment.

### Fixed
- Screenshot scaling on non-Retina displays.
- Query descent ordering and a connection leak in the daemon.
- npm release publishing.

## [0.2.0] - 2026-07-17

### Added
- Electron app support, including click/fill handling tuned for Chromium's
  accessibility quirks.
- Screen-edge glow indicator for active system interaction, with safe mouse click
  restoration and idle-wait support.
- macOS GitHub Actions Accessibility CI prototype and expanded native/Electron test apps.

## [0.1.0] - 2026-05-21

### Added
- Initial release: Swift daemon (`macbethd`) driving macOS apps through the
  Accessibility API, a TypeScript client over JSON-RPC, and an MCP server for
  LLM agents.
