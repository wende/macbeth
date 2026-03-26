import { run } from "./shell.mjs";

export function runShortcut(name, input = undefined) {
  const args = ["run", name];
  if (input !== undefined) {
    args.push("--input", input);
  }
  return run("shortcuts", args).stdout;
}

export function listShortcuts() {
  const output = run("shortcuts", ["list"]).stdout;
  if (!output) return [];
  return output.split("\n").map((line) => line.trim()).filter(Boolean);
}
