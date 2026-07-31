import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const rootDir = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const cliEntry = join(rootDir, "client/bin/macbeth.mjs");

function runCli(args: string[]) {
  return spawnSync(process.execPath, [cliEntry, ...args], { encoding: "utf8" });
}

describe("macbeth CLI", () => {
  it.each(["mcp", "serve", "server", "start"])(
    "names the correct invocation for `%s`",
    (alias) => {
      const result = runCli([alias]);
      expect(result.status).toBe(1);
      expect(result.stderr).toContain(`Unknown command: ${alias}`);
      expect(result.stderr).toContain("the MCP server is the default");
      expect(result.stderr).toContain("run `macbeth` with no arguments");
    }
  );

  it("still shows full help for an unrelated unknown command", () => {
    const result = runCli(["frobnicate"]);
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("Unknown command: frobnicate");
    expect(result.stdout).toContain("macbeth — open-source Computer Use for macOS");
  });
});
