import { describe, expect, it } from "vitest";
import type { MacbethClient } from "../client.js";
import {
  discoverSmartApps,
  discoverSmartElements,
  runSmartFlow,
  type SmartReranker,
} from "../smart.js";
import type { ToolContext, ToolDefinition } from "../tools.js";

const ctx: ToolContext = {
  client: {} as MacbethClient,
  skillsDir: "",
  withActivity: (operation) => operation(),
};

function tool(name: string, output: string, isError = false): ToolDefinition {
  return {
    name,
    description: name,
    handler: async () => ({ content: [{ type: "text", text: output }], ...(isError ? { isError: true } : {}) }),
  };
}

function titleScores(documents: string[], preferred: string): number[] {
  return documents.map((document) => document.includes(`title=${preferred}`) ? 0.95 : 0.05);
}

describe("smart reranker flow", () => {
  it("reranks apps and actionable AX nodes while preserving handle mapping", async () => {
    const requests: Array<{ query: string; documents: string[] }> = [];
    const rerank: SmartReranker = async (query, documents) => {
      requests.push({ query, documents });
      return {
        scores: requests.length === 1 ? titleScores(documents, "Devin") : titleScores(documents, "Preferences"),
        latencyMs: 42,
        model: "mlx-community/Qwen3-Reranker-0.6B-4bit",
      };
    };
    const tools = [
      tool("list_apps", "Finder (pid: 1, runtime: native)\nDevin (pid: 2, runtime: electron)"),
      tool("query_tree", [
        '[app "Devin"] h:h_1',
        '  [menubar] h:h_2',
        '    [menu_bar_item "Devin"] h:h_3',
        '      [menu] h:h_4',
        '        [menu_item "About Devin"] h:h_5',
        '        [menu_item "Preferences"] h:h_6',
        '        [menu_item "Open…"] h:h_7',
      ].join("\n")),
      tool("click", "Clicked successfully"),
    ];

    const result = await runSmartFlow({ task: "Find and open Devin settings panel", steps: 3, debug: true, ctx, tools, rerank });

    expect(result.status).toBe("success");
    expect(result.toolsUsed.map((entry) => entry.tool)).toEqual(["list_apps", "query_tree", "click"]);
    expect(result.toolsUsed[2]!.args).toEqual({ app: "Devin", handleId: "h_6" });
    expect(result.toolsUsed[0]).not.toHaveProperty("isError");
    expect(requests[1]!.query).toBe("Find and open Devin settings panel");
    expect(requests[1]!.documents.find((document) => document.includes("title=Preferences"))).toContain("ancestors=Devin > menubar > Devin > menu");
    expect(result.decisions?.[1]).toEqual(expect.objectContaining({ choice: "h_6", confidence: 0.95, latencyMs: 42 }));
    expect(result.decisions?.[1]!.topCandidates[0]).toEqual(expect.objectContaining({ id: "h_6", score: 0.95 }));
  });

  it("stops at the requested tool-call limit", async () => {
    const result = await runSmartFlow({
      task: "Inspect Finder",
      steps: 2,
      ctx,
      tools: [
        tool("list_apps", "Finder (pid: 1, runtime: native)"),
        tool("query_tree", '[button "Open"] h:h_2'),
      ],
      rerank: async (_query, documents) => ({ scores: documents.map(() => 1), latencyMs: 1 }),
    });

    expect(result.status).toBe("step_limit");
    expect(result.toolsUsed).toHaveLength(2);
  });

  it("keeps all viable elements for semantic reranking and excludes disabled controls", () => {
    const log = [{
      step: 1,
      tool: "query_tree",
      args: { app: "Devin" },
      output: [
        '[menu_bar_item "Devin"] h:h_1',
        '  [menu] h:h_2',
        '    [menu_item "Preferences"] h:h_3',
        '    [menu_item "Open…"] h:h_4',
        '    [menu_item "Unavailable" [disabled]] h:h_5',
      ].join("\n"),
    }];

    const elements = discoverSmartElements(log);
    expect(elements.map((element) => element.value)).toEqual(["h_3", "h_4"]);
    expect(elements.find((element) => element.value === "h_3")!.description).toContain("ancestors=Devin > menu");
  });

  it.each([
    {
      task: "Find and open Devin settings panel",
      preferred: "Preferences",
      tree: '[menu_item "Open…"] h:h_1\n[menu_item "Preferences"] h:h_2',
      expected: "h_2",
    },
    {
      task: "Open the New Terminal menu item",
      preferred: "New Terminal",
      tree: '[menu_item "New Window"] h:h_1\n[menu_item "New Terminal"] h:h_2',
      expected: "h_2",
    },
    {
      task: "Choose the Extensions sidebar button",
      preferred: "Extensions",
      tree: '[button "Explorer"] h:h_1\n[button "Extensions"] h:h_2',
      expected: "h_2",
    },
  ])("selects the expected candidate for $task", async ({ task, preferred, tree, expected }) => {
    let call = 0;
    const result = await runSmartFlow({
      task,
      steps: 3,
      ctx,
      tools: [tool("list_apps", "Devin (pid: 2, runtime: electron)"), tool("query_tree", tree), tool("click", "ok")],
      rerank: async (_query, documents) => ({
        scores: call++ === 0 ? documents.map(() => 1) : titleScores(documents, preferred),
        latencyMs: 1,
      }),
    });

    expect(result.status).toBe("success");
    expect(result.toolsUsed[2]!.args.handleId).toBe(expected);
  });

  it("returns a failure when no actionable nodes are available", async () => {
    const result = await runSmartFlow({
      task: "Open settings",
      steps: 3,
      ctx,
      tools: [tool("list_apps", "Devin (pid: 2, runtime: electron)"), tool("query_tree", '[window "Devin"] h:h_1')],
      rerank: async (_query, documents) => ({ scores: documents.map(() => 1), latencyMs: 1 }),
    });

    expect(result.status).toBe("failure");
    expect(result.reason).toContain("No viable target candidates");
  });

  it("discovers every app without lexical pre-pruning", () => {
    const apps = discoverSmartApps([{
      step: 1,
      tool: "list_apps",
      args: {},
      output: "ChatGPT (pid: 1, runtime: electron)\nDevin (pid: 2, runtime: electron)",
    }]);

    expect(apps.map((app) => app.value)).toEqual(["ChatGPT", "Devin"]);
  });
});
