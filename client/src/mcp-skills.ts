import { existsSync } from "node:fs";
import { readdir, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";

export const DEFAULT_SKILL_NAME = "macbeth";

export interface ScriptMeta {
  file: string;
  name: string;
  description: string;
  usage: string;
}

export interface SkillMeta {
  name: string;
  description: string;
  scripts: ScriptMeta[];
}

export interface SkillToolResult {
  content: Array<{ type: "text"; text: string }>;
  isError?: boolean;
  [key: string]: unknown;
}

export function resolveSkillsDir(candidates: string[]): string {
  return candidates.find(existsSync) ?? candidates[0]!;
}

/** Omit / blank → core macbeth skill so `load_skill` works with no parameters. */
export function resolveSkillName(name?: string | null): string {
  const trimmed = name?.trim();
  return trimmed ? trimmed : DEFAULT_SKILL_NAME;
}

export async function parseScriptMeta(
  scriptPath: string,
  fileName: string
): Promise<ScriptMeta | null> {
  try {
    const content = await readFile(scriptPath, "utf-8");
    const nameMatch = content.match(/^\/\/\s*@name\s+(.+)$/m);
    const descMatch = content.match(/^\/\/\s*@description\s+(.+)$/m);
    const usageMatch = content.match(/^\/\/\s*@usage\s+(.+)$/m);
    return {
      file: fileName,
      name: nameMatch?.[1]?.trim() ?? fileName.replace(/\.mjs$/, ""),
      description: descMatch?.[1]?.trim() ?? "",
      usage: usageMatch?.[1]?.trim() ?? `node ${fileName}`,
    };
  } catch {
    return null;
  }
}

export async function listSkillScripts(
  skillsDir: string,
  skillName: string
): Promise<ScriptMeta[]> {
  const scriptsDir = join(skillsDir, skillName, "scripts");
  try {
    const entries = await readdir(scriptsDir, { withFileTypes: true });
    const mjsFiles = entries.filter((e) => e.isFile() && e.name.endsWith(".mjs"));
    const scripts = await Promise.all(
      mjsFiles.map((f) => parseScriptMeta(join(scriptsDir, f.name), f.name))
    );
    return scripts.filter(Boolean) as ScriptMeta[];
  } catch {
    return [];
  }
}

/**
 * Read a skill frontmatter `description`, including YAML block scalars
 * (`description: |` / `description: >` with indented continuation lines).
 * Stops at the next top-level key or end of the frontmatter block.
 */
export function parseFrontmatterDescription(
  frontmatter: string,
  fallback: string
): string {
  const lines = frontmatter.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const header = lines[i]!.match(/^description:\s*(.*)$/);
    if (!header) continue;

    const rest = header[1] ?? "";
    const block = rest.match(/^([|>])(.*)$/);
    if (!block) {
      return rest.trim() || fallback;
    }

    const indicator = block[1]!;
    const body: string[] = [];
    for (let j = i + 1; j < lines.length; j++) {
      const line = lines[j]!;
      // Next top-level key (non-empty, non-indented) ends the block.
      if (line.length > 0 && !/^[ \t]/.test(line)) break;
      body.push(line);
    }

    const indents = body
      .filter((line) => line.trim().length > 0)
      .map((line) => line.match(/^[ \t]*/)?.[0]?.length ?? 0);
    const minIndent = indents.length > 0 ? Math.min(...indents) : 0;
    const dedented = body.map((line) => line.slice(minIndent));

    if (indicator === ">") {
      const paragraphs: string[] = [];
      let current: string[] = [];
      for (const line of dedented) {
        if (line.trim() === "") {
          if (current.length > 0) {
            paragraphs.push(current.join(" "));
            current = [];
          }
        } else {
          current.push(line.trimEnd());
        }
      }
      if (current.length > 0) paragraphs.push(current.join(" "));
      return paragraphs.join("\n").trim() || fallback;
    }

    return dedented.join("\n").trim() || fallback;
  }

  return fallback;
}

export async function parseSkillMeta(
  skillsDir: string,
  skillDir: string
): Promise<SkillMeta | null> {
  try {
    const content = await readFile(join(skillsDir, skillDir, "SKILL.md"), "utf-8");
    const fmMatch = content.match(/^---\n([\s\S]*?)\n---/);
    const fallback = `Skill: ${skillDir}`;
    const description = fmMatch
      ? parseFrontmatterDescription(fmMatch[1]!, fallback)
      : fallback;
    const scripts = await listSkillScripts(skillsDir, skillDir);
    return { name: skillDir, description, scripts };
  } catch {
    return null;
  }
}

export function formatSkillScripts(scripts: ScriptMeta[]): string {
  if (scripts.length === 0) return "";
  const lines = scripts.map(
    (s) =>
      `  - **${s.name}** (${s.file}): ${s.description}${s.usage ? `\n    Usage: \`${s.usage}\`` : ""}`
  );
  return "\n  Scripts:\n" + lines.join("\n");
}

export async function listSkills(skillsDir: string): Promise<SkillToolResult> {
  try {
    const entries = await readdir(skillsDir, { withFileTypes: true });
    const dirs = entries.filter((e) => e.isDirectory());
    const skills = (
      await Promise.all(dirs.map((d) => parseSkillMeta(skillsDir, d.name)))
    ).filter(Boolean) as SkillMeta[];
    if (skills.length === 0) {
      return { content: [{ type: "text", text: "No skills found in skills/ directory." }] };
    }
    const text = skills
      .map((s) => `- **${s.name}**: ${s.description}${formatSkillScripts(s.scripts)}`)
      .join("\n");
    return { content: [{ type: "text", text }] };
  } catch {
    return {
      content: [
        {
          type: "text",
          text: "No skills/ directory found. Create skills/<name>/SKILL.md to add skills.",
        },
      ],
      isError: true,
    };
  }
}

export async function loadSkill(
  skillsDir: string,
  name?: string | null
): Promise<SkillToolResult> {
  const skillName = resolveSkillName(name);
  try {
    const content = await readFile(join(skillsDir, skillName, "SKILL.md"), "utf-8");
    const scripts = await listSkillScripts(skillsDir, skillName);

    let text = content;
    if (scripts.length > 0) {
      text += "\n\n---\n\n## Runnable Scripts\n\n";
      text += "Use the `run_skill_script` tool to execute these:\n\n";
      text += scripts
        .map(
          (s) =>
            `- **${s.name}** (\`${s.file}\`): ${s.description}\n  Usage: \`${s.usage}\``
        )
        .join("\n\n");
    }

    return { content: [{ type: "text", text }] };
  } catch {
    return {
      content: [
        {
          type: "text",
          text: `Skill "${skillName}" not found. Run list_skills to see available skills.`,
        },
      ],
      isError: true,
    };
  }
}

export function resolveSkillScriptPath(
  skillsDir: string,
  skill: string,
  script: string
): { ok: true; path: string } | { ok: false; error: string } {
  const scriptPath = join(skillsDir, skill, "scripts", script);
  const resolved = resolve(scriptPath);
  if (!resolved.startsWith(resolve(skillsDir))) {
    return { ok: false, error: "Invalid script path." };
  }
  return { ok: true, path: scriptPath };
}
