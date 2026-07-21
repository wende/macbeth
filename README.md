<p align="center">
  <img src="assets/macbeth-logo.svg" alt="Macbeth" width="300" />
</p>

<h1 align="center">Macbeth — Computer Use for macOS</h1>

<p align="center">
  <strong>Let the agent you already use inspect and operate your Mac.</strong>
</p>

<p align="center">
  Macbeth is an open-source control layer for native AppKit and Electron applications.<br />
  It gives MCP agents and TypeScript scripts structured UI trees, reliable actions, screenshots, OCR, menus, AppleScript, Shortcuts, and reusable app skills.
</p>

<p align="center"><em>Think Playwright for your Mac: structured locators when available, visual fallbacks when necessary.</em></p>

<p align="center">
  <a href="#quickstart">Quickstart</a> ·
  <a href="#what-can-your-agent-do">Examples</a> ·
  <a href="#typescript-api">TypeScript</a> ·
  <a href="#security-and-limitations">Security</a> ·
  <a href="#teach-macbeth-an-application">Skills</a>
</p>

## Quickstart

Give Claude Code access to Macbeth:

```bash
claude mcp add macbeth -- npx -y macbeth
```

Then ask it to verify the connection:

> Using Macbeth, list the running applications, connect to Finder, inspect its front window, and summarize the first few controls you can see. Do not perform any other actions.

Macbeth ships with a prebuilt, signed and notarized universal daemon. No Swift toolchain or manual service installation is required. If setup fails, run `npx macbeth doctor`; it prints a self-contained diagnostic prompt you can paste back into your agent.

Any MCP client that can launch a stdio server can use `npx -y macbeth`. See [MCP setup](docs/mcp.md) for generic configuration, updates, and the complete tool list.

<details>
<summary>Let your agent guide the installation</summary>

> Add Macbeth as an MCP server using `npx -y macbeth`. Run `npx macbeth doctor`, guide me through granting only the permissions I need, and verify the setup by inspecting Finder. Do not take any unrelated actions.

</details>

> [!CAUTION]
> Macbeth can read visible interface content and can click, type, run scripts, invoke Shortcuts, and operate menus. Connect it only to agents and MCP clients you trust, and require confirmation for consequential actions.

## What can your agent do?

### Work in a professional application

> “In Logic Pro, set the project tempo to 128 BPM and start playback.”

The bundled [Logic Pro skill](skills/LogicPro/SKILL.md) documents its transport, tracks, tempo, mixer, menus, and known accessibility quirks.

### Inspect and navigate macOS

> “Open System Settings, find the firewall controls, and report their current state without changing anything.”

Macbeth can inspect named controls and values, select native menu items, and use keyboard input when a semantic action is unavailable.

### Work with Electron interfaces

> “Inspect this Electron application's front window, find its main search field, and tell me which controls are available.”

Macbeth enables Chromium's accessibility tree and applies Electron-aware click and fill strategies. The exact tree still varies by application and version; see the [Electron skill](skills/electron/SKILL.md).

### See beyond the accessibility tree

> “Capture the frontmost Notes window and extract all visible text.”

ScreenCaptureKit screenshots and local Vision OCR provide a fallback for content that macOS does not expose as useful accessibility data.

### Build repeatable scripts and tests

The same engine is available as a TypeScript API with lazy locators, auto-waiting actions, explicit state waits, screenshots, and application connections.

## Why Macbeth?

- **Use your own agent.** Macbeth is a control layer, not a model or agent runtime.
- **Structured when possible.** Query roles, labels, values, enabled state, hierarchy, and stable handles instead of relying only on coordinates.
- **Visual when necessary.** Fall back to window capture and OCR when accessibility metadata is thin.
- **Application-aware.** Versioned skills preserve workflows, shortcuts, and known failure modes.
- **Scriptable.** Use the same primitives interactively over MCP or directly from TypeScript.

### Structured before pixels

| Capability | Screenshot-only control | Macbeth |
|---|---|---|
| Find a labeled control | Visual inference | Accessibility query when exposed |
| Read role, value, and state | Inferred | Structured attributes |
| Wait for a UI change | Repeated captures | Explicit waits and auto-waiting actions |
| Handle incomplete UI metadata | Vision/OCR | Accessibility first, screenshot/OCR fallback |
| Reuse application knowledge | Prompt-dependent | Bundled, versioned skills |

Accessibility information can itself be incomplete or misleading. Macbeth is a hybrid interface: it uses stronger structured primitives when macOS exposes them and keeps visual and system-level fallbacks available when it does not.

## Security and limitations

- Macbeth requires macOS 14 or newer and Node.js 20 or newer.
- Accessibility permission is required for UI inspection and interaction. Screen Recording is required only for screenshots and window OCR.
- Application accessibility quality varies. Custom-rendered canvases, games, and some creative tools may require menus, screenshots, OCR, keyboard input, or application-specific guidance.
- Interface changes between application versions can break specialized workflows.
- The interaction glow makes Macbeth activity visible, but it is not an approval system or a complete audit log.
- Agents can make mistakes. Use human review for destructive, financial, publishing, or privacy-sensitive actions.

Macbeth uses a local stdio MCP server and a Unix-domain socket; it does not open a TCP listener. Screenshots requested through MCP are written to a temporary directory and are not automatically deleted. Read the [security model](SECURITY.md) for data flow, permission revocation, local-process risks, and safer operating practices.

## TypeScript API

```bash
npm install macbeth
```

```ts
import { connect } from "macbeth";

const app = await connect("TextEdit");
await app.window("Untitled").textField().fill("Hello from Macbeth");
await app.pressKey("s", ["cmd"]);
```

See [Developing with Macbeth](skills/DEVELOPING_MACBETH.md) for locators, screenshots, Electron behavior, lifecycle, and tests.

## Teach Macbeth an application

A Macbeth skill is a `SKILL.md` file, optionally accompanied by runnable scripts, that teaches an agent an application's reliable workflows and pitfalls. Bundled skills cover Calendar, Contacts, Logic Pro, Mail, Maps, Messages, Music, Notes, Reminders, Safari, System Settings, and generic Electron applications.

You can add a skill without changing the Swift daemon. Start with the [contribution guide](CONTRIBUTING.md#contributing-an-application-skill) and include a reproducible prompt, tested application version, expected result, and honest failure modes.

## Documentation

| Guide | Contents |
|---|---|
| [MCP server](docs/mcp.md) | Installation, smoke test, tools, skills, and updates |
| [TypeScript API](skills/DEVELOPING_MACBETH.md) | Client API, locators, Electron, and tests |
| [Architecture](docs/architecture.md) | Daemon, protocol, fallbacks, and design notes |
| [Security](SECURITY.md) | Trust boundaries, data handling, and permission revocation |
| [Troubleshooting](TROUBLESHOOTING.md) | Diagnostics and common setup failures |
| [Contributing](CONTRIBUTING.md) | Development workflow and application skills |

## Requirements

- macOS 14 (Sonoma) or later
- Node.js 20+
- Swift 6.0+ only when building the daemon from source

## License

MIT
