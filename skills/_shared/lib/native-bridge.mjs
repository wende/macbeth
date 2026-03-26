import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const bridge = join(here, "..", "native", "apple_data.swift");

export function runNativeBridge(args) {
  const result = spawnSync("swift", [bridge, ...args], { encoding: "utf8" });
  if (result.error) throw result.error;

  const stdout = (result.stdout ?? "").trim();
  const stderr = (result.stderr ?? "").trim();
  const parsed = tryParseJson(stdout);

  if (result.status === 0) {
    if (parsed !== null) return parsed;
    return { ok: true, output: stdout, stderr: stderr || undefined };
  }

  if (parsed !== null) return parsed;
  throw new Error(stderr || stdout || `Native bridge failed with status ${result.status}`);
}

function tryParseJson(text) {
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
