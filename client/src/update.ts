import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const MODULE_DIR = dirname(fileURLToPath(import.meta.url));
// dist/update.js lives one level below the package root (dist/ → package root).
const PACKAGE_ROOT = resolve(MODULE_DIR, "..");

/** GitHub repository that publishes signed macbeth releases. */
export const DEFAULT_REPO = "wende/macbeth";
/** npm package name, used as the install fallback when no tarball asset exists. */
export const PACKAGE_NAME = "macbeth";

export interface ReleaseAsset {
  name: string;
  browser_download_url: string;
}

export interface ReleaseInfo {
  /** Raw git tag, e.g. "v0.3.0". */
  tag: string;
  /** Version with any leading "v" stripped, e.g. "0.3.0". */
  version: string;
  /** Download URL of the packed npm tarball attached to the release, if any. */
  tarballUrl: string | null;
  /** Human-facing release page. */
  htmlUrl: string;
}

/**
 * Parse a version string into comparable numeric components. Any leading "v"
 * and any pre-release/build suffix (`-beta.1`, `+meta`) are ignored — release
 * tags in this repo are plain `vMAJOR.MINOR.PATCH`.
 */
export function parseVersion(input: string): number[] {
  const core = input.trim().replace(/^v/i, "").split(/[-+]/, 1)[0];
  return core.split(".").map((part) => {
    const n = Number.parseInt(part, 10);
    return Number.isFinite(n) ? n : 0;
  });
}

/**
 * Compare two versions. Returns a negative number if `a < b`, zero if equal,
 * and a positive number if `a > b`. Missing components are treated as 0
 * (`1.2` == `1.2.0`).
 */
export function compareVersions(a: string, b: string): number {
  const pa = parseVersion(a);
  const pb = parseVersion(b);
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (diff !== 0) return diff < 0 ? -1 : 1;
  }
  return 0;
}

/** Read the installed package version from the bundled package.json. */
export function readInstalledVersion(packageRoot = PACKAGE_ROOT): string {
  const pkgPath = resolve(packageRoot, "package.json");
  const pkg = JSON.parse(readFileSync(pkgPath, "utf8")) as { version?: string };
  if (!pkg.version) {
    throw new Error(`No version field in ${pkgPath}`);
  }
  return pkg.version;
}

/** Shape of the pieces of the GitHub "latest release" response we consume. */
interface GithubReleaseResponse {
  tag_name?: string;
  html_url?: string;
  assets?: ReleaseAsset[];
}

/**
 * Fetch the most recent published (non-draft, non-prerelease) release for the
 * repository from the GitHub REST API.
 */
export async function fetchLatestRelease(
  repo = DEFAULT_REPO,
  fetchImpl: typeof fetch = fetch
): Promise<ReleaseInfo> {
  const url = `https://api.github.com/repos/${repo}/releases/latest`;
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "User-Agent": `${PACKAGE_NAME}-cli`,
    "X-GitHub-Api-Version": "2022-11-28",
  };
  // An optional token lifts the low unauthenticated rate limit and lets the
  // update work against private forks.
  const token = process.env.GITHUB_TOKEN ?? process.env.GH_TOKEN;
  if (token) headers.Authorization = `Bearer ${token}`;

  const res = await fetchImpl(url, { headers });
  if (!res.ok) {
    throw new Error(
      `GitHub API request failed: ${res.status} ${res.statusText} (${url})`
    );
  }

  const data = (await res.json()) as GithubReleaseResponse;
  const tag = data.tag_name;
  if (!tag) {
    throw new Error(`No tag_name in latest release for ${repo}`);
  }

  const assets = data.assets ?? [];
  const tarball = assets.find((a) => a.name.endsWith(".tgz"));

  return {
    tag,
    version: tag.replace(/^v/i, ""),
    tarballUrl: tarball?.browser_download_url ?? null,
    htmlUrl: data.html_url ?? `https://github.com/${repo}/releases/tag/${tag}`,
  };
}

/**
 * Pick what to hand to `npm install -g`. Prefer the exact tarball published on
 * the GitHub release (signed + notarized binaries); fall back to the npm
 * registry pinned to the release version so the two sources stay in lockstep.
 */
export function resolveInstallSpec(release: ReleaseInfo): string {
  return release.tarballUrl ?? `${PACKAGE_NAME}@${release.version}`;
}

function log(message: string): void {
  process.stdout.write(`${message}\n`);
}

/** Run `npm install -g <spec>`, streaming npm's output through to the user. */
function npmInstallGlobal(spec: string): Promise<void> {
  return new Promise((resolvePromise, reject) => {
    const npm = process.platform === "win32" ? "npm.cmd" : "npm";
    const child = spawn(npm, ["install", "-g", spec], {
      stdio: "inherit",
    });
    child.on("error", (err) => {
      reject(
        new Error(
          `Failed to run npm (${err.message}). Install manually with: npm install -g ${spec}`
        )
      );
    });
    child.on("exit", (code) => {
      if (code === 0) resolvePromise();
      else reject(new Error(`npm install -g ${spec} exited with code ${code ?? "unknown"}`));
    });
  });
}

export interface UpdateOptions {
  repo?: string;
  /** Report availability without installing. */
  check?: boolean;
  /** Reinstall even when already on the latest version. */
  force?: boolean;
  fetchImpl?: typeof fetch;
  install?: (spec: string) => Promise<void>;
}

/**
 * Check GitHub for the newest release and, unless it is already installed,
 * self-update via a global npm install of the release tarball.
 *
 * Returns the process exit code.
 */
export async function runUpdate(argv: string[] = [], options: UpdateOptions = {}): Promise<number> {
  const repo = options.repo ?? process.env.MACBETH_UPDATE_REPO ?? DEFAULT_REPO;
  const check = options.check ?? argv.includes("--check");
  const force = options.force ?? argv.includes("--force");
  const install = options.install ?? npmInstallGlobal;

  const current = readInstalledVersion();
  log(`Current version: v${current}`);
  log(`Checking ${repo} for the latest release...`);

  let release: ReleaseInfo;
  try {
    release = await fetchLatestRelease(repo, options.fetchImpl ?? fetch);
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    process.stderr.write(`Could not check for updates: ${detail}\n`);
    return 1;
  }

  log(`Latest release:  ${release.tag}`);

  const cmp = compareVersions(current, release.version);
  if (cmp >= 0 && !force) {
    log(
      cmp === 0
        ? "You are already on the latest version."
        : `Your version (v${current}) is newer than the latest release. Nothing to do.`
    );
    return 0;
  }

  if (check) {
    log(`An update is available: v${current} -> ${release.tag}`);
    log(`Release notes: ${release.htmlUrl}`);
    log(`Run "macbeth update" to install it.`);
    return 0;
  }

  const spec = resolveInstallSpec(release);
  log(`Updating to ${release.tag} via: npm install -g ${spec}`);
  try {
    await install(spec);
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    process.stderr.write(`Update failed: ${detail}\n`);
    return 1;
  }

  log(`Updated to ${release.tag}.`);
  return 0;
}
