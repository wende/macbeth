import { describe, expect, it } from "vitest";
import { resolveElementTarget } from "../mcp-target.js";

describe("resolveElementTarget", () => {
  it("accepts a locator query", () => {
    expect(resolveElementTarget([{ role: "button", identifier: "save" }])).toEqual({
      query: [{ role: "button", identifier: "save" }],
    });
  });

  it("accepts a direct handle", () => {
    expect(resolveElementTarget(undefined, "h_42")).toEqual({ handleId: "h_42" });
  });

  it("rejects missing and ambiguous targets", () => {
    expect(() => resolveElementTarget()).toThrow('exactly one of "query" or "handleId"');
    expect(() => resolveElementTarget([], undefined)).toThrow('exactly one of "query" or "handleId"');
    expect(() => resolveElementTarget([{ role: "button" }], "h_42")).toThrow(
      'exactly one of "query" or "handleId"'
    );
  });
});
