#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PACKAGE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function readVersion() {
  try {
    const pkg = JSON.parse(
      readFileSync(resolve(PACKAGE_ROOT, "package.json"), "utf8")
    );
    return pkg.version ?? "unknown";
  } catch {
    return "unknown";
  }
}

function printHelp() {
  process.stdout.write(
    `macbeth — Playwright for macOS native apps (Accessibility API)\n\n` +
      `Usage:\n` +
      `  macbeth               Start the MCP server (default; used by LLM agents)\n` +
      `  macbeth doctor        Check macOS Accessibility + Screen Recording permissions\n` +
      `  macbeth update        Update to the latest GitHub release\n` +
      `  macbeth update --check  Report whether an update is available, without installing\n` +
      `  macbeth version       Print the installed version\n` +
      `  macbeth help          Show this help\n`
  );
}

const [command, ...rest] = process.argv.slice(2);

try {
  switch (command) {
    case "update":
    case "self-update":
    case "upgrade": {
      const { runUpdate } = await import("../dist/update.js");
      process.exit(await runUpdate(rest));
    }
    case "doctor": {
      const { spawnSync } = await import("node:child_process");
      const { DaemonManager } = await import("../dist/daemon.js");
      let binary;
      try {
        binary = new DaemonManager().daemonBinaryPath;
      } catch (err) {
        process.stderr.write(
          `${err instanceof Error ? err.message : err}\n`
        );
        process.exit(1);
      }
      process.stdout.write(`macbeth ${readVersion()}\n`);
      process.stdout.write(`daemon: ${binary}\n\n`);
      const result = spawnSync(binary, ["--check-permissions"], {
        stdio: "inherit",
      });
      process.exit(result.status ?? 1);
    }
    case "version":
    case "--version":
    case "-v": {
      process.stdout.write(`${readVersion()}\n`);
      break;
    }
    case "help":
    case "--help":
    case "-h": {
      printHelp();
      break;
    }
    default: {
      if (command && !command.startsWith("-")) {
        // An unrecognized bare word is almost certainly a typo; surface help
        // rather than silently starting the MCP server.
        process.stderr.write(`Unknown command: ${command}\n\n`);
        printHelp();
        process.exit(1);
      }
      // No command (or leading-dash flags meant for the server): start the MCP
      // server. This is the entry point invoked by `npx macbeth` in MCP configs.
      await import("../dist/mcp.js");
    }
  }
} catch (err) {
  process.stderr.write(`${err instanceof Error ? err.message : err}\n`);
  process.exit(1);
}
