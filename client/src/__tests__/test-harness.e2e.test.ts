import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { AppHandle, MacbethClient } from "../client.js";

const rootDir = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const bundlePath = resolve(rootDir, "test-harness/.build/MacbethTestApp.app");
const guiEnabled = process.platform === "darwin" && process.env.MACBETH_GUI_TESTS === "1";
const guiDescribe = guiEnabled ? describe : describe.skip;
const keyboardDescribe = guiEnabled && process.env.MACBETH_GUI_KEYBOARD_TESTS === "1"
  ? describe
  : describe.skip;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

guiDescribe("Macbeth packaged test harness", () => {
  let client: MacbethClient;
  let app: AppHandle;

  beforeAll(async () => {
    execFileSync(resolve(rootDir, "scripts/build-test-harness.sh"), { stdio: "inherit" });
    expect(existsSync(bundlePath)).toBe(true);

    execFileSync("open", ["-g", "-n", bundlePath]);
    client = new MacbethClient({ timeout: 10_000 });

    const deadline = Date.now() + 10_000;
    let lastError: unknown;
    while (Date.now() < deadline) {
      try {
        app = await client.connect("Macbeth TestApp");
        return;
      } catch (error) {
        lastError = error;
        await sleep(100);
      }
    }
    throw lastError ?? new Error("Macbeth TestApp did not launch");
  }, 30_000);

  afterAll(async () => {
    if (app?.pid) process.kill(app.pid, "SIGTERM");
    await client?.close();
  });

  it("is a regular app discoverable by name with a live window", async () => {
    const apps = await client.listApps();
    expect(apps).toContainEqual(expect.objectContaining({
      name: "Macbeth TestApp",
      bundleId: "dev.macbeth.testapp",
      runtime: "native",
    }));

    const tree = await app.queryTree({ maxDepth: 2 });
    expect(tree).toContain('[window "Macbeth TestApp"');
  });

  it("automates fields, form state, handles, and submit state", async () => {
    const name = app.locator({ role: "text_field", identifier: "name-input" });
    const email = app.locator({ role: "text_field", identifier: "email-input" });
    const status = app.locator({ role: "text", identifier: "status-label" });

    await name.fill("Macbeth GUI Test");
    await email.fill("gui-test@example.test");

    const scopedName = await name.scope();
    expect((await scopedName.getInfo()).value).toBe("Macbeth GUI Test");
    await scopedName.unpin();

    const fields = await app.readForm({ maxDepth: 5 });
    expect(fields).toEqual(expect.arrayContaining([
      expect.objectContaining({ identifier: "name-input", value: "Macbeth GUI Test" }),
      expect.objectContaining({ identifier: "email-input", value: "gui-test@example.test" }),
    ]));

    await app.locator({ role: "button", identifier: "submit-btn" }).click();
    expect(await status.getText()).toBe("Status: Submitted – Macbeth GUI Test, gui-test@example.test");
  });

  it("handles modal windows without foreground activation", async () => {
    await app.locator({ role: "button", identifier: "modal-btn" }).click();
    const modal = app.window("Modal Dialog");
    await modal.waitFor({ timeout: 5_000 });
    await modal.locator({ role: "text_field", identifier: "modal-text-input" }).fill("modal probe");
    await modal.locator({ role: "button", identifier: "modal-close-btn" }).click();

    expect(await app.locator({ role: "text", identifier: "status-label" }).getText()).toBe("Status: Modal closed");
  });

  keyboardDescribe("keyboard input", () => {
    it("activates the target before sending keyboard events", async () => {
      await app.pressKey("tab");
      await app.pressKeys([{ key: "tab" }, { text: "keyboard-probe" }]);
    });
  });

  it("returns bounded errors for missing apps, locators, and waits", async () => {
    await expect(client.connect("Macbeth Definitely Missing App")).rejects.toThrow("No running app matching");
    await expect(
      app.locator({ role: "button", identifier: "missing-button" }).click({ timeout: 1_000 })
    ).rejects.toThrow("No element matching");
    await expect(app.window("Missing Modal").waitFor({ timeout: 500 })).rejects.toThrow("No element matching");
  });
});
