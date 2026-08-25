import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { firstSentence, formatGlobalHelp } from "../cli.js";

const rootDir = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const cliEntry = join(rootDir, "client/bin/macbeth.mjs");
const cliBuilt = existsSync(join(rootDir, "client/dist/cli.js"));

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

  it.skipIf(!cliBuilt)("lists MCP tools in `macbeth help` and per-tool --help", () => {
    const help = runCli(["help"]);
    expect(help.status).toBe(0);
    expect(help.stdout).toContain("list_apps");
    expect(help.stdout).toContain("run_applescript");
    expect(help.stdout).toContain("macbeth <tool> --json");

    const click = runCli(["click", "--help"]);
    expect(click.status).toBe(0);
    expect(click.stdout).toContain("--app");
    expect(click.stdout).toContain("--handle-id");
    expect(click.stdout).toContain("--json");
  });

  it.skipIf(!cliBuilt)("runs list_skills without starting the daemon", () => {
    const result = runCli(["list_skills"]);
    expect(result.status).toBe(0);
    expect(result.stdout).toMatch(/macbeth/i);
    expect(result.stderr).not.toMatch(/macbethd binary not found/);
  });

  it.skipIf(!cliBuilt)("rejects ambiguous --json and repeated --app flags", () => {
    const jsonFlag = runCli(["click", "--json", "--app", "Finder"]);
    expect(jsonFlag.status).toBe(1);
    expect(jsonFlag.stderr).toMatch(/requires a JSON object/);

    const repeated = runCli(["click", "--app", "Finder", "--app", "1234"]);
    expect(repeated.status).toBe(1);
    expect(repeated.stderr).toMatch(/Repeated --app/);

    const noHandle = runCli(["click", "--no-handle-id"]);
    expect(noHandle.status).toBe(1);
    expect(noHandle.stderr).toMatch(/only valid for boolean options/);
  });
});

describe("CLI help blurbs", () => {
  it("does not split a sentence on SKILL.md and truncates long text with an ellipsis", () => {
    expect(firstSentence("Load a skill's SKILL.md instructions (and list any runnable scripts). Next.")).toBe(
      "Load a skill's SKILL.md instructions (and list any runnable scripts)."
    );
    expect(firstSentence("a".repeat(200)).endsWith("…")).toBe(true);
    expect(firstSentence("a".repeat(200)).length).toBe(110);
    expect(formatGlobalHelp()).toContain("SKILL.md");
  });
});
