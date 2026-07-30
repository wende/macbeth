import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const demoSource = readFileSync(
  fileURLToPath(new URL("../../../scripts/demo-presentation.mjs", import.meta.url)),
  "utf8"
);

describe("presentation demo contract", () => {
  it("uses ordinary tools without explicit glow-control calls", () => {
    expect(demoSource).not.toMatch(/["'](?:begin|end)_activity["']/);
  });

  it("launches the native fixture in its presentation viewport", () => {
    expect(demoSource).toContain("--args --presentation");
  });

  it("covers the presentation fixture and tool feature set", () => {
    // Match callTool("…") string form — not bare fill( — same style as demo-background.
    expect(demoSource).toContain('callTool("fill"');
    expect(demoSource).toContain('callTool("click"');
    expect(demoSource).toContain('callTool("screenshot"');
    expect(demoSource).toContain("Electron Demo");
  });
});
