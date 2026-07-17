import { afterEach, describe, expect, it, vi } from "vitest";

const { existsSync, statSync } = vi.hoisted(() => ({
  existsSync: vi.fn(),
  statSync: vi.fn(),
}));

vi.mock("node:fs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs")>();
  return { ...actual, existsSync, statSync, default: { ...actual, existsSync, statSync } };
});

import { DaemonManager } from "../daemon.js";

const BUNDLED = /client\/bin\/macbethd$/;
const DEBUG = /\.build\/debug\/macbethd$/;
const RELEASE = /\.build\/release\/macbethd$/;

/** Make statSync resolve only for candidates matching a pattern → mtime. */
function buildsExist(builds: Array<[RegExp, number]>): void {
  statSync.mockImplementation((file: string) => {
    for (const [pattern, mtimeMs] of builds) {
      if (pattern.test(file)) return { mtimeMs } as ReturnType<typeof statSync>;
    }
    throw Object.assign(new Error("ENOENT"), { code: "ENOENT" });
  });
}

function resolvedBinary(): string {
  return (new DaemonManager({ socketPath: "/tmp/unused.sock" }) as any).binaryPath;
}

describe("DaemonManager binary discovery", () => {
  afterEach(() => {
    existsSync.mockReset();
    statSync.mockReset();
    delete process.env.MACBETH_DAEMON_PATH;
  });

  it("prefers the most recently built binary over a fixed candidate order", () => {
    // The regression this guards: a stale `swift build` debug product shadowing
    // a freshly-run scripts/build-daemon.sh bundle (and vice versa).
    buildsExist([
      [DEBUG, 1_000],
      [BUNDLED, 2_000],
    ]);
    expect(resolvedBinary()).toMatch(BUNDLED);

    buildsExist([
      [DEBUG, 2_000],
      [BUNDLED, 1_000],
    ]);
    expect(resolvedBinary()).toMatch(DEBUG);
  });

  it("picks the newest when all three builds are present", () => {
    buildsExist([
      [BUNDLED, 1_000],
      [DEBUG, 2_000],
      [RELEASE, 3_000],
    ]);
    expect(resolvedBinary()).toMatch(RELEASE);
  });

  it("uses the only build present", () => {
    buildsExist([[BUNDLED, 1_000]]);
    expect(resolvedBinary()).toMatch(BUNDLED);
  });

  it("throws listing every searched path when no build exists", () => {
    buildsExist([]);
    expect(() => resolvedBinary()).toThrow(/macbethd binary not found[\s\S]*\.build\/debug/);
  });

  it("lets MACBETH_DAEMON_PATH override discovery", () => {
    process.env.MACBETH_DAEMON_PATH = "/custom/macbethd";
    existsSync.mockReturnValue(true);
    buildsExist([[BUNDLED, 9_000]]);

    expect(resolvedBinary()).toBe("/custom/macbethd");
    expect(statSync).not.toHaveBeenCalled();
  });

  it("throws when MACBETH_DAEMON_PATH points at a missing binary", () => {
    process.env.MACBETH_DAEMON_PATH = "/custom/macbethd";
    existsSync.mockReturnValue(false);
    // A silent fallback to a discovered build would defeat the point of an
    // explicit override, so this must fail loudly.
    buildsExist([[BUNDLED, 9_000]]);

    expect(() => resolvedBinary()).toThrow(/MACBETH_DAEMON_PATH points at a missing binary/);
  });
});
