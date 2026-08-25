# CLI

The `macbeth` binary is both the MCP server entry point and a command-line
client for the same tools. `npx macbeth` with no arguments still starts the
stdio MCP server — that is what agent configs invoke. Every MCP tool is also a
subcommand:

```bash
macbeth list_apps
macbeth query_tree --app Finder --max-depth 2
macbeth click --json '{"app":"Finder","handleId":"h_1"}'
macbeth load_skill          # core usage guide (same as MCP load_skill with no args)
macbeth load_skill --name Safari
macbeth list_apps --help    # arguments for one tool
```

`--json '{...}'` is the CLI equivalent of an MCP tool call: the object uses the
same field names the MCP server advertises. Flags (`--app`, `--handle-id`,
`--query '[{...}]'`) are a more convenient spelling of those fields. Kebab-case
and snake_case flags map to the MCP camelCase names (`--handle-id` → `handleId`).

Both surfaces execute the catalog in `client/src/tools.ts`. Adding a tool there
is what exposes it through MCP *and* the CLI; `mcp.ts` must not call
`registerTool` on its own.

The daemon stays warm across CLI invocations (the same as TypeScript scripts),
so handles (`h_3`) and `begin_activity` tokens remain valid until they expire.

## Limitations that would need a different product

These are not missing tools. The CLI can invoke every MCP tool with the same
arguments and the same handlers. Matching the *session* around those tools 1:1
would mean speaking MCP over stdio, which is already `macbeth` with no arguments.

1. **Transport.** MCP is a long-lived stdio JSON-RPC session. The CLI is one-shot
   argv → stdout. Host features — session negotiation, per-request cancellation
   IDs, and the model-facing `mcp.log` usage tracker — are not tool capabilities.
2. **Nested values on the flag path.** Arrays and objects are JSON strings
   (`--query '[{"role":"button"}]'`). `--json` is lossless.
3. **All-digit `--app` flags.** `--app 1234` is a PID. `--json '{"app":"1234"}'`
   is the name `"1234"`. Use `--json` when those collide.
4. **Process-local MCP state.** Durable state (handles, activity tokens) lives in
   the daemon and is shared. The MCP usage log is process-local on purpose
   (it measures what the *model* received) and has no CLI equivalent.
5. **Unused MCP surface.** Macbeth does not expose Resources, Prompts, streaming
   progress, or image content blocks. Screenshot returns a file path as text on
   both surfaces. Adding those MCP features would need a new CLI UX, not just
   another catalog entry.

`macbeth doctor`, `update`, `version`, and `help` are CLI-only meta commands.
They are not MCP tools.

Tools that only touch the filesystem (`list_skills`, `load_skill`) do not start
the daemon. The client is created on first daemon-backed call.
