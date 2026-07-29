import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const demoSource = readFileSync(
  fileURLToPath(new URL("../../../scripts/demo-background.mjs", import.meta.url)),
  "utf8"
);

describe("background demo contract", () => {
  it("uses ordinary tools without explicit glow-control calls", () => {
    expect(demoSource).not.toMatch(/["'](?:begin|end)_activity["']/);
  });

  it("covers the presentation fixture and tool feature set", () => {
    expect(demoSource).toContain('pollTool(\n      "connect_app"');
    expect(demoSource).toContain('callTool("fill"');
    expect(demoSource).toContain('callTool("click"');
    expect(demoSource).toContain('callTool("screenshot"');
    expect(demoSource).toContain("--args --presentation");
    expect(demoSource).toContain("--force-renderer-accessibility");
    expect(demoSource).toContain("Electron Demo");
  });

  it("restores the sentinel before every measured action", () => {
    expect(demoSource).toMatch(
      /async function measuredAction[\s\S]*?await ensureSentinelFrontmost\(\)/
    );
  });

  it("measures activation events without controlling fixture focus", () => {
    expect(demoSource).toContain("scripts/watch-frontmost.swift");
    expect(demoSource).toContain("analyzeFocus");
    expect(demoSource).not.toContain("setTargetFrontmost");
  });
});
