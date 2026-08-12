import type { JsonRpcClient } from "./rpc.js";
import {
  isAppHandleInvalid,
  isRecoverableHandleError,
  isUnknownHandleError,
} from "./errors.js";

export interface LocatorOptions {
  timeout?: number;
  /**
   * Re-connect to the app this locator belongs to and return its current app handle.
   * Supplied by `AppHandle`, which knows the pid. Recovery paths use it when the app
   * handle itself has stopped being valid — chiefly after a daemon restart, which
   * invalidates element handles and app handles alike.
   */
  reacquireApp?: () => Promise<string>;
}
import type { QueryStep, ElementInfo, ClickOptions, FillStrategy } from "./types.js";

function buildClickParams(args: {
  appHandle: string;
  query: QueryStep[];
  defaultTimeout: number;
  options?: ClickOptions;
  handleId?: string;
}) {
  const { appHandle, query, defaultTimeout, options, handleId } = args;
  return {
    appHandle,
    query,
    ...(handleId !== undefined ? { handleId } : {}),
    timeout: (options?.timeout ?? defaultTimeout) / 1000,
    ...(options?.strategy ? { strategy: options.strategy } : {}),
    ...(options?.waitForIdleMs !== undefined ? { waitForIdleMs: options.waitForIdleMs } : {}),
  };
}

/**
 * A Locator represents a way to find an element in the AX tree.
 * Inspired by Playwright's Locator pattern — immutable, chainable, lazy.
 * No RPC is sent until a terminal method (click, fill, etc.) is called.
 */
export class Locator {
  protected rpc: JsonRpcClient;
  protected appHandle: string;
  protected queryPath: QueryStep[];
  protected defaultTimeout: number;
  protected reacquireApp?: () => Promise<string>;

  constructor(
    rpc: JsonRpcClient,
    appHandle: string,
    queryPath: QueryStep[],
    options?: LocatorOptions
  ) {
    this.rpc = rpc;
    this.appHandle = appHandle;
    this.queryPath = queryPath;
    this.defaultTimeout = options?.timeout ?? 30_000;
    this.reacquireApp = options?.reacquireApp;
  }

  /** Options that derived locators inherit. */
  protected get inheritedOptions(): LocatorOptions {
    return { timeout: this.defaultTimeout, reacquireApp: this.reacquireApp };
  }

  // --- Narrowing methods (return new Locator with appended step) ---

  private child(role: string, title?: string, opts?: { identifier?: string }): Locator {
    return new Locator(this.rpc, this.appHandle, [
      ...this.queryPath,
      { role, title, identifier: opts?.identifier },
    ], this.inheritedOptions);
  }

  /** Find a child by role, title, and/or identifier */
  locator(query: QueryStep): Locator {
    return new Locator(this.rpc, this.appHandle, [
      ...this.queryPath,
      query,
    ], this.inheritedOptions);
  }

  // Convenience shorthand methods for common roles
  window(title: string): Locator { return this.child("window", title); }
  button(title?: string, opts?: { identifier?: string }): Locator { return this.child("button", title, opts); }
  textField(title?: string, opts?: { identifier?: string }): Locator { return this.child("text_field", title, opts); }
  textArea(title?: string, opts?: { identifier?: string }): Locator { return this.child("text_area", title, opts); }
  checkbox(title?: string): Locator { return this.child("checkbox", title); }
  radio(title?: string): Locator { return this.child("radio", title); }
  tab(title: string): Locator { return this.child("tab", title); }
  tabGroup(title?: string): Locator { return this.child("tab_group", title); }
  menu(title: string): Locator { return this.child("menu", title); }
  menuItem(title: string): Locator { return this.child("menu_item", title); }
  menuBar(): Locator { return this.child("menubar"); }
  menuBarItem(title: string): Locator { return this.child("menu_bar_item", title); }
  toolbar(): Locator { return this.child("toolbar"); }
  group(title?: string, opts?: { identifier?: string }): Locator { return this.child("group", title, opts); }
  list(title?: string): Locator { return this.child("list", title); }
  table(title?: string): Locator { return this.child("table", title); }
  row(title?: string): Locator { return this.child("row", title); }
  cell(title?: string): Locator { return this.child("cell", title); }
  slider(title?: string): Locator { return this.child("slider", title); }
  popup(title?: string): Locator { return this.child("popup", title); }
  comboBox(title?: string): Locator { return this.child("combo_box", title); }
  text(title?: string): Locator { return this.child("text", title); }
  image(title?: string): Locator { return this.child("image", title); }
  scrollArea(title?: string): Locator { return this.child("scroll_area", title); }
  sheet(title?: string): Locator { return this.child("sheet", title); }
  dialog(title?: string): Locator { return this.child("dialog", title); }
  disclosure(title?: string): Locator { return this.child("disclosure", title); }
  outline(title?: string): Locator { return this.child("outline", title); }
  link(title?: string): Locator { return this.child("link", title); }
  splitGroup(title?: string): Locator { return this.child("split_group", title); }
  // Web content (Electron / Chromium). Web areas are the DOM root; headings are
  // the most common structural landmark inside them.
  webArea(title?: string): Locator { return this.child("web_area", title); }
  heading(title?: string): Locator { return this.child("heading", title); }

  // --- Terminal action methods (send RPC) ---

  async click(options?: ClickOptions): Promise<void> {
    await this.rpc.call("click", buildClickParams({
      appHandle: this.appHandle,
      query: this.queryPath,
      defaultTimeout: this.defaultTimeout,
      options,
    }));
  }

