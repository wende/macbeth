export interface QueryStep {
  role?: string;
  title?: string;
  identifier?: string;
  titlePattern?: string;
  index?: number;
}

export interface AppInfo {
  name: string;
  pid: number;
  bundleId: string | null;
  runtime: "native" | "electron" | "unknown";
}

export interface ConnectOptions {
  socketPath?: string;
  daemonPath?: string;
  timeout?: number;
  verbose?: boolean;
}

export interface TreeOptions {
  maxDepth?: number;
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

export type ClickStrategy = "auto" | "ax" | "flash";

export interface ClickOptions {
  timeout?: number;
  /** Click strategy: "auto" (default), "ax" (AXPress only), or "flash". */
  strategy?: ClickStrategy;
  /**
   * Flash click only. Wait until the user has been idle this many ms (capped at
   * 5s) before stealing focus. Default 0 (off).
   */
  waitForIdleMs?: number;
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
