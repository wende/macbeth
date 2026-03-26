import { spawnSync } from "node:child_process";

export function runAppleScript(sourceLines, argv = []) {
  const lines = Array.isArray(sourceLines) ? sourceLines : [sourceLines];
  const args = [];
  for (const line of lines) {
    args.push("-e", line);
  }
  args.push(...argv);

  const result = spawnSync("osascript", args, { encoding: "utf8" });

  if (result.error) throw result.error;
  if (result.status !== 0) {
    const err = (result.stderr ?? result.stdout ?? "AppleScript failed").trim();
    throw new Error(err);
  }

  return (result.stdout ?? "").trim();
}
