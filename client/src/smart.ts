import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { createInterface, type Interface } from "node:readline";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ToolResult } from "./tool-errors.js";
import type { ToolContext, ToolDefinition } from "./tools.js";

export interface SmartLogEntry {
  step: number;
  tool: string;
  args: Record<string, unknown>;
  output: string;
}

interface ExecutedEntry extends SmartLogEntry {
  error: boolean;
}

export interface SmartRanking {
  id: string;
  score: number;
  description: string;
}

export interface SmartDecision {
  step: number;
  phase: "app" | "target";
  choice: string;
  description: string;
  confidence: number;
  latencyMs: number;
  model?: string;
  topCandidates: SmartRanking[];
}

export interface SmartResult {
  status: "success" | "failure" | "step_limit";
  reason: string;
  toolsUsed: SmartLogEntry[];
  decisions?: SmartDecision[];
}

export interface SmartRerankResult {
  scores: number[];
  latencyMs: number;
  model?: string;
}

export type SmartReranker = (query: string, documents: string[]) => Promise<SmartRerankResult>;

export interface SmartCandidate {
  id: string;
  description: string;
  value: string;
}

interface ParsedNode {
  handle: string;
  role: string;
  title: string;
  line: string;
  depth: number;
  disabled: boolean;
  actionableAncestor: boolean;
  ancestors: string[];
  siblingTitles: string[];
}

const MODULE_DIR = dirname(fileURLToPath(import.meta.url));
const BRIDGE = resolve(MODULE_DIR, "..", "native", "laya_smart.py");
const ACTIONABLE_ROLE = /^(?:AX)?(?:button|menu[_ ]?item|check[_ ]?box|radio[_ ]?button|pop[_ ]?up[_ ]?button|link|text[_ ]?field|search[_ ]?field|slider|tab)$/i;

function resultText(result: ToolResult): string {
  return result.content.map((block) => block.text).join("\n");
}

function unique(values: string[]): string[] {
  return [...new Set(values)];
}

function publicLog(log: ExecutedEntry[]): SmartLogEntry[] {
  return log.map(({ step, tool, args, output }) => ({ step, tool, args, output }));
}

function nodeLabel(role: string, title: string): string {
  return title || role.replaceAll("_", " ");
}

function parseTree(output: string): ParsedNode[] {
  const parsed: ParsedNode[] = [];
  const stack: Array<{ depth: number; label: string; parentKey: string; actionable: boolean }> = [];
  const siblings = new Map<string, string[]>();

  for (const line of output.split("\n")) {
    const match = line.match(/^(\s*)\[([^\s\]]+)(?:\s+"([^"]*)")?[^\]]*\].*?\b(h_\d+)\b/);
    if (!match) continue;
    const depth = match[1]!.length;
    const role = match[2]!;
    const title = match[3] ?? "";
    while (stack.length > 0 && stack.at(-1)!.depth >= depth) stack.pop();
    const ancestors = stack.map((entry) => entry.label).filter(Boolean);
    const parentKey = stack.at(-1)?.parentKey ?? "root";
    const label = nodeLabel(role, title);
    const siblingTitles = siblings.get(parentKey) ?? [];
    const node: ParsedNode = {
      handle: match[4]!,
      role,
      title,
      line: line.trim(),
      depth,
      disabled: /\[disabled\]/i.test(line),
      actionableAncestor: stack.some((entry) => entry.actionable),
      ancestors,
      siblingTitles,
    };
    parsed.push(node);
    siblings.set(parentKey, [...siblingTitles, label].slice(-6));
    stack.push({ depth, label, parentKey: node.handle, actionable: ACTIONABLE_ROLE.test(role) && !node.disabled });
  }

  const byParent = new Map<string, ParsedNode[]>();
  for (const node of parsed) {
    const parent = node.ancestors.join("\u0000");
    byParent.set(parent, [...(byParent.get(parent) ?? []), node]);
  }
  for (const nodes of byParent.values()) {
    nodes.forEach((node, index) => {
      node.siblingTitles = nodes
        .slice(Math.max(0, index - 3), index)
        .concat(nodes.slice(index + 1, index + 4))
        .map((sibling) => sibling.title)
        .filter(Boolean)
        .slice(0, 4);
    });
  }
  return parsed;
}

function candidateDocument(node: ParsedNode): string {
  const role = node.role.startsWith("AX") ? node.role : `AX${node.role.split(/[_ ]/).map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join("")}`;
  return [
    `id=${node.handle}`,
    `role=${role}`,
    `title=${node.title}`,
    "enabled=true",
    "actions=[press]",
    `ancestors=${node.ancestors.join(" > ") || "(none)"}`,
  ].join("\n");
}

