#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PACKAGE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const TROUBLESHOOTING_URL =
  "https://github.com/wende/macbeth/blob/main/TROUBLESHOOTING.md";

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

function macOSVersion() {
  try {
    const r = spawnSync("sw_vers", ["-productVersion"], { encoding: "utf8" });
    if (r.status === 0 && r.stdout) return r.stdout.trim();
  } catch {
    // sw_vers is macOS-only; absence is itself a useful signal below.
  }
  return "unknown (sw_vers not available — is this macOS?)";
}

// Builds a self-contained, copy-paste block a user can hand to their coding
// agent (Claude Code, Cursor, …) so it can diagnose and fix a broken install.
// It bundles the exact error text, the environment, and a pointer to the
// troubleshooting guide, framed by rules that make it easy to select.
function printAgentFixBlock({ summary, problems = [], details }) {
  const rule = "─".repeat(72);
  const localGuide = resolve(PACKAGE_ROOT, "..", "TROUBLESHOOTING.md");
  const guide = existsSync(localGuide)
    ? `${TROUBLESHOOTING_URL}\n  (local copy: ${localGuide})`
    : TROUBLESHOOTING_URL;

  const lines = [];
  lines.push("");
  lines.push(`✖ ${summary}`);
  lines.push("");
  lines.push("Copy everything between the lines below and paste it to your");
  lines.push("coding agent (Claude Code, Cursor, …) to fix it:");
  lines.push(rule);
  lines.push(
    "The Macbeth MCP server (open-source Computer Use for macOS) isn't working."
  );
  lines.push(
    "Diagnose and fix it, then verify with `npx macbeth doctor`. Tell me"
  );
  lines.push(
    "exactly which permissions to grant or commands to run, and apply any"
  );
  lines.push("fixes you can.");
  lines.push("");
  lines.push("Environment:");
  lines.push(`  macbeth : ${readVersion()}`);
  lines.push(`  macOS   : ${macOSVersion()}`);
  lines.push(`  node    : ${process.version}`);
  lines.push("");
  lines.push("What went wrong:");
  if (problems.length > 0) {
    for (const p of problems) lines.push(`  - ${p}`);
  }
  if (details && details.trim()) {
    lines.push("");
    for (const l of details.replace(/\s+$/, "").split("\n")) {
      lines.push(`  ${l}`);
    }
  }
  lines.push("");
  lines.push("Troubleshooting guide:");
  lines.push(`  ${guide}`);
  lines.push(rule);
  lines.push("");
  process.stderr.write(lines.join("\n"));
}

function runDoctor(DaemonManager) {
  process.stdout.write(`macbeth ${readVersion()}\n`);

  let binary;
  try {
    binary = new DaemonManager().daemonBinaryPath;
  } catch (err) {
    const details = err instanceof Error ? err.message : String(err);
    printAgentFixBlock({
      summary: "macbeth doctor could not locate the daemon binary.",
      problems: [
        "The bundled `macbethd` daemon was not found — the install is " +
          "incomplete, or this is an unbuilt source checkout.",
      ],
      details,
    });
    return 1;
  }

  process.stdout.write(`daemon: ${binary}\n\n`);

  const result = spawnSync(binary, ["--check-permissions"], {
    encoding: "utf8",
  });

  // Surface the daemon's own preflight output to the human first.
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);

  if (result.error) {
    printAgentFixBlock({
      summary: "macbeth doctor could not run the daemon.",
      problems: [
        `The daemon at ${binary} failed to launch.`,
      ],
      details: result.error.message,
    });
    return 1;
  }

  const out = result.stdout ?? "";
  const axDenied = /accessibility:\s*DENIED/i.test(out) || result.status !== 0;
  const screenDenied = /screen_capture:\s*DENIED/i.test(out);

  const problems = [];
  if (axDenied) {
    problems.push(
      "Accessibility permission is DENIED — required for all UI " +
        "automation (query_tree, click, fill, read_form)."
    );
  }
  if (screenDenied) {
    problems.push(
      "Screen Recording permission is DENIED — required only for the " +
        "screenshot and image OCR tools."
    );
  }

  // Accessibility is the gating permission (mirrors the daemon's own exit
  // code): a denied screen-capture alone is a note, not a failure.
  if (axDenied) {
    printAgentFixBlock({
      summary: "macbeth doctor found a blocking problem.",
      problems,
      details: out,
    });
    return 1;
  }

  if (screenDenied) {
    process.stdout.write(
      "\nNote: Screen Recording is denied — screenshots and image OCR will " +
        "fail until it is granted.\nEverything else is ready.\n"
    );
  } else {
    process.stdout.write("\n✓ macbeth is ready — all permissions granted.\n");
  }
  return 0;
}

