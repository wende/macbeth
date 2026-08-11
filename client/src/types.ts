export interface QueryStep {
  role?: string;
  title?: string;
  identifier?: string;
  titlePattern?: string;
  index?: number;
}

/** Exactly one way to address an element: a locator query or a handle id. */
export type ElementTarget =
  | { query: QueryStep[]; handleId?: never }
  | { handleId: string; query?: never };

export type AppRuntime = "native" | "electron" | "unknown";

/** Whether a running app can currently be driven through the Accessibility API.
 *  `permission_required` means the API is off for every app because macbeth has not
 *  been granted Accessibility; `not_connectable` means this specific process refuses
 *  accessibility requests (launchers, helper processes, apps that never implement AX). */
export type AXReadiness = "connectable" | "permission_required" | "not_connectable";

export interface AppAccessibility {
  status: AXReadiness;
  connectable: boolean;
  /** Raw AX error code from the probe. Absent when connectable. */
  axCode?: number;
  /** Stable snake_case name for the AX error, e.g. "cannot_complete". */
  axError?: string;
  explanation?: string;
  nextAction?: string;
}

export interface AppInfo {
  name: string;
  pid: number;
  bundleId: string | null;
  aliases: string[];
  runtime: AppRuntime;
  accessibility: AppAccessibility;
}

export type AppMatchKind =
  | "pid"
  | "app_handle"
  | "exact_name"
  | "declared_alias"
  | "bundle_identifier"
  | "partial_name"
  | "partial_alias"
  | "partial_bundle_identifier";

export interface TreeDiagnostics {
  runtime: AppRuntime;
  webContent: "ready" | "empty_web_area" | "no_web_area";
  warning?: string;
}

export interface QueryTreeDetailedResult {
  tree: string;
  diagnostics: TreeDiagnostics;
}

export interface AppWindowInfo {
  /** WindowServer window ID. Not an AX element handle: it is issued by macOS,
   *  is unaffected by handle TTL or `pin_handle`, and stays valid until the
   *  window closes (a reopened window gets a new ID). */
  windowId: number;
  ownerPid: number | null;
  ownerName: string | null;
  bundleId: string | null;
  title: string | null;
  frame: { x: number; y: number; width: number; height: number };
  layer: number;
  onScreen: boolean;
  active: boolean;
  capturable: boolean;
  kind: "window" | "bookkeeping" | "menu_bar" | "overlay";
  /** The window a screenshot captures for this owner when no `windowId` is given. */
  default: boolean;
  /** AX role, or null when the app exposes no AX window for this surface. */
  role: string | null;
  /** AX subrole (e.g. "AXStandardWindow", "AXDialog"), or null when unavailable. */
  subrole: string | null;
  /** Minimized into the Dock; null when AX metadata is unavailable. */
  minimized: boolean | null;
}

export interface ListWindowsOptions {
  /** Include menu-bar strips, overlays, and bookkeeping surfaces
   *  (`kind !== "window"`). Default false. */
  includeAllSurfaces?: boolean;
  /** Case-insensitive regex matched against any of title/ownerName/bundleId.
   *  Filtering runs before the per-owner AX join so filtered-out apps skip it. */
  titlePattern?: string;
}

export interface ListMenuBarOptions {
  /** Case-insensitive regex. Matched against each menu item's AX title;
   *  non-matching branches are pruned but ancestors of matches stay. */
  titlePattern?: string;
}

export interface ConnectOptions {
  socketPath?: string;
  daemonPath?: string;
  timeout?: number;
  verbose?: boolean;
}

/** Per-connection options. */
export interface AppConnectOptions {
  /** For Electron apps, how long (ms) to wait for Chromium to build its
   *  accessibility tree after enabling it. Default 3000. */
  readyTimeoutMs?: number;
}

/** Strategy for `click`: "auto" tries AXPress (element + neighbours) then a synthetic
 *  mouse click; "ax" only presses; "mouse" only clicks by coordinates. */
export type ClickStrategy = "auto" | "ax" | "mouse";

export interface ClickOptions {
  timeout?: number;
  strategy?: ClickStrategy;
  /**
   * Mouse fallback only. Wait until the user has been idle for this many
   * milliseconds before briefly activating the target window. Capped at 5s.
   */
  waitForIdleMs?: number;
}

/** Strategy for `fill`: "auto" does a verified AX write then keyboard synthesis
 *  (always keyboard on Electron); "ax" only writes the AX value; "keyboard" only types. */
export type FillStrategy = "auto" | "ax" | "keyboard";

export interface TreeOptions {
  maxDepth?: number;
  /** Cap breadth of the walked tree. When the budget runs out, the parent
   *  node is emitted with a `truncatedChildren` marker carrying the handleId
   *  to re-query for a deeper walk. Must be >= 1 when set. */
  maxNodes?: number;
  /** Optional walk root (element handle from a prior query_tree). When set,
   *  the tree starts at this element instead of the app — used to drill into
   *  a subtree named by a truncation marker. */
  handleId?: string;
  format?: "text" | "json";
  includeInvisible?: boolean;
}

export interface ElementInfo {
  handleId: string;
  role: string;
  title?: string;
  value?: string;
  identifier?: string;
  enabled: boolean;
  focused: boolean;
}

export interface ScreenshotResult {
  data: string;
  width: number;
  height: number;
  format: "png";
}

export type KeyStroke =
  | {
      key: string;
      modifiers?: string[];
      delayMs?: number;
    }
  | {
      text: string;
      delayMs?: number;
    };

/**
 * How far a keyboard call got.
 *
 * - `attempted` — the events could not be shown to have entered the event stream.
 * - `dispatched` — they entered the system event stream; app delivery is unproven.
 * - `verified` — the app's observable state changed. Not produced yet.
 */
export type KeyDispatchOutcome = "attempted" | "dispatched" | "verified";

export interface KeyFocusedElementInfo {
  role: string | null;
  subrole: string | null;
  title: string | null;
  identifier: string | null;
  value: string | null;
}

export interface KeyTargetInfo {
  app: string | null;
  pid: number | null;
  bundleId: string | null;
  /** Whether the target app held keyboard focus when the events were posted. */
  frontmost: boolean;
  /** Who actually held keyboard focus — the app that received the events. */
  focusedApp: { pid: number | null; name: string | null };
  window: { title: string | null; identity: string | null };
  focusedElement: KeyFocusedElementInfo | null;
}

export interface PressKeyResult {
  /** False only when no key event could be created at all. */
  success: boolean;
  outcome: KeyDispatchOutcome;
  dispatched: boolean;
  verified: boolean;
  /** Human-readable explanation of the outcome and its caveats. */
  note: string;
  /** Machine-readable warning codes, e.g. `target-not-frontmost`. */
  warnings: string[];
  keysRequested: number;
  keysPosted: number;
  evidence: {
    /** Session key-down counter delta across the dispatch. */
    sessionKeyDownDelta: number | null;
    accessibilityTrusted: boolean;
  };
  target: KeyTargetInfo;
}

export interface PressKeysResult extends PressKeyResult {
  /** Number of key/text items in the sequence. */
  count: number;
}

export interface FormField {
  handleId: string;
  role: string;
  kind: "text" | "number" | "boolean" | "choice" | "unknown";
  label?: string;
  title?: string;
  value?: string;
  identifier?: string;
  min?: number;
  max?: number;
  editable: boolean;
  enabled: boolean;
}

export interface AXNodeJSON {
  handleId: string;
  role: string;
  title?: string;
  value?: string;
  identifier?: string;
  label?: string;
  enabled: boolean;
  focused: boolean;
  children?: AXNodeJSON[];
}