  async fill(value: string, options?: { timeout?: number; strategy?: FillStrategy }): Promise<void> {
    await this.rpc.call("fill", {
      appHandle: this.appHandle,
      query: this.queryPath,
      value,
      timeout: (options?.timeout ?? this.defaultTimeout) / 1000,
      ...(options?.strategy ? { strategy: options.strategy } : {}),
    });
  }

  async waitFor(options?: { timeout?: number }): Promise<ElementInfo> {
    return this.rpc.call<ElementInfo>("wait_for", {
      appHandle: this.appHandle,
      query: this.queryPath,
      timeout: (options?.timeout ?? this.defaultTimeout) / 1000,
    });
  }

  async getInfo(): Promise<ElementInfo> {
    return this.rpc.call<ElementInfo>("get_element", {
      appHandle: this.appHandle,
      query: this.queryPath,
    });
  }

  async getText(): Promise<string | undefined> {
    const info = await this.getInfo();
    return info.value ?? info.title;
  }

  async isEnabled(): Promise<boolean> {
    const info = await this.getInfo();
    return info.enabled;
  }

  async isFocused(): Promise<boolean> {
    const info = await this.getInfo();
    return info.focused;
  }

  /** Resolve this locator once and return a scoped locator that uses the handle directly.
   *  Falls back to re-querying if the handle expires. Pins the handle so the agent has
   *  a 60-min (refreshed-on-use) window to operate on the returned reference. */
  async scope(): Promise<ScopedLocator> {
    const info = await this.getInfo();
    await this.rpc.call("pin_handle", { handleId: info.handleId });
    return new ScopedLocator(
      this.rpc, this.appHandle, this.queryPath, info.handleId, this.inheritedOptions
    );
  }
}

class ScopedLocator extends Locator {
  private handleId: string;

  constructor(
    rpc: JsonRpcClient,
    appHandle: string,
    queryPath: QueryStep[],
    handleId: string,
    options?: LocatorOptions
  ) {
    super(rpc, appHandle, queryPath, options);
    this.handleId = handleId;
  }

  override async click(options?: ClickOptions): Promise<void> {
    await this.withRediscovery(() =>
      this.rpc.call("click", buildClickParams({
        appHandle: this.appHandle,
        handleId: this.handleId,
        query: this.queryPath,
        defaultTimeout: this.defaultTimeout,
        options,
      }))
    );
  }

  override async fill(value: string, options?: { timeout?: number; strategy?: FillStrategy }): Promise<void> {
    await this.withRediscovery(() =>
      this.rpc.call("fill", {
        appHandle: this.appHandle,
        handleId: this.handleId,
        value,
        timeout: (options?.timeout ?? this.defaultTimeout) / 1000,
        ...(options?.strategy ? { strategy: options.strategy } : {}),
      })
    );
  }

  override async getInfo(): Promise<ElementInfo> {
    return this.withRediscovery(() =>
      this.rpc.call<ElementInfo>("get_element", {
        appHandle: this.appHandle,
        handleId: this.handleId,
      })
    );
  }

  /**
   * Run a handle-based call, re-resolving and retrying exactly once if it fails because
   * the handle went stale. A second stale failure propagates instead of recursing again —
   * an app that keeps recycling the element faster than we can resolve it (Electron
   * re-render storms, list virtualisation) must fail fast, not hang the caller forever.
   */
  private async withRediscovery<T>(action: () => Promise<T>): Promise<T> {
    try {
      return await action();
    } catch (err) {
      if (!isRecoverableHandleError(err)) throw err;
      await this.rediscover(err);
      return action();
    }
  }

  /**
   * Re-resolve the element from the query path this locator was built from.
   *
   * The app handle can be dead too. An `unknown_handle` says so outright — the id came
   * from a previous daemon process, so this one's app handles are unrelated and its
   * `h_N` may already belong to a *different* app, which would resolve the query against
   * the wrong window. Re-acquire the app first in that case. For every other stale
   * reason the app handle is presumed good, and re-acquiring is only attempted if the
   * query is actually rejected for it — connect_app waits for Electron web content, so
   * it must not be on the path of an ordinary TTL re-resolve.
   */
  private async rediscover(cause?: unknown): Promise<void> {
    let reacquired = false;
    if (isUnknownHandleError(cause)) {
      await this.reacquireAppHandle();
      reacquired = true;
    }

    let info: ElementInfo;
    try {
      info = await this.resolveFromQuery();
    } catch (err) {
      // Already reacquired once for this rediscovery: a second app_not_found means
      // reconnecting didn't help, so retrying it again would only waste a redundant
      // connect_app (Electron waits for web content on every call) for no benefit.
      if (reacquired || !isAppHandleInvalid(err) || this.reacquireApp === undefined) throw err;
      await this.reacquireAppHandle();
      info = await this.resolveFromQuery();
    }

    this.handleId = info.handleId;
    await this.rpc.call("pin_handle", { handleId: this.handleId });
  }

  private resolveFromQuery(): Promise<ElementInfo> {
    return this.rpc.call<ElementInfo>("get_element", {
      appHandle: this.appHandle,
      query: this.queryPath,
    });
  }

  private async reacquireAppHandle(): Promise<void> {
    if (this.reacquireApp === undefined) return;
    this.appHandle = await this.reacquireApp();
  }
}
