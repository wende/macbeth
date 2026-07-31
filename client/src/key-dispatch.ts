import type { PressKeyResult, KeyStroke } from "./types.js";

/** Human label for a single key press, e.g. `cmd+shift+a`. */
export function describeKeyPress(key: string, modifiers?: string[]): string {
  return modifiers?.length ? `${modifiers.join("+")}+${key}` : key;
}

/** Human label for a key sequence, e.g. `cmd+l, "example.com", return`. */
export function describeKeyStrokes(keys: KeyStroke[]): string {
  return keys
    .map((stroke) =>
      "key" in stroke
        ? describeKeyPress(stroke.key, stroke.modifiers)
        : JSON.stringify(stroke.text)
    )
    .join(", ");
}

export interface KeyDispatchReport {
  text: string;
  /** Only true when nothing was sent at all — never for merely unverified delivery. */
  isError: boolean;
}

/**
 * Detect a result from a daemon that predates outcome reporting.
 *
 * A newer client talking to an older `macbethd` still gets `{success: true}`; that
 * case keeps the old wording rather than inventing evidence it never received.
 */
function hasOutcome(result: unknown): result is PressKeyResult {
  if (typeof result !== "object" || result === null) return false;
  const payload = result as Partial<PressKeyResult>;
  // Require the whole shape, not just `outcome`: another RPC could grow an
  // `outcome` field of its own without ever being a keyboard dispatch report.
  return (
    typeof payload.outcome === "string" &&
    typeof payload.success === "boolean" &&
    typeof payload.target === "object" &&
    payload.target !== null
  );
}

function describeTarget(result: PressKeyResult): string {
  const { target } = result;
  if (!target || (target.app === null && target.pid === null)) return "an unknown target";

  const parts: string[] = [target.app ?? `pid ${target.pid}`];
  if (target.app && target.pid !== null) parts[0] = `${target.app} (pid ${target.pid})`;
  if (target.window?.title) parts.push(`window "${target.window.title}"`);

  const focused = target.focusedElement;
  if (focused?.role) {
    const name = focused.title ?? focused.identifier;
    parts.push(name ? `focus ${focused.role} "${name}"` : `focus ${focused.role}`);
  } else {
    parts.push("no focused element");
  }

  if (!target.frontmost) {
    const holder = target.focusedApp?.name
      ? `${target.focusedApp.name}${target.focusedApp.pid !== null ? ` (pid ${target.focusedApp.pid})` : ""}`
      : "another app";
    parts.push(`NOT frontmost — keyboard focus was on ${holder}`);
  }

  return parts.join(", ");
}

/**
 * Render a keyboard dispatch result for an agent.
 *
 * The wording never claims the target app acted on the input, because nothing in
 * the AX or CoreGraphics APIs reports that. It states which tier was reached and,
 * when the tier is below `dispatched`, says so without framing it as a hard
 * failure — an agent that reads "failed" tends to resend, and resent keystrokes
 * are worse than an honest "unconfirmed".
 */
export function formatKeyDispatch(
  label: string,
  result: unknown,
  legacyText: string
): KeyDispatchReport {
  if (!hasOutcome(result)) {
    return { text: legacyText, isError: false };
  }

  const lines = [`Sent ${label} to ${describeTarget(result)}.`];
  if (result.note) lines.push(result.note);

  const warnings = result.warnings?.length ? result.warnings.join(", ") : "none";
  const evidence = result.evidence ?? { sessionKeyDownDelta: null, accessibilityTrusted: true };
  lines.push(
    `outcome=${result.outcome} verified=${result.verified === true} ` +
      `keysPosted=${result.keysPosted}/${result.keysRequested} ` +
      `sessionKeyDownDelta=${evidence.sessionKeyDownDelta ?? "unknown"} warnings=[${warnings}]`
  );

  return { text: lines.join("\n"), isError: result.success === false };
}
