import { describe, expect, it } from "vitest";
import {
  describeKeyPress,
  describeKeyStrokes,
  formatKeyDispatch,
} from "../key-dispatch.js";
import type { PressKeyResult } from "../types.js";

function result(overrides: Partial<PressKeyResult> = {}): PressKeyResult {
  return {
    success: true,
    outcome: "dispatched",
    dispatched: true,
    verified: false,
    note: "Keyboard events entered the system event stream. Whether the app acted on them is not verified.",
    warnings: [],
    keysRequested: 1,
    keysPosted: 1,
    evidence: { sessionKeyDownDelta: 1, accessibilityTrusted: true },
    target: {
      app: "Slack",
      pid: 4821,
      bundleId: "com.tinyspeck.slackmacgap",
      frontmost: true,
      focusedApp: { pid: 4821, name: "Slack" },
      window: { title: "general", identity: "pid:4821:window:12" },
      focusedElement: {
        role: "AXTextArea",
        subrole: null,
        title: null,
        identifier: "message-input",
        value: "hello",
      },
    },
    ...overrides,
  };
}

describe("key labels", () => {
  it("renders modifiers with the key", () => {
    expect(describeKeyPress("return")).toBe("return");
    expect(describeKeyPress("a", ["cmd", "shift"])).toBe("cmd+shift+a");
  });

  it("renders a sequence of keys and literal text", () => {
    expect(
      describeKeyStrokes([{ key: "l", modifiers: ["cmd"] }, { text: "example.com" }, { key: "return" }])
    ).toBe('cmd+l, "example.com", return');
  });
});

describe("formatKeyDispatch", () => {
  it("names the app, window and focused element, and refuses to claim the app acted", () => {
    const { text, isError } = formatKeyDispatch("return", result(), "Pressed return");

    expect(isError).toBe(false);
    expect(text).toContain("Slack (pid 4821)");
    expect(text).toContain('window "general"');
    expect(text).toContain('focus AXTextArea "message-input"');
    expect(text).toContain("not verified");
    expect(text).toContain("outcome=dispatched verified=false");
    expect(text).not.toMatch(/^Pressed return$/);
  });

  it("reports an unverifiable dispatch without calling it a failure", () => {
    const { text, isError } = formatKeyDispatch(
      "return",
      result({
        outcome: "attempted",
        dispatched: false,
        note: "Dispatch could not be confirmed. Do not resend blindly — confirm the current state with query_tree, wait_for, or screenshot first.",
        warnings: ["dispatch-unconfirmed"],
        evidence: { sessionKeyDownDelta: 0, accessibilityTrusted: true },
      }),
      "Pressed return"
    );

    // Unconfirmed delivery is not a tool error: flagging it as one makes agents
    // resend, and duplicate keystrokes are worse than an honest caveat.
    expect(isError).toBe(false);
    expect(text).toContain("outcome=attempted");
    expect(text).toContain("warnings=[dispatch-unconfirmed]");
    expect(text).toContain("Do not resend blindly");
  });

  it("marks a hard dispatch failure as an error", () => {
    const { text, isError } = formatKeyDispatch(
      "return",
      result({
        success: false,
        outcome: "attempted",
        dispatched: false,
        keysPosted: 0,
        note: "Dispatch could not be confirmed. No keyboard events could be created, so nothing was sent to the system.",
        warnings: ["dispatch-failed"],
        evidence: { sessionKeyDownDelta: 0, accessibilityTrusted: true },
      }),
      "Pressed return"
    );

    expect(isError).toBe(true);
    expect(text).toContain("keysPosted=0/1");
    expect(text).toContain("nothing was sent");
  });

  it("says when no element holds focus", () => {
    const base = result();
    const { text } = formatKeyDispatch(
      "tab",
      result({
        warnings: ["no-focused-element"],
        target: { ...base.target, focusedElement: null },
      }),
      "Pressed tab"
    );

    expect(text).toContain("no focused element");
    expect(text).toContain("warnings=[no-focused-element]");
  });

  it("names the app that actually held keyboard focus", () => {
    const base = result();
    const { text } = formatKeyDispatch(
      "cmd+s",
      result({
        warnings: ["target-not-frontmost"],
        target: {
          ...base.target,
          frontmost: false,
          focusedApp: { pid: 300, name: "Finder" },
        },
      }),
      "Pressed cmd+s"
    );

    expect(text).toContain("NOT frontmost — keyboard focus was on Finder (pid 300)");
  });

  it("falls back to the legacy wording for a daemon that reports no outcome", () => {
    const { text, isError } = formatKeyDispatch("return", { success: true }, "Pressed return");

    expect(text).toBe("Pressed return");
    expect(isError).toBe(false);
  });
});
