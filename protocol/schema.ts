// macbeth JSON-RPC 2.0 protocol definitions
// TypeScript is the canonical source; Swift implements manually.

// --- Element handles ---

/**
 * An opaque element handle (`h_0`, `h_1`, …) issued by the daemon.
 *
 * Handles are canonical: the same AX element gets the same handle every time the daemon
 * sees it, so repeating `query_tree` over an unchanged tree returns the ids you already
 * hold, and previously returned handles stay usable across unrelated queries. Ids are
 * never reused — a retired handle fails rather than resolving to a different element.
 *
 * A handle stops working when (see `docs/handle-lifecycle.md`):
 *  - it goes unused past the daemon's idle TTL (5 min, or 60 min when pinned) —
 *    `stale_handle` (-32010) with `data.reason === "expired"`
 *  - the app destroys or recycles the element — `stale_handle` with `"destroyed"` /
 *    `"recycled"`
 *  - the owning app quits — `stale_handle` with `"app_terminated"`
 *  - the daemon restarts, which clears every handle — `unknown_handle` (-32011)
 *
 * Pins are finite: a pinned handle's TTL extends to 60 min, refreshed on every use,
 * but pins age out on their own. `pin_handle` (bulk: `handleIds[]`) and the `pin: true`
 * flag on the minting methods (`query_tree`, `get_element`, `read_form`) are the only
 * ways to pin — there is no unpin.
 *
 * Stale means "re-resolve from the query that produced it"; unknown means the id was
 * never issued and retrying it can't help.
 */
export type ElementHandle = string;

// --- Query types ---

export interface QueryStep {
  role?: string;
  title?: string;
  identifier?: string;
  titlePattern?: string;
  index?: number;
}

// --- RPC method params and results ---

// list_apps
export interface ListAppsResult {
  apps: AppInfo[];
}

// list_methods
export interface ListMethodsResult {
  methods: string[];
}

// begin_activity / end_activity
export interface BeginActivityResult {
  token: string;
}

export interface EndActivityParams {
  token: string;
}

export interface EndActivityResult {
  ended: boolean;
}

// run_applescript
export interface RunAppleScriptParams {
  /**
   * Script source. The parameter is `source` — not `script`, `code`, or `body`.
   *
   * AppleScript: `tell application "Finder" to get name of every window`
   * JavaScript (JXA): `Application("Finder").windows().map(w => w.name())`
   */
  source: string;
  /**
   * Exactly `"AppleScript"` or `"JavaScript"` — JXA is `"JavaScript"`. The
   * daemon also accepts the lowercase spellings and `"jxa"`, but the MCP tool
   * enum exposes only the two canonical values.
   */
  language?: "AppleScript" | "JavaScript";
  /** Defaults to true because arbitrary scripts may control applications. */
  interactive?: boolean;
  /**
   * Hard daemon-side execution timeout in milliseconds. Clamped to 100–300000
   * (default 30000). Exceeding it stops the script and fails this call with a
   * typed `timeout` error (-32001); the daemon connection and every other
   * in-flight or subsequent call are unaffected.
   */
  timeoutMs?: number;
}

export interface RunAppleScriptResult {
  output: string;
}

export interface ListMenuBarParams {
  appHandle: string;
}

export interface ListMenuBarResult {
  menu: string;
}

export interface SelectMenuItemParams {
  appHandle: string;
  menuPath: string[];
}

export interface SelectMenuItemResult {
  selected: string;
}

export type AppRuntime = "native" | "electron" | "unknown";

/** Whether a running app can currently be driven through the Accessibility API.
 *  `permission_required` means the API is off for every app because macbeth has
 *  not been granted Accessibility; `not_connectable` means this specific process
 *  refuses accessibility requests. */
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

// connect_app
export interface ConnectAppParams {
  name?: string;
  pid?: number;
  /** Handle returned by an earlier connect_app. Reconnecting by handle skips name
   *  resolution and keeps addressing the same process. */
  appHandle?: string;
  /** For Electron apps, how long (ms) to wait for Chromium to build its
   *  accessibility tree after enabling it. Default 3000. */
  readyTimeoutMs?: number;
}

