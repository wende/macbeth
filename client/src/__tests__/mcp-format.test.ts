import { describe, expect, it } from "vitest";
import { parse as parseYaml } from "yaml";

import { toModelPayload } from "../mcp-format.js";

describe("toModelPayload", () => {
  it("renders empty objects and arrays on multiple lines", () => {
    expect(toModelPayload({})).toBe("{}\n");
    expect(toModelPayload([])).toBe("[]\n");
  });

  it("quotes free-text strings that look like YAML scalars", () => {
    // Without quoting, "Yes" parses as a boolean and "2026-08-10" as a date.
    const out = toModelPayload({
      yesNo: "Yes",
      dateLike: "2026-08-10",
      nullish: "null",
      tilde: "~",
    });
    expect(out).toContain("Yes");
    expect(out).toContain("2026-08-10");
    expect(out).toContain("null");
    expect(out).toContain("~");
    // All four values must stay strings — they would change type without quoting.
    for (const value of ["Yes", "2026-08-10", "null", "~"]) {
      const re = new RegExp(`: ['"]?${value.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\\\$&")}['"]?`);
      expect(out).toMatch(re);
    }
  });

  it("preserves strings containing colon-space and hash", () => {
    const tricky = "path: /tmp/foo #comment\nline2";
    const out = toModelPayload({ v: tricky });
    expect(out).toContain("path: /tmp/foo");
    expect(out).toContain("line2");
    // newline-bearing string must be quoted / block-scalar, not parsed as flow.
    expect(out).not.toMatch(/^v: path:[^\n]*$/m);
  });

  it("keeps emoji and unicode intact", () => {
    const out = toModelPayload({ label: "✓ done" });
    expect(out).toContain("✓ done");
  });

  it("does not hard-wrap long values (lineWidth: 0)", () => {
    const long = "x".repeat(200);
    const out = toModelPayload({ v: long });
    const lines = out.split("\n").filter((line) => line.includes(long));
    expect(lines).toHaveLength(1);
  });

  it("returns deterministic, parseable YAML", () => {
    const obj = {
      count: 2,
      windows: [
        { windowId: 1, title: "A" },
        { windowId: 2, title: "B" },
      ],
      nested: { a: 1, b: [true, false, null] },
    };
    const out = toModelPayload(obj);
    // Must not throw on second parse round-trip.
    expect(() => parseYaml(out)).not.toThrow();
  });
});