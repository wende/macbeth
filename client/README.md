# Macbeth

Macbeth is an open-source computer-use layer for macOS. It gives MCP-compatible agents and TypeScript programs structured UI access, actions, screenshots, local Apple Vision OCR, menus, AppleScript, Shortcuts, and reusable application skills across native AppKit and Electron interfaces.

## MCP server

Macbeth requires macOS 14 or newer and Node.js 20 or newer. It runs locally over stdio and does not require environment variables.

```bash
npx -y macbeth
```

Generic MCP configuration:

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

Run `npx macbeth doctor` to check Accessibility and Screen Recording permissions.

## TypeScript API

```bash
npm install macbeth
```

```ts
import { connect } from "macbeth";

const app = await connect("TextEdit");
await app.window("Untitled").textField().fill("Hello from Macbeth");
```

Macbeth can act inside applications with the authority of the current user. Connect only trusted agents and require approval for consequential actions.

Documentation, source, and security guidance: https://github.com/wende/macbeth

MIT licensed.
