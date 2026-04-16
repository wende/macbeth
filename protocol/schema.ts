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

export interface AppInfo {
  name: string;
  pid: number;
  bundleId: string | null;
}

// connect_app
export interface ConnectAppParams {
  name?: string;
  pid?: number;
}

export interface ConnectAppResult {
  appHandle: string;
  name: string;
  pid: number;
  bundleId: string | null;
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
export interface ClickParams {
  appHandle: string;
  handleId?: string;
  query?: QueryStep[];
  timeout?: number;
}

// fill
export interface FillParams {
  appHandle: string;
  handleId?: string;
  query?: QueryStep[];
  value: string;
  timeout?: number;
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
  windowHandle?: string;
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

// --- Generic action result ---
export interface ActionResult {
  success: boolean;
  handleId?: string;
}
