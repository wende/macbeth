import { describe, expect, it } from "vitest";
import { z } from "zod";

import {
  CliParseError,
  fieldToFlag,
  flagToFieldName,
  materializeToolArgs,
  parseJsonObject,
  parseToolArgv,
} from "../cli-args.js";

const clickLike = {
  name: "click",
  inputSchema: {
    app: z.union([z.string(), z.number()]),
    handleId: z.string().optional(),
    timeout: z.number().optional().default(30),
    pin: z.boolean().optional(),
    query: z.array(z.object({ role: z.string().optional() })).optional(),
    modifiers: z.array(z.string()).optional(),
  },
};

describe("CLI argument parsing", () => {
  it("maps kebab, snake, and camel flags to MCP field names", () => {
    expect(flagToFieldName("handle-id")).toBe("handleId");
    expect(flagToFieldName("handle_id")).toBe("handleId");
    expect(flagToFieldName("handleId")).toBe("handleId");
    expect(flagToFieldName("--wait-for-idle-ms")).toBe("waitForIdleMs");
    expect(fieldToFlag("waitForIdleMs")).toBe("wait-for-idle-ms");
  });

  it("parses --json exclusively and flags as MCP fields", () => {
    expect(parseToolArgv(["--json", '{"app":"Finder"}'])).toEqual({
      help: false,
      json: '{"app":"Finder"}',
      values: {},
    });
    expect(parseToolArgv(["--app", "Finder", "--handle-id", "h_1"])).toEqual({
      help: false,
      json: undefined,
      values: { app: "Finder", handleId: "h_1" },
    });
    expect(() => parseToolArgv(["--json", "{}", "--app", "Finder"])).toThrow(CliParseError);
    expect(() => parseToolArgv(["--json", "--app", "Finder"])).toThrow(/requires a JSON object/);
    expect(parseToolArgv(["--json", "-"])).toEqual({
      help: false,
      json: "-",
      values: {},
    });
  });

  it("coerces all-digit --app flags to a PID and leaves JSON strings alone", () => {
    const fromFlag = materializeToolArgs(clickLike, parseToolArgv(["--app", "1234"]).values);
    expect(fromFlag.app).toBe(1234);
    const fromJson = materializeToolArgs(clickLike, { app: "1234" }, { coerce: false });
    expect(fromJson.app).toBe("1234");
  });

  it("applies Zod defaults the same way MCP does", () => {
    const parsed = materializeToolArgs(clickLike, { app: "Finder", handleId: "h_1" });
    expect(parsed.timeout).toBe(30);
  });

  it("accepts JSON arrays for nested MCP fields and repeated flags for string arrays", () => {
    const nested = materializeToolArgs(
      clickLike,
      parseToolArgv(["--app", "Finder", "--query", '[{"role":"button"}]']).values
    );
    expect(nested.query).toEqual([{ role: "button" }]);

    const repeated = materializeToolArgs(
      clickLike,
      parseToolArgv(["--app", "Finder", "--modifiers", "cmd", "--modifiers", "shift"]).values
    );
    expect(repeated.modifiers).toEqual(["cmd", "shift"]);
  });

  it("parses --json objects and rejects arrays", () => {
    expect(parseJsonObject('{"app":"Finder"}')).toEqual({ app: "Finder" });
    expect(() => parseJsonObject("[]")).toThrow(/JSON object/);
  });

  it("rejects a repeated non-array flag instead of stringifying the pair", () => {
    expect(() => parseToolArgv(["--app", "Finder", "--app", "1234"], clickLike))
      .toThrow(/Repeated --app/);
    const raw = parseToolArgv(["--app", "Finder", "--app", "1234"]).values;
    expect(() => materializeToolArgs(clickLike, raw)).toThrow(/Repeated --app/);
  });

  it("rejects --no-<field> and a bare flag on non-boolean options", () => {
    expect(() => parseToolArgv(["--no-handle-id"], clickLike))
      .toThrow(/only valid for boolean options/);
    expect(() => parseToolArgv(["--handle-id"], clickLike))
      .toThrow(/requires a value/);
    const parsed = parseToolArgv(["--app", "Finder", "--no-pin"], clickLike);
    expect(materializeToolArgs(clickLike, parsed.values).pin).toBe(false);
  });

  it("uses singular Unknown option for a single typo", () => {
    expect(() => materializeToolArgs(clickLike, { app: "Finder", nope: true }))
      .toThrow(/Unknown option for click: --nope/);
    expect(() => materializeToolArgs(clickLike, { app: "Finder", foo: 1, bar: 2 }))
      .toThrow(/Unknown options for click: --foo, --bar/);
  });
});
