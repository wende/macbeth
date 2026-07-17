<!-- README hero · Option 2 — Feature strip + badges
     Style: Cypress / Prisma. Logo, title, shields, then a feature table strip.
     When pasting into repo-root README.md, change the logo src to assets/macbeth-logo.svg
     and drop this comment. Replace from logo through intro paragraphs (before ## Demo). -->

<p align="center">
  <img src="macbeth-logo.svg" alt="Macbeth" width="340" />
</p>

<h1 align="center">Macbeth</h1>

<p align="center">
  <em>Playwright for macOS apps</em> — drive real desktop UI via the Accessibility API.
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/macbeth"><img src="https://img.shields.io/npm/v/macbeth?style=flat-square&color=61202F&labelColor=1a1520" alt="npm" /></a>
  <img src="https://img.shields.io/badge/license-MIT-8B3342?style=flat-square&labelColor=1a1520" alt="MIT" />
  <img src="https://img.shields.io/badge/macOS-14%2B-32111A?style=flat-square&logo=apple&logoColor=white&labelColor=1a1520" alt="macOS" />
  <img src="https://img.shields.io/badge/Node-%E2%89%A520-339933?style=flat-square&logo=nodedotjs&logoColor=white&labelColor=1a1520" alt="Node" />
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white&labelColor=1a1520" alt="Swift" />
  <img src="https://img.shields.io/badge/TypeScript-3178C6?style=flat-square&logo=typescript&logoColor=white&labelColor=1a1520" alt="TypeScript" />
  <img src="https://img.shields.io/badge/MCP-ready-8B5CF6?style=flat-square&labelColor=1a1520" alt="MCP" />
  <img src="https://img.shields.io/badge/Electron-%E2%9C%93-47848F?style=flat-square&logo=electron&logoColor=white&labelColor=1a1520" alt="Electron" />
  <a href="https://github.com/wende/macbeth/stargazers"><img src="https://img.shields.io/github/stars/wende/macbeth?style=social" alt="stars" /></a>
</p>

| Native + Electron | Playwright locators | MCP + glow | Screenshots & OCR |
|:-----------------:|:-------------------:|:----------:|:-----------------:|
| AppKit **and** Chromium (Slack, VS Code, Discord…) | Chainable, lazy, auto-waiting | Tools for agents, live window outlines | ScreenCaptureKit + Vision when AX is thin |

```bash
npm install macbeth
```

TypeScript client + Swift daemon over JSON-RPC. Auto-spawns `macbethd` — no manual setup.
