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
 *  - it goes unused past the daemon's idle TTL (5 min) and isn't pinned — `stale_handle`
 *    (-32010) with `data.reason === "expired"`
 *  - the app destroys or recycles the element — `stale_handle` with `"destroyed"` /
 *    `"recycled"`
 *  - the owning app quits — `stale_handle` with `"app_terminated"`
 *  - the daemon restarts, which clears every handle — `unknown_handle` (-32011)
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
  source: string;
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

export interface AppInfo {
  name: string;
  pid: number;
  bundleId: string | null;
  aliases: string[];
  runtime: AppRuntime;
}

// connect_app
export interface ConnectAppParams {
  name?: string;
  pid?: number;
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
  matchKind: "pid" | "exact_name" | "declared_alias" | "bundle_identifier" | "partial_name" | "partial_alias" | "partial_bundle_identifier";
  matchedValue: string;
  manualAccessibility: string;
  webContentReadiness: "ready" | "empty_web_area" | "no_web_area" | null;
}

// list_windows
export interface ListWindowsParams {
  appHandle: string;
}

export type WindowKind = "window" | "bookkeeping" | "menu_bar" | "overlay";

export interface AppWindowInfo {
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
  default: boolean;
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