export interface ConnectAppResult {
  appHandle: string;
  name: string;
  pid: number;
  bundleId: string | null;
  aliases: string[];
  runtime: AppRuntime;
  requestedName: string | null;
  matchKind: "pid" | "app_handle" | "exact_name" | "declared_alias" | "bundle_identifier" | "partial_name" | "partial_alias" | "partial_bundle_identifier";
  matchedValue: string;
  manualAccessibility: string;
  webContentReadiness: "ready" | "empty_web_area" | "no_web_area" | null;
}

// list_windows
export interface ListWindowsParams {
  /** Scope the listing to one connected app and its helper processes.
   *  Omit to list windows for every app that owns one. */
  appHandle?: string;
  /** Include menu-bar strips, overlays, and bookkeeping sentinels
   *  (`kind !== "window"`). Default false. */
  includeAllSurfaces?: boolean;
}

export type WindowKind = "window" | "bookkeeping" | "menu_bar" | "overlay";

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
  kind: WindowKind;
  /** The window `screenshot`/`extract_text` capture for this owner when no
   *  `windowId` is given. */
  default: boolean;
  /** AX role (e.g. "AXWindow"), null when the app exposes no AX window for
   *  this surface or accessibility permission is missing. */
  role: string | null;
  /** AX subrole (e.g. "AXStandardWindow", "AXDialog"), null when unavailable. */
  subrole: string | null;
  /** Minimized into the Dock. Null (not false) when AX metadata is unavailable —
   *  WindowServer still reports a frame for minimized windows. */
  minimized: boolean | null;
}

export interface ListWindowsResult {
  windows: AppWindowInfo[];
}

// query_tree
export interface QueryTreeParams {
  appHandle: string;
  maxDepth?: number;
  format?: "text" | "json";
  includeInvisible?: boolean;
  /** Pin every handle minted during the walk (60 min idle TTL, refreshed on use).
   *  Use when you intend to operate on returned handles later rather than immediately. */
  pin?: boolean;
}

export interface QueryTreeResult {
  tree: string | AXNodeJSON;
  diagnostics: TreeDiagnostics;
}

export interface TreeDiagnostics {
  runtime: AppRuntime;
  webContent: "ready" | "empty_web_area" | "no_web_area";
  warning?: string;
}

export interface AXNodeJSON {
  handleId: ElementHandle;
  role: string;
  title?: string;
  value?: string;
  identifier?: string;
  label?: string;
  enabled: boolean;
  focused: boolean;
  children: AXNodeJSON[];
}

// get_element
export interface GetElementParams {
  appHandle: string;
  query: QueryStep[];
  /** Pin the returned handle (60 min idle TTL, refreshed on use). */
  pin?: boolean;
}

export interface GetElementResult {
  handleId: ElementHandle;
  role: string;
  title?: string;
  value?: string;
  identifier?: string;
  enabled: boolean;
  focused: boolean;
}

// click
/** Click strategy: "auto" (AXPress, then neighbours, then synthetic mouse),
 *  "ax" (AXPress only), "mouse" (synthetic mouse click only). */
export type ClickStrategy = "auto" | "ax" | "mouse";

export interface ClickParams {
  appHandle: string;
  handleId?: string;
  query?: QueryStep[];
  timeout?: number;
  strategy?: ClickStrategy;
  /**
   * Mouse fallback only. Wait until the user is idle for this many milliseconds
   * before briefly activating the target window. Capped at 5s.
   */
  waitForIdleMs?: number;
}

// fill
/** Fill strategy: "auto" (verified AX write, keyboard fallback — always keyboard on
 *  Electron), "ax" (AX write only), "keyboard" (keyboard synthesis only). */
export type FillStrategy = "auto" | "ax" | "keyboard";

export interface FillParams {
  appHandle: string;
  handleId?: string;
  query?: QueryStep[];
  value: string;
  timeout?: number;
  strategy?: FillStrategy;
}

// wait_for
export interface WaitForCondition {
  kind: "exists" | "value_equals" | "value_changes" | "enabled";
  value?: string;
}

export interface WaitForParams {
  appHandle: string;
  query?: QueryStep[];
  handleId?: string;
  timeout?: number;
  pollMs?: number;
  condition?: WaitForCondition;
}