function isModuleNotFound(err) {
  return Boolean(
    err &&
      typeof err === "object" &&
      "code" in err &&
      err.code === "ERR_MODULE_NOT_FOUND"
  );
}

function printHelp() {
  process.stdout.write(
    `macbeth — open-source Computer Use for macOS\n` +
      `See and operate Mac applications through MCP or TypeScript, including native and Electron interfaces.\n\n` +
      `Usage:\n` +
      `  macbeth               Start the MCP server (default; used by LLM agents)\n` +
      `  macbeth doctor        Check macOS Accessibility + Screen Recording permissions\n` +
      `  macbeth update        Update to the latest GitHub release\n` +
      `  macbeth update --check  Report whether an update is available, without installing\n` +
      `  macbeth version       Print the installed version\n` +
      `  macbeth help          Show this help, including every MCP tool as a CLI command\n` +
      `  macbeth <tool>        Run an MCP tool (same names and arguments as the MCP server)\n` +
      `  macbeth <tool> --json '{...}'\n` +
      `                       Pass arguments as JSON — the CLI equivalent of an MCP tool call\n`
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
      const { DaemonManager } = await import("../dist/daemon.js");
      process.exit(runDoctor(DaemonManager));
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
      try {
        const { formatGlobalHelp } = await import("../dist/cli.js");
        process.stdout.write(formatGlobalHelp());
      } catch {
        printHelp();
      }
      break;
    }
    default: {
      const MCP_START_ALIASES = new Set(["mcp", "serve", "server", "start"]);
      if (command && MCP_START_ALIASES.has(command)) {
        // These read as "start the server" verbs, but the MCP server has no
        // subcommand — it's what `macbeth` does with no arguments at all.
        // Name the fix instead of just refusing.
        process.stderr.write(
          `Unknown command: ${command} — the MCP server is the default; ` +
            `run \`macbeth\` with no arguments.\n`
        );
        process.exit(1);
      }
      if (command && !command.startsWith("-")) {
        try {
          const { isToolCommand, runCli, formatGlobalHelp } = await import("../dist/cli.js");
          if (isToolCommand(command)) {
            process.exit(await runCli(process.argv.slice(2)));
          }
          process.stderr.write(`Unknown command: ${command}\n\n`);
          process.stdout.write(formatGlobalHelp());
          process.exit(1);
        } catch (err) {
          if (isModuleNotFound(err)) {
            process.stderr.write(`Unknown command: ${command}\n\n`);
            printHelp();
            process.exit(1);
          }
          throw err;
        }
      }
      // No command (or leading-dash flags meant for the server): start the MCP
      // server. This is the entry point invoked by `npx macbeth` in MCP configs.
      await import("../dist/mcp.js");
    }
  }
} catch (err) {
  const details = err instanceof Error ? (err.stack ?? err.message) : String(err);
  const invocation = `macbeth ${command ?? ""}`.trim();
  // Any unexpected failure — a broken start-up, a failed update — still gets
  // the same paste-to-your-agent treatment so the user is never left with a
  // bare stack trace and no next step.
  printAgentFixBlock({
    summary: `\`${invocation}\` failed unexpectedly.`,
    problems: [err instanceof Error ? err.message : String(err)],
    details,
  });
  process.exit(1);
}
