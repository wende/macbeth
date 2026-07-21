# Contributing to Macbeth

Contributions are welcome across the Swift daemon, TypeScript client, MCP surface, documentation, tests, and application skills. Keep claims reproducible: describe what was tested, on which macOS and application versions, and where the workflow still fails.

## Development setup

Requirements:

- macOS 14 or newer
- Node.js 20 or newer
- Swift 6.0 or newer when building the daemon

Install dependencies and run the non-GUI checks:

```bash
npm install
npm --prefix client run build
npm --prefix client test
swift test --package-path daemon
```

GUI and Electron tests require the relevant macOS permissions and applications. See [Developing with Macbeth](skills/DEVELOPING_MACBETH.md#writing-tests) before running them.

For a new RPC method, update the shared schema, Swift handler, TypeScript client, and MCP surface together. The complete path is documented in [Architecture](docs/architecture.md#adding-an-rpc-method).

## Contributing an application skill

An application skill teaches an agent how to use existing Macbeth primitives reliably. It usually does not require a daemon change.

### 1. Create the skill

Add `skills/<Application>/SKILL.md` with frontmatter and focused operating guidance:

```markdown
---
name: example-app
description: Inspect and operate Example App using accessibility-first workflows
---

# Example App Automation

## Connect

## Backends

## Reliable workflows

## Gotchas
```

Document what the application actually exposes: stable roles and labels, menu paths, useful shortcuts, readiness delays, version-specific behavior, and the fallback order when accessibility information is incomplete.

### 2. Add scripts only when they improve reliability

Optional runnable scripts live in `skills/<Application>/scripts/` and use `.mjs`. Start each script with metadata so `load_skill` can describe it:

```js
// @description Read the selected item without modifying it
// @usage node skills/ExampleApp/scripts/read-selection.mjs
```

Prefer the public `macbeth` API. Do not embed credentials, personal paths, private data, or assumptions about another user's account. Avoid destructive behavior by default and require explicit arguments for consequential actions.

### 3. Supply reproducible evidence

A skill pull request should include:

- the application and version tested;
- the macOS version and required permissions;
- an exact task prompt or script invocation;
- the expected end state and how it was verified;
- known failure modes and fallback strategies;
- a short recording or trace when practical.

Generic compatibility is not the same as a dedicated skill. Do not mark an application as supported or planned solely because it uses AppKit or Electron.

### 4. Validate discovery and execution

Confirm that `list_skills` finds the new directory, `load_skill` renders its instructions and script metadata, and every included script runs from the repository root. Test read-only workflows first, then any mutating workflow against disposable data.

## Pull requests

- Keep changes focused and preserve unrelated work in the tree.
- Add or update tests for behavior changes.
- Update the README only for capabilities available on the branch being merged.
- Avoid universal compatibility, reliability, privacy, or security claims without evidence.
- Explain user-visible permission or data-handling changes explicitly.

Security vulnerabilities should follow the private reporting guidance in [SECURITY.md](SECURITY.md#report-a-vulnerability).