export function discoverSmartApps(log: SmartLogEntry[]): SmartCandidate[] {
  const text = log.map((entry) => entry.output).join("\n");
  const jsonNames = [...text.matchAll(/"ownerName"\s*:\s*"([^"]+)"/g)].map((match) => match[1]!);
  const yamlNames = [...text.matchAll(/^\s*ownerName:\s*(.+)$/gim)].map((match) => match[1]!.trim());
  const appLines = [...text.matchAll(/^\s*[-•]?\s*([^\n(]+?)\s*\((?:pid|bundle|match):/gim)].map((match) => match[1]!.trim());
  return unique([...jsonNames, ...yamlNames, ...appLines]).map((app, index) => ({
    id: `app_${index}`,
    value: app,
    description: `id=app_${index}\nrole=AXApplication\ntitle=${app}\nenabled=true\nactions=[inspect accessibility tree]`,
  }));
}

export function discoverSmartElements(log: SmartLogEntry[]): SmartCandidate[] {
  const latestTree = [...log].reverse().find((entry) => entry.tool === "query_tree");
  if (!latestTree) return [];
  return parseTree(latestTree.output)
    .filter((node) => ACTIONABLE_ROLE.test(node.role) && !node.disabled && !node.actionableAncestor && !node.ancestors.slice(1).includes("Apple"))
    .map((node) => ({ id: node.handle, value: node.handle, description: candidateDocument(node) }));
}

function topRankings(candidates: SmartCandidate[], scores: number[], limit = 10): SmartRanking[] {
  return candidates
    .map((candidate, index) => ({ id: candidate.id, score: scores[index] ?? Number.NEGATIVE_INFINITY, description: candidate.description }))
    .sort((a, b) => b.score - a.score)
    .slice(0, limit);
}

export async function runSmartFlow(options: {
  task: string;
  steps: number;
  debug?: boolean;
  ctx: ToolContext;
  tools: ToolDefinition[];
  rerank: SmartReranker;
}): Promise<SmartResult> {
  const log: ExecutedEntry[] = [];
  const decisions: SmartDecision[] = [];
  const finish = (status: SmartResult["status"], reason: string): SmartResult => ({
    status,
    reason,
    toolsUsed: publicLog(log),
    ...(options.debug ? { decisions } : {}),
  });
  const execute = async (toolName: string, args: Record<string, unknown>): Promise<ToolResult> => {
    const tool = options.tools.find((candidate) => candidate.name === toolName);
    if (!tool || tool.name === "smart") throw new Error(`Unavailable tool selected: ${toolName}`);
    let result: ToolResult;
    try {
      result = await tool.handler(options.ctx, args);
    } catch (error) {
      result = { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }], isError: true };
    }
    log.push({ step: log.length + 1, tool: toolName, args, output: resultText(result), error: result.isError === true });
    return result;
  };
  const choose = async (phase: SmartDecision["phase"], candidates: SmartCandidate[]): Promise<SmartCandidate> => {
    if (candidates.length === 0) throw new Error(`No viable ${phase} candidates were found.`);
    const result = await options.rerank(options.task, candidates.map((candidate) => candidate.description));
    if (result.scores.length !== candidates.length) throw new Error(`Reranker returned ${result.scores.length} scores for ${candidates.length} candidates.`);
    const ranked = topRankings(candidates, result.scores);
    const winner = candidates.find((candidate) => candidate.id === ranked[0]!.id)!;
    decisions.push({
      step: log.length + 1,
      phase,
      choice: winner.id,
      description: winner.description,
      confidence: ranked[0]!.score,
      latencyMs: result.latencyMs,
      ...(result.model ? { model: result.model } : {}),
      topCandidates: ranked,
    });
    return winner;
  };

  try {
    if (options.steps < 1) return finish("step_limit", `Reached the ${options.steps}-step limit.`);
    const appsResult = await execute("list_apps", {});
    if (appsResult.isError) return finish("failure", "Could not list applications.");
    if (log.length >= options.steps) return finish("step_limit", `Reached the ${options.steps}-step limit.`);

    const app = await choose("app", discoverSmartApps(log));
    const treeResult = await execute("query_tree", { app: app.value, maxDepth: 8, maxNodes: 500, format: "text", pin: true });
    if (treeResult.isError) return finish("failure", `Could not inspect ${app.value}.`);
    if (log.length >= options.steps) return finish("step_limit", `Reached the ${options.steps}-step limit.`);

    const target = await choose("target", discoverSmartElements(log));
    const clickResult = await execute("click", { app: app.value, handleId: target.value });
    if (clickResult.isError) return finish("failure", `The highest-ranked element ${target.value} could not be activated.`);
    return finish("success", `Activated the highest-ranked accessibility element ${target.value}.`);
  } catch (error) {
    return finish("failure", error instanceof Error ? error.message : String(error));
  }
}

export class QwenSmartReranker {
  private process?: ChildProcessWithoutNullStreams;
  private lines?: Interface;
  private pending: Array<{ resolve: (value: SmartRerankResult) => void; reject: (error: Error) => void }> = [];

  private start(): void {
    if (this.process) return;
    const localPython = resolve(MODULE_DIR, "..", "..", ".venv-smart", "bin", "python");
    const python = process.env.MACBETH_SMART_PYTHON ?? (existsSync(localPython) ? localPython : "python3");
    this.process = spawn(python, [BRIDGE], { stdio: ["pipe", "pipe", "pipe"] });
    this.lines = createInterface({ input: this.process.stdout });
    this.lines.on("line", (line) => {
      const pending = this.pending.shift();
      if (!pending) return;
      try {
        const response = JSON.parse(line) as SmartRerankResult & { error?: string };
        if (response.error) pending.reject(new Error(response.error));
        else if (Array.isArray(response.scores)) pending.resolve(response);
        else pending.reject(new Error("Qwen reranker returned no scores"));
      } catch (error) {
        pending.reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
    this.process.on("error", (error) => this.rejectAll(error));
    this.process.on("exit", (code) => this.rejectAll(new Error(`Qwen reranker process exited with status ${code}`)));
  }

  private rejectAll(error: Error): void {
    this.process = undefined;
    for (const pending of this.pending.splice(0)) pending.reject(error);
  }

  rerank: SmartReranker = async (query, documents) => {
    this.start();
    return new Promise<SmartRerankResult>((resolveResult, reject) => {
      this.pending.push({ resolve: resolveResult, reject });
      this.process!.stdin.write(`${JSON.stringify({ query, documents })}\n`);
    });
  };

  close(): void {
    this.lines?.close();
    this.process?.kill();
    this.process = undefined;
  }
}
