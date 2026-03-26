import { spawnSync } from "node:child_process";

export function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    ...options,
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    const stderr = (result.stderr ?? "").trim();
    const stdout = (result.stdout ?? "").trim();
    const detail = stderr || stdout || `${command} exited with code ${result.status}`;
    throw new Error(detail);
  }

  return {
    stdout: (result.stdout ?? "").trim(),
    stderr: (result.stderr ?? "").trim(),
  };
}

export function runJson(command, args, options = {}) {
  const { stdout } = run(command, args, options);
  if (!stdout) return null;
  return JSON.parse(stdout);
}
