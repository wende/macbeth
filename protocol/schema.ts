// macbeth JSON-RPC 2.0 protocol definitions
// TypeScript is the canonical source; Swift implements manually.

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
  handleId: string;
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
}

export interface GetElementResult {
  handleId: string;
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
