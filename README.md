<p align="center">
  <img src="assets/macbeth-logo.svg" alt="Macbeth" width="300" />
</p>

<h1 align="center">Playwright for macOS</h1>

<p align="center">
  <a href="https://www.npmjs.com/package/macbeth"><img src="https://img.shields.io/npm/v/macbeth?style=for-the-badge&color=61202F&labelColor=1a1520" alt="npm" /></a>
  <img src="https://img.shields.io/badge/license-MIT-8B3342?style=for-the-badge&labelColor=1a1520" alt="MIT" />
  <img src="https://img.shields.io/badge/macOS-14%2B-32111A?style=for-the-badge&logo=apple&logoColor=white&labelColor=1a1520" alt="macOS" />
  <img src="https://img.shields.io/badge/MCP-ready-8B5CF6?style=for-the-badge&labelColor=1a1520" alt="MCP" />
</p>

<p align="center">
  Chainable locators, auto-waiting, screenshots, OCR, and an MCP server — so TypeScript scripts and LLM agents can drive native AppKit and Electron apps alike.
</p>

```bash
npm install macbeth
```

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#mcp-server">MCP</a> ·
  <a href="#test-tool">Test tool</a> ·
  <a href="#docs">Docs</a> ·
  <a href="https://github.com/wende/macbeth/issues">Issues</a>
</p>

## Features

- **Any Mac app, one API** — Native and Electron apps alike — same locators, same actions.
- **Playwright-style locators** — Chainable queries with auto-waiting click, fill, and keyboard input.
- **MCP for agents** — Tool calls for Claude and friends, with an on-screen interaction glow.
- **Screenshots & OCR** — Capture any window and read its text — even when AX sees nothing.
- **LLM-readable UI trees** — Clean, indented element trees agents can act on directly.
- **Menus, AppleScript, Shortcuts** — Menu-bar automation and system integration alongside AX queries.
- **Bundled app skills** — Calendar, Mail, Safari, System Settings, Electron, and more.

## MCP server

macbeth includes an MCP server so LLM agents (Claude, etc.) can automate macOS apps through tool calls. The published package ships a **prebuilt, notarized universal daemon** — no build step, no Swift toolchain.

**Claude Code** — register from your terminal:

```bash
claude mcp add macbeth -- npx -y macbeth
```

For other clients, add to your MCP config (e.g. `.mcp.json`):

```json
{
  "mcpServers": {
    "macbeth": {
      "command": "npx",
      "args": ["-y", "macbeth"]
    }
  }
}
```

Grant Accessibility (and Screen Recording if you need screenshots), then the agent can connect to apps, query UI trees, click, fill, screenshot, OCR, run menus/AppleScript/Shortcuts, and load bundled skills. Verify the install with `npx macbeth doctor`.

Update:

```bash
npx macbeth update          # install latest signed release
npx macbeth update --check  # report only
```

Setup for other clients, the full tool list, and skills: [docs/mcp.md](docs/mcp.md).

## Test tool

Use macbeth from Node the same way you use Playwright against a browser — connect to an app, chain locators, assert.

```bash
npm install macbeth
```

API, locators, Electron notes, and test examples: [skills/DEVELOPING_MACBETH.md](skills/DEVELOPING_MACBETH.md).

## Permissions

| Permission | When |
|---|---|
| **Accessibility** | Required for all UI automation. macOS prompts on first use, or grant in System Settings → Privacy & Security → Accessibility. |
| **Screen Recording** | Screenshots/OCR only. If missing when requested, macbeth opens the correct Settings pane. |

No login items or background services. The TypeScript client auto-spawns the Swift daemon and shuts it down on close; the daemon can stay warm between runs.

## Requirements

- macOS 14 (Sonoma) or later
- Node.js 20+
- Swift 6.0+ only if building the daemon from source

## Docs

| Doc | Contents |
|---|---|
| [skills/DEVELOPING_MACBETH.md](skills/DEVELOPING_MACBETH.md) | Client API, locators, Electron, writing tests |
| [docs/mcp.md](docs/mcp.md) | MCP tools, skills, updates |
| [docs/architecture.md](docs/architecture.md) | How it works and design notes |
| [docs/interaction-glow.md](docs/interaction-glow.md) | On-screen interaction indicator |
| [docs/releasing.md](docs/releasing.md) | Signed/notarized releases |
| [docs/keyboard-input-and-foregrounding.md](docs/keyboard-input-and-foregrounding.md) | Keyboard delivery and focus behavior |
| [docs/ci-prototype.md](docs/ci-prototype.md) | Experimental macOS CI permissions prototype |

## License

MIT
