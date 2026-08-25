import { z, type ZodTypeAny } from "zod";

export class CliParseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CliParseError";
  }
}

export interface ToolArgSchema {
  name: string;
  inputSchema?: Record<string, ZodTypeAny>;
}

export interface ParsedToolArgv {
  help: boolean;
  /** Present when the caller used `--json` / `-j` (MCP-equivalent structured args). */
  json?: string;
  values: Record<string, unknown>;
}

/** `--handle-id` / `--handle_id` / `--handleId` all map to the MCP field `handleId`. */
export function flagToFieldName(flag: string): string {
  const trimmed = flag.replace(/^--?/, "");
  return trimmed.replace(/[-_]+([a-zA-Z0-9])/g, (_, c: string) => c.toUpperCase());
}

export function fieldToFlag(field: string): string {
  return field.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);
}

function unwrap(schema: ZodTypeAny): ZodTypeAny {
  let current: ZodTypeAny = schema;
  for (;;) {
    const def = current._def as {
      typeName?: string;
      innerType?: ZodTypeAny;
      schema?: ZodTypeAny;
    };
    if (
      def.typeName === "ZodOptional"
      || def.typeName === "ZodDefault"
      || def.typeName === "ZodNullable"
    ) {
      current = def.innerType!;
      continue;
    }
    if (def.typeName === "ZodEffects") {
      current = def.schema!;
      continue;
    }
    return current;
  }
}

function typeNameOf(schema: ZodTypeAny): string {
  return String((unwrap(schema)._def as { typeName?: string }).typeName ?? "");
}

export function schemaIsOptional(schema: ZodTypeAny): boolean {
  const name = String((schema._def as { typeName?: string }).typeName ?? "");
  return name === "ZodOptional" || name === "ZodDefault";
}

export function schemaTypeLabel(schema: ZodTypeAny): string {
  const inner = unwrap(schema);
  const name = String((inner._def as { typeName?: string }).typeName ?? "");
  if (name === "ZodBoolean") return "boolean";
  if (name === "ZodNumber") return "number";
  if (name === "ZodString") return "string";
  if (name === "ZodEnum") {
    const values = (inner._def as { values?: string[] }).values ?? [];
    return values.join("|") || "string";
  }
  if (name === "ZodArray") return "json";
  if (name === "ZodObject") return "json";
  if (name === "ZodUnion") {
    const options = ((inner._def as { options?: ZodTypeAny[] }).options ?? [])
      .map((option) => schemaTypeLabel(option));
    return [...new Set(options)].join("|") || "string";
  }
  return "string";
}

export function schemaDescription(schema: ZodTypeAny): string {
  return schema.description
    ?? unwrap(schema).description
    ?? "";
}

function fieldSchema(tool: ToolArgSchema | undefined, field: string): ZodTypeAny | undefined {
  return tool?.inputSchema?.[field];
}

function isArraySchema(schema: ZodTypeAny | undefined): boolean {
  return schema !== undefined && typeNameOf(schema) === "ZodArray";
}

function isBooleanSchema(schema: ZodTypeAny | undefined): boolean {
  return schema !== undefined && typeNameOf(schema) === "ZodBoolean";
}

function assignValue(existing: unknown, value: unknown): unknown {
  if (existing === undefined) return value;
  if (Array.isArray(existing)) return [...existing, value];
  return [existing, value];
}

function setFlagValue(
  values: Record<string, unknown>,
  field: string,
  value: unknown,
  tool?: ToolArgSchema
): void {
  const schema = fieldSchema(tool, field);
  if (values[field] !== undefined && schema && !isArraySchema(schema)) {
    throw new CliParseError(
      `Repeated --${fieldToFlag(field)} is not allowed; pass the value once`
    );
  }
  values[field] = schema === undefined || isArraySchema(schema)
    ? assignValue(values[field], value)
    : value;
}

function takeJsonOperand(argv: string[], index: number): { value: string; nextIndex: number } {
  const value = argv[index];
  if (value === undefined) {
    throw new CliParseError("`--json` requires a JSON object, or `-` to read stdin");
  }
  // `-` is the stdin sentinel. Any other leading-dash token is a flag, not JSON.
  if (value.startsWith("-") && value !== "-") {
    throw new CliParseError("`--json` requires a JSON object, or `-` to read stdin");
  }
  return { value, nextIndex: index };
}

