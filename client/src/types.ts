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

export interface ScreenshotResult {
  data: string;
  width: number;
  height: number;
  format: "png";
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
