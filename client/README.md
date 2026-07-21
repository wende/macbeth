<p align="center">
  <img src="../assets/macbeth-logo.svg" alt="Macbeth" width="420" />
</p>

# Macbeth

Playwright-style automation for native macOS apps via the Accessibility API.

```bash
npm install macbeth
```

TypeScript client with chainable locators, auto-waiting, and screenshots. Drives native AppKit apps and Electron/Chromium apps (Slack, VS Code, Discord). Also ships as an MCP server for LLM agents.

```ts
const app = await macbeth.connectApp("Safari");
const url = app.locator({ role: "text_field", title: "Address" });
await url.fill("https://anthropic.com");
await url.pressKey("return");
```

Apache/MIT, macOS 14+, Node 20+.