function splitEquals(token: string): [string, string | undefined] {
  const eq = token.indexOf("=");
  if (eq === -1) return [token, undefined];
  return [token.slice(0, eq), token.slice(eq + 1)];
}

/**
 * Parse argv *after* the tool name into either `--help`, a `--json` blob, or
 * per-field flags that match the MCP input schema.
 *
 * Pass `tool` so duplicates and `--no-<field>` can be rejected against the
 * schema instead of turning into a later "invalid value" from `coerce`.
 */
export function parseToolArgv(argv: string[], tool?: ToolArgSchema): ParsedToolArgv {
  const values: Record<string, unknown> = {};
  let json: string | undefined;
  let help = false;

  for (let i = 0; i < argv.length; i++) {
    const token = argv[i]!;
    if (token === "--help" || token === "-h") {
      help = true;
      continue;
    }
    if (token === "--json" || token === "-j") {
      const taken = takeJsonOperand(argv, i + 1);
      json = taken.value;
      i = taken.nextIndex;
      continue;
    }
    if (token.startsWith("--json=")) {
      json = token.slice("--json=".length);
      continue;
    }
    if (token.startsWith("--no-")) {
      const field = flagToFieldName(token.slice("--no-".length));
      if (!field) {
        throw new CliParseError("`--no-` must be followed by a boolean option name");
      }
      const schema = fieldSchema(tool, field);
      if (schema && !isBooleanSchema(schema)) {
        throw new CliParseError(
          `--no-${fieldToFlag(field)} is only valid for boolean options`
        );
      }
      setFlagValue(values, field, false, tool);
      continue;
    }
    if (token.startsWith("--")) {
      const [rawName, inline] = splitEquals(token.slice(2));
      const field = flagToFieldName(rawName);
      if (inline !== undefined) {
        setFlagValue(values, field, inline, tool);
        continue;
      }
      const next = argv[i + 1];
      const schema = fieldSchema(tool, field);
      if (next === undefined || next.startsWith("-")) {
        if (schema && !isBooleanSchema(schema)) {
          throw new CliParseError(`Option --${fieldToFlag(field)} requires a value`);
        }
        setFlagValue(values, field, true, tool);
      } else {
        i += 1;
        setFlagValue(values, field, next, tool);
      }
      continue;
    }
    throw new CliParseError(`Unexpected argument: ${token}`);
  }

  if (json !== undefined && Object.keys(values).length > 0) {
    throw new CliParseError("`--json` cannot be combined with other tool flags; pass every argument inside the JSON object");
  }

  return { help, json, values };
}

function coerceNumber(value: unknown, field: string): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "") {
    const n = Number(value);
    if (Number.isFinite(n)) return n;
  }
  throw new CliParseError(`Option --${fieldToFlag(field)} expects a number`);
}

function coerceBoolean(value: unknown, field: string): boolean {
  if (typeof value === "boolean") return value;
  if (value === "true" || value === "1") return true;
  if (value === "false" || value === "0") return false;
  throw new CliParseError(`Option --${fieldToFlag(field)} expects a boolean`);
}

function parseJsonValue(value: string, field: string): unknown {
  try {
    return JSON.parse(value);
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    throw new CliParseError(`Option --${fieldToFlag(field)} is not valid JSON: ${detail}`);
  }
}

function looksLikeJson(value: string): boolean {
  const trimmed = value.trim();
  return trimmed.startsWith("{") || trimmed.startsWith("[");
}

