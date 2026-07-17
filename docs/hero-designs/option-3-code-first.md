<!-- README hero · Option 3 — Code-first proof
     Style: Bun / Zod. Compact chunky badges + hello-world snippet as the hero.
     When pasting into repo-root README.md, change the logo src to assets/macbeth-logo.svg
     and drop this comment. Replace from logo through intro paragraphs (before ## Demo). -->

<p align="center">
  <img src="macbeth-logo.svg" alt="Macbeth" width="300" />
</p>

<h1 align="center">Playwright for macOS apps</h1>

<p align="center">
  <a href="https://www.npmjs.com/package/macbeth"><img src="https://img.shields.io/npm/v/macbeth?style=for-the-badge&color=61202F&labelColor=1a1520" alt="npm" /></a>
  <img src="https://img.shields.io/badge/license-MIT-8B3342?style=for-the-badge&labelColor=1a1520" alt="MIT" />
  <img src="https://img.shields.io/badge/macOS_14+-32111A?style=for-the-badge&logo=apple&logoColor=white&labelColor=1a1520" alt="macOS" />
  <img src="https://img.shields.io/badge/MCP-ready-8B5CF6?style=for-the-badge&labelColor=1a1520" alt="MCP" />
  <img src="https://img.shields.io/badge/Swift_6-F05138?style=for-the-badge&logo=swift&logoColor=white&labelColor=1a1520" alt="Swift" />
  <img src="https://img.shields.io/badge/TypeScript-3178C6?style=for-the-badge&logo=typescript&logoColor=white&labelColor=1a1520" alt="TypeScript" />
</p>

```ts
import { connect } from "macbeth";

const app = await connect("TextEdit");
await app.window("Untitled").textField().fill("Hello from macbeth");
await app.pressKey("s", ["cmd"]);
// process exits cleanly — daemon stays warm
```

**Native AppKit · Electron/Chromium · MCP for agents** — same locator API, Accessibility under the hood.

```bash
npm install macbeth
```

<p align="center">
  <a href="#quick-start">Docs</a> ·
  <a href="#features">Features</a> ·
  <a href="#mcp-server">MCP server</a> ·
  <a href="https://github.com/wende/macbeth/issues">Issues</a>
</p>
