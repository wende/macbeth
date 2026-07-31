import type { AppAccessibility, AppInfo } from "./types.js";

/** How an app can be addressed: a fuzzy name, a PID, or a handle from a previous
 *  connect. The handle form is what makes `connect_app`'s return value useful — pass
 *  it back as the app target and no name re-resolution happens. */
export type AppTarget = string | number;

/** Handle ids are minted by the daemon as `h_<n>`, so they are unambiguous against
 *  real application names. */
const APP_HANDLE_PATTERN = /^h_\d+$/;

export function isAppHandle(target: AppTarget): target is string {
  return typeof target === "string" && APP_HANDLE_PATTERN.test(target);
}

/** Build `connect_app` params for a name, PID, or app handle. */
export function appConnectParams(
  target: AppTarget
): { pid: number } | { appHandle: string } | { name: string } {
  if (typeof target === "number") return { pid: target };
  if (isAppHandle(target)) return { appHandle: target };
  return { name: target };
}

/** Assumed readiness when the field is absent from the wire — an older daemon that
 *  predates accessibility probing. Treating those apps as connectable keeps the old
 *  behaviour (everything listed flat) rather than declaring every app broken. */
const UNPROBED: AppAccessibility = {
  status: "connectable",
  connectable: true,
};

/** Read an app's readiness, tolerating a daemon old enough not to report one.
 *  The field is required in the protocol — the current daemon always sends it — so
 *  this is a wire-compatibility check, not an optional property. */
export function appAccessibility(app: AppInfo): AppAccessibility {
  return "accessibility" in app ? app.accessibility : UNPROBED;
}

function describeApp(app: AppInfo): string {
  const bundle = app.bundleId ? `, bundle: ${app.bundleId}` : "";
  const aliases = app.aliases?.length ? `, aliases: ${app.aliases.join(", ")}` : "";
  return `${app.name} (pid: ${app.pid}, runtime: ${app.runtime}${bundle}${aliases})`;
}

function describeBlockedApp(app: AppInfo): string {
  const info = appAccessibility(app);
  const code = info.axCode != null ? ` [AX ${info.axCode} ${info.axError ?? "unknown"}]` : "";
  const why = info.explanation ? `\n    ${info.explanation}` : "";
  const next = info.nextAction ? `\n    Next: ${info.nextAction}` : "";
  return `${describeApp(app)}${code}${why}${next}`;
}

/**
 * Render `list_apps` so that "running" and "drivable through Accessibility" are
 * visibly different things. Listing an app that `connect_app` will reject — without
 * saying so — is what makes discovery untrustworthy.
 */
export function formatAppList(apps: AppInfo[]): string {
  if (apps.length === 0) return "No running apps found.";

  const connectable = apps.filter((a) => appAccessibility(a).connectable);
  const blocked = apps.filter((a) => !appAccessibility(a).connectable);

  // A permission failure is global, not per-app: reporting each app individually
  // would bury the single fix behind a wall of identical entries.
  const permissionBlocked = blocked.filter(
    (a) => appAccessibility(a).status === "permission_required"
  );
  if (permissionBlocked.length > 0 && permissionBlocked.length === apps.length) {
    const info = appAccessibility(permissionBlocked[0]);
    return [
      `No app is reachable through Accessibility right now (AX ${info.axCode ?? "?"} ${info.axError ?? "api_disabled"}).`,
      info.explanation ?? "",
      info.nextAction ? `Next: ${info.nextAction}` : "",
      "",
      "Running apps:",
      ...apps.map((a) => `  ${describeApp(a)}`),
    ]
      .filter(Boolean)
      .join("\n");
  }

  const sections: string[] = [];
  sections.push(
    connectable.length > 0
      ? `Connectable through Accessibility (${connectable.length}):\n`
          + connectable.map((a) => `  ${describeApp(a)}`).join("\n")
      : "Connectable through Accessibility: none."
  );
  if (blocked.length > 0) {
    sections.push(
      `Running but NOT connectable through Accessibility (${blocked.length}) — `
        + `connect_app will fail for these:\n`
        + blocked.map((a) => `  ${describeBlockedApp(a)}`).join("\n")
    );
  }
  return sections.join("\n\n");
}
