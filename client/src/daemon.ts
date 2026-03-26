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

    this.binaryPath =
      options?.binaryPath ?? this.findDaemonBinary();

    this.verbose = options?.verbose ?? false;
  }

  get socketPath(): string {
    return this._socketPath;
  }

  async ensureRunning(): Promise<string> {
    // Check if socket exists and is connectable
    if (fs.existsSync(this._socketPath)) {
      try {
        const { createConnection } = await import("node:net");
        const connected = await new Promise<boolean>((resolve) => {
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

        if (connected) {
          if (this.verbose) {
            process.stderr.write(
              `[macbeth] Reusing existing daemon at ${this._socketPath}\n`
            );
          }
          return this._socketPath;
        }
      } catch {
        // Socket file exists but not connectable, start fresh
      }
    }

    // Spawn daemon
    if (this.verbose) {
      process.stderr.write(
        `[macbeth] Spawning daemon: ${this.binaryPath}\n`
      );
    }

    const args = ["--socket-path", this._socketPath];
    if (this.verbose) args.push("--verbose");

    this.process = spawn(this.binaryPath, args, {
      stdio: ["ignore", "ignore", this.verbose ? "inherit" : "ignore"],
      detached: false,
    });

    // Don't keep the parent process alive just because the daemon is running.
    // The daemon stays warm for subsequent scripts.
    this.process.unref();

    this.process.on("error", (err) => {
      process.stderr.write(`[macbeth] Daemon error: ${err.message}\n`);
    });

    this.process.on("exit", (code) => {
      if (this.verbose) {
        process.stderr.write(`[macbeth] Daemon exited (code=${code})\n`);
      }
      this.process = null;
    });

    // Wait for socket to appear
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) {
      if (fs.existsSync(this._socketPath)) {
        return this._socketPath;
      }
      await new Promise((r) => setTimeout(r, 100));
    }

    throw new Error(
      `Daemon failed to start: socket not created at ${this._socketPath} within 5s`
    );
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
    // Look for the bundled binary relative to this package
    const candidates = [
      // Development: built from source
      path.resolve(__dirname, "../../daemon/.build/debug/macbethd"),
      path.resolve(__dirname, "../../daemon/.build/release/macbethd"),
      // npm package: bundled binary
      path.resolve(__dirname, "../bin/macbethd"),
    ];

    for (const candidate of candidates) {
      if (fs.existsSync(candidate)) {
        return candidate;
      }
    }

    throw new Error(
      `macbethd binary not found. Searched:\n${candidates.map((c) => `  - ${c}`).join("\n")}\n\nBuild it with: cd daemon && swift build`
    );
  }
}
