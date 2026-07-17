import { describe, it, expect, vi } from "vitest";
import {
  compareVersions,
  parseVersion,
  fetchLatestRelease,
  resolveInstallSpec,
  runUpdate,
  PACKAGE_NAME,
  type ReleaseInfo,
} from "../update.js";

function mockFetch(body: unknown, ok = true, status = 200): typeof fetch {
  return vi.fn().mockResolvedValue({
    ok,
    status,
    statusText: ok ? "OK" : "Not Found",
    json: async () => body,
  }) as unknown as typeof fetch;
}

describe("parseVersion", () => {
  it("strips a leading v and splits on dots", () => {
    expect(parseVersion("v1.2.3")).toEqual([1, 2, 3]);
    expect(parseVersion("0.2.0")).toEqual([0, 2, 0]);
  });

  it("ignores pre-release and build metadata", () => {
    expect(parseVersion("v1.2.3-beta.1")).toEqual([1, 2, 3]);
    expect(parseVersion("1.2.3+build.5")).toEqual([1, 2, 3]);
  });
});

describe("compareVersions", () => {
  it("orders versions numerically", () => {
    expect(compareVersions("0.2.0", "0.3.0")).toBeLessThan(0);
    expect(compareVersions("0.3.0", "0.2.0")).toBeGreaterThan(0);
    expect(compareVersions("1.0.0", "1.0.0")).toBe(0);
  });

  it("does not compare as strings (10 > 9)", () => {
    expect(compareVersions("0.9.0", "0.10.0")).toBeLessThan(0);
  });

  it("treats missing components as zero", () => {
    expect(compareVersions("1.2", "1.2.0")).toBe(0);
    expect(compareVersions("1.2", "1.2.1")).toBeLessThan(0);
  });
});

describe("fetchLatestRelease", () => {
  it("extracts tag, version and the .tgz asset url", async () => {
    const fetchImpl = mockFetch({
      tag_name: "v0.3.0",
      html_url: "https://github.com/wende/macbeth/releases/tag/v0.3.0",
      assets: [
        { name: "macbeth-v0.3.0-macos-universal.zip", browser_download_url: "https://x/zip" },
        { name: "macbeth-0.3.0.tgz", browser_download_url: "https://x/tgz" },
      ],
    });

    const release = await fetchLatestRelease("wende/macbeth", fetchImpl);
    expect(release.tag).toBe("v0.3.0");
    expect(release.version).toBe("0.3.0");
    expect(release.tarballUrl).toBe("https://x/tgz");
  });

  it("returns null tarball url when no .tgz asset is present", async () => {
    const release = await fetchLatestRelease(
      "wende/macbeth",
      mockFetch({ tag_name: "v0.3.0", assets: [] })
    );
    expect(release.tarballUrl).toBeNull();
  });

  it("throws on a non-ok response", async () => {
    await expect(
      fetchLatestRelease("wende/macbeth", mockFetch({}, false, 404))
    ).rejects.toThrow(/404/);
  });
});

describe("resolveInstallSpec", () => {
  const base: ReleaseInfo = {
    tag: "v0.3.0",
    version: "0.3.0",
    tarballUrl: null,
    htmlUrl: "https://x",
  };

  it("prefers the GitHub tarball when available", () => {
    expect(resolveInstallSpec({ ...base, tarballUrl: "https://x/tgz" })).toBe("https://x/tgz");
  });

  it("falls back to the versioned npm package", () => {
    expect(resolveInstallSpec(base)).toBe(`${PACKAGE_NAME}@0.3.0`);
  });
});

describe("runUpdate", () => {
  it("does not install when already up to date", async () => {
    const install = vi.fn().mockResolvedValue(undefined);
    const code = await runUpdate([], {
      fetchImpl: mockFetch({ tag_name: "v0.2.0", assets: [] }),
      install,
      // readInstalledVersion reads the real package.json (0.2.0 at time of writing).
    });
    expect(install).not.toHaveBeenCalled();
    expect(code).toBe(0);
  });

  it("installs the release tarball when a newer version exists", async () => {
    const install = vi.fn().mockResolvedValue(undefined);
    const code = await runUpdate([], {
      fetchImpl: mockFetch({
        tag_name: "v99.0.0",
        assets: [{ name: "macbeth-99.0.0.tgz", browser_download_url: "https://x/tgz" }],
      }),
      install,
    });
    expect(install).toHaveBeenCalledWith("https://x/tgz");
    expect(code).toBe(0);
  });

  it("does not install in --check mode", async () => {
    const install = vi.fn().mockResolvedValue(undefined);
    const code = await runUpdate([], {
      check: true,
      fetchImpl: mockFetch({ tag_name: "v99.0.0", assets: [] }),
      install,
    });
    expect(install).not.toHaveBeenCalled();
    expect(code).toBe(0);
  });

  it("returns a non-zero code when the GitHub check fails", async () => {
    const code = await runUpdate([], {
      fetchImpl: mockFetch({}, false, 500),
      install: vi.fn(),
    });
    expect(code).toBe(1);
  });
});
