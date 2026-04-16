import { run } from "./shell.js";

export function runShortcut(name: string, input?: string): string {
  const args = ["run", name];
  if (input !== undefined) {
    args.push("--input", input);
  }
  return run("shortcuts", args).stdout;
}

export function listShortcuts(): string[] {
  const output = run("shortcuts", ["list"]).stdout;
  if (!output) return [];
  return output
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}
