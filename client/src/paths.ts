import os from "node:os";
import path from "node:path";

/**
 * Per-user Caches root for macbeth on macOS. The daemon does not have a bundle
 * identifier (it is an unbundled Swift executable), so we use the literal
 * `macbeth/` subdirectory instead of `<bundle-id>/`.
 *
 * Lives under `~/Library/Caches/` so macOS treats the contents as regenerable
 * (may be purged under disk pressure; not included in Time Machine backups by
 * default). See `docs/architecture.md` for the rationale.
 */
export function cachesRoot(): string {
  return path.join(os.homedir(), "Library", "Caches", "macbeth");
}

/** Directory where the daemon writes its audit log. */
export function defaultLogDir(): string {
  return path.join(cachesRoot(), "logs");
}