function coerce(schema: ZodTypeAny, value: unknown, field: string): unknown {
  if (value === undefined) return undefined;
  const inner = unwrap(schema);
  const name = String((inner._def as { typeName?: string }).typeName ?? "");

  if (name === "ZodBoolean") return coerceBoolean(value, field);
  if (name === "ZodNumber") return coerceNumber(value, field);
  if (name === "ZodString" || name === "ZodEnum") {
    return typeof value === "string" ? value : String(value);
  }
  if (name === "ZodObject") {
    if (typeof value === "string") return parseJsonValue(value, field);
    if (value && typeof value === "object") return value;
    throw new CliParseError(`Option --${fieldToFlag(field)} expects a JSON object`);
  }
  if (name === "ZodArray") {
    const element = (inner._def as { type: ZodTypeAny }).type;
    let items: unknown[];
    if (typeof value === "string") {
      items = looksLikeJson(value) ? (parseJsonValue(value, field) as unknown[]) : [value];
    } else if (Array.isArray(value)) {
      items = value;
    } else {
      items = [value];
    }
    if (!Array.isArray(items)) {
      throw new CliParseError(`Option --${fieldToFlag(field)} expects a JSON array`);
    }
    return items.map((item, index) => coerce(element, item, `${field}[${index}]`));
  }
  if (name === "ZodUnion") {
    const options = (inner._def as { options?: ZodTypeAny[] }).options ?? [];
    const optionNames = options.map((option) => typeNameOf(option));
    // App targets are string | number. An all-digit flag is a PID; quoted JSON
    // strings stay names. `--json` is the lossless path when those collide.
    if (
      optionNames.includes("ZodNumber")
      && optionNames.includes("ZodString")
      && typeof value === "string"
      && /^-?\d+$/.test(value)
    ) {
      return Number(value);
    }
    const errors: string[] = [];
    for (const option of options) {
      try {
        return coerce(option, value, field);
      } catch (err) {
        errors.push(err instanceof Error ? err.message : String(err));
      }
    }
    throw new CliParseError(errors[0] ?? `Option --${fieldToFlag(field)} has an invalid value`);
  }
  if (typeof value === "string" && looksLikeJson(value)) {
    return parseJsonValue(value, field);
  }
  return value;
}

export function toolZodObject(tool: ToolArgSchema): z.ZodObject<z.ZodRawShape> {
  return z.object(tool.inputSchema ?? {});
}

/**
 * Coerce CLI flags / a JSON object into the same shape the MCP handler receives,
 * including Zod defaults.
 *
 * Pass `coerce: false` for `--json` input: JSON already has types, and a string
 * `"1234"` must stay a name rather than becoming a PID.
 */
export function materializeToolArgs(
  tool: ToolArgSchema,
  raw: Record<string, unknown>,
  options?: { coerce?: boolean }
): Record<string, unknown> {
  const shape = tool.inputSchema ?? {};
  const unknown = Object.keys(raw).filter((key) => !(key in shape));
  if (unknown.length > 0) {
    const flags = unknown.map((k) => `--${fieldToFlag(k)}`).join(", ");
    const label = unknown.length === 1 ? "Unknown option" : "Unknown options";
    throw new CliParseError(`${label} for ${tool.name}: ${flags}`);
  }

  const coerceValues = options?.coerce !== false;
  const coerced: Record<string, unknown> = {};
  for (const [field, schema] of Object.entries(shape)) {
    if (raw[field] === undefined) continue;
    const flag = fieldToFlag(field);
    if (Array.isArray(raw[field]) && typeNameOf(schema) !== "ZodArray") {
      throw new CliParseError(
        `Repeated --${flag} is not allowed; pass the value once`
      );
    }
    if (typeof raw[field] === "boolean" && typeNameOf(schema) !== "ZodBoolean") {
      throw new CliParseError(
        raw[field]
          ? `Option --${flag} requires a value`
          : `--no-${flag} is only valid for boolean options`
      );
    }
    coerced[field] = coerceValues ? coerce(schema, raw[field], field) : raw[field];
  }
  const parsed = toolZodObject(tool).safeParse(coerced);
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    const path = issue?.path.length ? issue.path.join(".") : tool.name;
    throw new CliParseError(`${path}: ${issue?.message ?? parsed.error.message}`);
  }
  return parsed.data;
}

export function parseJsonObject(text: string): Record<string, unknown> {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    throw new CliParseError(`Invalid JSON: ${detail}`);
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new CliParseError("`--json` must be a JSON object");
  }
  return value as Record<string, unknown>;
}