export interface WaitForResult {
  handleId?: string;
  role?: string;
  title?: string;
  matched?: boolean;
  value?: string;
  oldValue?: string;
  newValue?: string;
  enabled?: boolean;
}

// press_key
export interface PressKeyParams {
  appHandle: string;
  key: string;
  modifiers?: string[];
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

export interface PressKeysParams {
  appHandle: string;
  keys: KeyStroke[];
}

/**
 * How far a keyboard call got. Tiers are cumulative:
 *
 * - `attempted` — the events could not be shown to have entered the event stream
 *   (creation failed, or the session key-down counter never advanced).
 * - `dispatched` — they entered the system event stream. Whether the target app
 *   consumed them is unknown: nothing in the AX or CoreGraphics APIs reports it.
 * - `verified` — the app's observable state changed as a result. Reserved; the
 *   daemon does not produce this yet.
 */
export type KeyDispatchOutcome = "attempted" | "dispatched" | "verified";

export interface KeyFocusedElementInfo {
  role: string | null;
  subrole: string | null;
  title: string | null;
  identifier: string | null;
  /** Truncated to 120 characters. */
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
  /** Null when the app exposes no focused element; many apps still handle keys. */
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
    /**
     * Session key-down counter delta across the dispatch. Other processes and a
     * human at the keyboard also advance it, so it confirms dispatch (`>=` the
     * posted count) and never refutes it.
     */
    sessionKeyDownDelta: number | null;
    accessibilityTrusted: boolean;
  };
  target: KeyTargetInfo;
}

export interface PressKeysResult extends PressKeyResult {
  /** Number of key/text items in the sequence. */
  count: number;
}

// screenshot
export interface ScreenshotParams {
  appHandle: string;
  /** WindowServer ID from list_windows. Omitting uses the default visible window. */
  windowId?: number;
  region?: { x: number; y: number; width: number; height: number };
}

export interface ScreenshotResult {
  data: string; // base64 PNG
  width: number;
  height: number;
  format: "png";
}

// read_form
export interface ReadFormParams {
  appHandle: string;
  handleId?: string;
  query?: QueryStep[];
  maxDepth?: number;
  /** Pin every returned field handle (60 min idle TTL, refreshed on use). This is the
   *  cheap path for "I'm about to fill this form" — one call, every handle pinned. */
  pin?: boolean;
}

export interface FormField {
  handleId: ElementHandle;
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

export interface ReadFormResult {
  fields: FormField[];
}

// extract_text
export interface ExtractTextParams {
  appHandle?: string;
  data?: string; // base64 PNG
  /** WindowServer ID from list_windows. Omitting uses the default visible window. */
  windowId?: number;
  region?: { x: number; y: number; width: number; height: number };
}

export interface TextItem {
  text: string;
  confidence: number;
  bbox: { x: number; y: number; w: number; h: number };
}

export interface ExtractTextResult {
  items: TextItem[];
}

// pin_handle
/**
 * Extend a handle's idle TTL to 60 min (default), refreshed on each use. Pins are
 * finite — abandoned handles age out, so there is no separate unpin method.
 *
 * Use the bulk `handleIds` form when you discover a set of handles together (e.g.
 * the result of a `read_form(pin: true)` that you instead want to pin after the fact).
 * Prefer the `pin: true` flag on `query_tree`, `get_element`, and `read_form` when you
 * know at mint time — it costs zero extra round trips.
 */
export interface PinHandleParams {
  handleId?: string;
  handleIds?: string[];
}

export interface PinHandleResult {
  pinned: true;
  /** Singular path. Present when the caller used `handleId`. */
  handleId?: string;
  /** Bulk path. Maps each requested id to `true` on success or `{ error: code }` on
   *  failure (`"unknown_handle"`, `"stale_handle: <reason>"`). */
  results?: Record<string, boolean | { error: string }>;
}

// dump_attributes
export interface DumpAttributesParams {
  handleId: string;
}

export type DumpAttributesResult = Record<string, unknown>;

// --- Generic action result ---
export interface ActionResult {
  success: boolean;
  handleId?: string;
}
