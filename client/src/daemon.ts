import { spawn, type ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export class DaemonManager {
  private process: ChildProcess | null = null;
  private _socketPath: string;
  private binaryPath: string;
  private verbose: boolean;

  constructor(options?: {
    socketPath?: string;
    binaryPath?: string;
    verbose?: boolean;
  }) {
    this._socketPath =
      options?.socketPath ??
      path.join(os.tmpdir(), `macbeth-${process.getuid?.() ?? 0}.sock`);

    this.verbose = options?.verbose ?? false;

    this.binaryPath =
      options?.binaryPath ?? this.findDaemonBinary();
  }

  get socketPath(): string {
    return this._socketPath;
  }

  async ensureRunning(): Promise<string> {
    // Check if socket exists and is connectable
    if (await this.isSocketConnectable()) {
      if (this.verbose) {
        process.stderr.write(
          `[macbeth] Reusing existing daemon at ${this._socketPath}\n`
        );
      }
      return this._socketPath;
    }

    // A stale socket file makes a newly spawned daemon look ready before it has
    // bound its own listener. Remove it before spawning and wait for a real
    // connection below.
    try {
      fs.unlinkSync(this._socketPath);
    } catch {
      // Missing socket is expected on a first launch.
    }

    // Spawn daemon
    if (this.verbose) {
      process.stderr.write(
        `[macbeth] Spawning daemon: ${this.binaryPath}\n`
      );
    }

    const args = ["--socket-path", this._socketPath];
    if (this.verbose) args.push("--verbose");

    const spawned = spawn(this.binaryPath, args, {
      // Always capture startup diagnostics. In verbose mode they are also
      // mirrored live; otherwise they are included only when startup fails.
      stdio: ["ignore", "ignore", "pipe"],
      detached: false,
    });
    this.process = spawned;

    let startupStderr = "";
    let startupFailure: string | null = null;
    const appendStartupStderr = (chunk: Buffer | string): void => {
      const text = chunk.toString();
      startupStderr = (startupStderr + text).slice(-16_384);
      if (this.verbose) process.stderr.write(text);
    };
    spawned.stderr?.on("data", appendStartupStderr);

    // Don't keep the parent process alive just because the daemon is running.
    // The daemon stays warm for subsequent scripts.
    spawned.unref();

    spawned.on("error", (err) => {
      startupFailure = `could not launch ${this.binaryPath}: ${err.message}`;
      if (this.verbose) process.stderr.write(`[macbeth] Daemon error: ${err.message}\n`);
    });

    spawned.on("exit", (code, signal) => {
      startupFailure = signal
        ? `exited before creating its socket (signal=${signal})`
        : `exited before creating its socket (code=${code ?? "unknown"})`;
      if (this.verbose) {
        process.stderr.write(`[macbeth] Daemon exited (code=${code}, signal=${signal})\n`);
      }
      if (this.process === spawned) this.process = null;
    });

    // Wait until the socket accepts connections, not merely until its path exists.
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) {
      if (startupFailure) {
        const detail = startupStderr.trim();
        throw new Error(
          `Daemon failed to start: ${startupFailure}${detail ? `\n${detail}` : ""}`
        );
      }
      if (await this.isSocketConnectable()) {
        if (!this.verbose) {
          spawned.stderr?.off("data", appendStartupStderr);
          spawned.stderr?.resume();
        }
        return this._socketPath;
      }
      await new Promise((r) => setTimeout(r, 100));
    }

    const detail = startupStderr.trim();
    throw new Error(
      `Daemon failed to start: socket not created at ${this._socketPath} within 5s`
      + `${detail ? `\n${detail}` : ""}`
    );
  }

  private async isSocketConnectable(): Promise<boolean> {
    if (!fs.existsSync(this._socketPath)) return false;

    try {
      const { createConnection } = await import("node:net");
      return await new Promise<boolean>((resolve) => {
        const sock = createConnection({ path: this._socketPath }, () => {
          sock.destroy();
          resolve(true);
        });
        sock.on("error", () => resolve(false));
        sock.setTimeout(1000, () => {
          sock.destroy();
          resolve(false);
        });
      });
    } catch {
      return false;
    }
  }

  async shutdown(): Promise<void> {
    if (!this.process) return;

    this.process.kill("SIGTERM");

    // Wait up to 3s for graceful exit
    const exited = await Promise.race([
      new Promise<boolean>((resolve) => {
        this.process?.on("exit", () => resolve(true));
      }),
      new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 3000)),
    ]);

    if (!exited && this.process) {
      this.process.kill("SIGKILL");
    }

    this.process = null;

    // Clean up socket file
    try {
      fs.unlinkSync(this._socketPath);
    } catch {
      // Ignore
    }
  }

  private findDaemonBinary(): string {
    // MACBETH_DAEMON_PATH=<path> overrides discovery entirely (mirrors the
    // daemon's own MACBETH_GLOW_HELPER escape hatch).
    const explicit = process.env.MACBETH_DAEMON_PATH;
    if (explicit) {
      if (!fs.existsSync(explicit)) {
        throw new Error(
          `MACBETH_DAEMON_PATH points at a missing binary: ${explicit}`
        );
      }
      return explicit;
    }

    const candidates = [
      // npm package: bundled binary, produced by scripts/build-daemon.sh
      path.resolve(__dirname, "../bin/macbethd"),
      // Development: SwiftPM products from `swift build [-c release]`
      path.resolve(__dirname, "../../daemon/.build/debug/macbethd"),
      path.resolve(__dirname, "../../daemon/.build/release/macbethd"),
    ];

    // These coexist whenever a dev has run both `swift build` and
    // build-daemon.sh, and neither is categorically the "right" one: a fixed
    // order silently runs a stale binary for whichever workflow it deprioritizes.
    // Pick the most recently built instead, so the last build always wins.
    const found = candidates
      .map((file) => {
        try {
          return { file, mtimeMs: fs.statSync(file).mtimeMs };
        } catch {
          return null;
        }
      })
      .filter((c): c is { file: string; mtimeMs: number } => c !== null)
      .sort((a, b) => b.mtimeMs - a.mtimeMs);

    if (found.length === 0) {
      throw new Error(
        `macbethd binary not found. Searched:\n${candidates.map((c) => `  - ${c}`).join("\n")}\n\nBuild it with: cd daemon && swift build`
      );
    }

    if (this.verbose && found.length > 1) {
      process.stderr.write(
        `[macbeth] Multiple macbethd builds found; using newest: ${found[0].file}\n`
      );
    }

    return found[0].file;
  }
}
