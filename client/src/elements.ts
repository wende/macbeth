import { type JsonRpcClient, JsonRpcError } from "./rpc.js";
import type { QueryStep, ElementInfo, ClickOptions } from "./types.js";

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

  constructor(
    rpc: JsonRpcClient,
    appHandle: string,
    queryPath: QueryStep[],
    options?: { timeout?: number }
  ) {
    this.rpc = rpc;
    this.appHandle = appHandle;
    this.queryPath = queryPath;
    this.defaultTimeout = options?.timeout ?? 30_000;
  }

  // --- Narrowing methods (return new Locator with appended step) ---

  private child(role: string, title?: string, opts?: { identifier?: string }): Locator {
    return new Locator(this.rpc, this.appHandle, [
      ...this.queryPath,
      { role, title, identifier: opts?.identifier },
    ], { timeout: this.defaultTimeout });
  }

  /** Find a child by role, title, and/or identifier */
  locator(query: QueryStep): Locator {
    return new Locator(this.rpc, this.appHandle, [
      ...this.queryPath,
      query,
    ], { timeout: this.defaultTimeout });
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

  // --- Terminal action methods (send RPC) ---

  async click(options?: ClickOptions): Promise<void> {
    await this.rpc.call("click", {
      appHandle: this.appHandle,
      query: this.queryPath,
      timeout: (options?.timeout ?? this.defaultTimeout) / 1000,
      strategy: options?.strategy,
      waitForIdleMs: options?.waitForIdleMs,
    });
  }

  async fill(value: string, options?: { timeout?: number }): Promise<void> {
    await this.rpc.call("fill", {
      appHandle: this.appHandle,
      query: this.queryPath,
      value,
      timeout: (options?.timeout ?? this.defaultTimeout) / 1000,
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
   *  Falls back to re-querying if the handle expires. Pins the handle to prevent TTL expiry. */
  async scope(): Promise<ScopedLocator> {
    const info = await this.getInfo();
    await this.rpc.call("pin_handle", { handleId: info.handleId });
    return new ScopedLocator(this.rpc, this.appHandle, this.queryPath, info.handleId, { timeout: this.defaultTimeout });
  }
}

class ScopedLocator extends Locator {
  private handleId: string;

  constructor(
    rpc: JsonRpcClient,
    appHandle: string,
    queryPath: QueryStep[],
    handleId: string,
    options?: { timeout?: number }
  ) {
    super(rpc, appHandle, queryPath, options);
    this.handleId = handleId;
  }

  override async click(options?: ClickOptions): Promise<void> {
    try {
      await this.rpc.call("click", {
        appHandle: this.appHandle,
        handleId: this.handleId,
        timeout: (options?.timeout ?? this.defaultTimeout) / 1000,
        strategy: options?.strategy,
        waitForIdleMs: options?.waitForIdleMs,
      });
    } catch (err) {
      if (isHandleExpired(err)) {
        await this.rediscover();
        return this.click(options);
      }
      throw err;
    }
  }

  override async fill(value: string, options?: { timeout?: number }): Promise<void> {
    try {
      await this.rpc.call("fill", {
        appHandle: this.appHandle,
        handleId: this.handleId,
        value,
        timeout: (options?.timeout ?? this.defaultTimeout) / 1000,
      });
    } catch (err) {
      if (isHandleExpired(err)) {
        await this.rediscover();
        return this.fill(value, options);
      }
      throw err;
    }
  }

  override async getInfo(): Promise<ElementInfo> {
    try {
      return await this.rpc.call<ElementInfo>("get_element", {
        appHandle: this.appHandle,
        handleId: this.handleId,
      });
    } catch (err) {
      if (isHandleExpired(err)) {
        await this.rediscover();
        return this.getInfo();
      }
      throw err;
    }
  }

  private async rediscover(): Promise<void> {
    const info = await this.rpc.call<ElementInfo>("get_element", {
      appHandle: this.appHandle,
      query: this.queryPath,
    });
    this.handleId = info.handleId;
    await this.rpc.call("pin_handle", { handleId: this.handleId });
  }

  async unpin(): Promise<void> {
    await this.rpc.call("unpin_handle", { handleId: this.handleId });
  }
}

function isHandleExpired(err: unknown): boolean {
  return err instanceof JsonRpcError && err.code === -32000 && err.message.includes("expired");
}
