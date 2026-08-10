import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";

import {
  DEFAULT_SKILL_NAME,
  listSkills,
  loadSkill,
  parseFrontmatterDescription,
  parseSkillMeta,
  resolveSkillName,
  resolveSkillScriptPath,
} from "../mcp-skills.js";

const tempDirs: string[] = [];

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop();
    if (dir) rmSync(dir, { recursive: true, force: true });
  }
});

function makeSkillsDir(skills: Record<string, { md: string; scripts?: Record<string, string> }>): string {
  const root = mkdtempSync(join(tmpdir(), "macbeth-skills-"));
  tempDirs.push(root);
  for (const [name, skill] of Object.entries(skills)) {
    const skillDir = join(root, name);
    mkdirSync(skillDir, { recursive: true });
    writeFileSync(join(skillDir, "SKILL.md"), skill.md);
    if (skill.scripts) {
      const scriptsDir = join(skillDir, "scripts");
      mkdirSync(scriptsDir, { recursive: true });
      for (const [file, body] of Object.entries(skill.scripts)) {
        writeFileSync(join(scriptsDir, file), body);
      }
    }
  }
  return root;
}

describe("resolveSkillName", () => {
  it("defaults omitted, null, and blank names to macbeth", () => {
    expect(resolveSkillName(undefined)).toBe(DEFAULT_SKILL_NAME);
    expect(resolveSkillName(null)).toBe(DEFAULT_SKILL_NAME);
    expect(resolveSkillName("")).toBe(DEFAULT_SKILL_NAME);
    expect(resolveSkillName("   ")).toBe(DEFAULT_SKILL_NAME);
  });

  it("preserves explicit skill names", () => {
    expect(resolveSkillName("Safari")).toBe("Safari");
    expect(resolveSkillName(" electron ")).toBe("electron");
  });
});

describe("loadSkill", () => {
  it("loads the core macbeth skill when called with no name", async () => {
    const skillsDir = makeSkillsDir({
      macbeth: {
        md: "---\nname: macbeth\ndescription: Core guide\n---\n\n# Macbeth\n\nUse query_tree first.\n",
      },
      Safari: {
        md: "---\nname: safari\ndescription: Safari workflows\n---\n\n# Safari\n",
      },
    });

    const result = await loadSkill(skillsDir);
    expect(result.isError).toBeUndefined();
    expect(result.content[0]!.text).toContain("# Macbeth");
    expect(result.content[0]!.text).toContain("Use query_tree first.");
    expect(result.content[0]!.text).not.toContain("# Safari");
  });

  it("loads the core skill for an empty-string name", async () => {
    const skillsDir = makeSkillsDir({
      macbeth: {
        md: "---\nname: macbeth\ndescription: Core guide\n---\n\n# Core\n",
      },
    });

    const result = await loadSkill(skillsDir, "");
    expect(result.isError).toBeUndefined();
    expect(result.content[0]!.text).toContain("# Core");
  });

  it("loads an explicit app skill by name", async () => {
    const skillsDir = makeSkillsDir({
      macbeth: {
        md: "---\nname: macbeth\ndescription: Core\n---\n\n# Core\n",
      },
      Safari: {
        md: "---\nname: safari\ndescription: Safari\n---\n\n# Safari Automation\n",
        scripts: {
          "open-url.mjs":
            "// @name open-url\n// @description Open a URL\n// @usage node open-url.mjs <url>\nexport {};\n",
        },
      },
    });

    const result = await loadSkill(skillsDir, "Safari");
    expect(result.isError).toBeUndefined();
    expect(result.content[0]!.text).toContain("# Safari Automation");
    expect(result.content[0]!.text).toContain("## Runnable Scripts");
    expect(result.content[0]!.text).toContain("open-url.mjs");
  });

  it("reports a typed miss when the skill directory is absent", async () => {
    const skillsDir = makeSkillsDir({
      macbeth: {
        md: "---\nname: macbeth\ndescription: Core\n---\n\n# Core\n",
      },
    });

    const result = await loadSkill(skillsDir, "MissingApp");
    expect(result.isError).toBe(true);
    expect(result.content[0]!.text).toContain('Skill "MissingApp" not found');
  });
});

describe("listSkills", () => {
  it("includes the core macbeth skill alongside app skills", async () => {
    const skillsDir = makeSkillsDir({
      macbeth: {
        md: "---\nname: macbeth\ndescription: How to use Macbeth MCP tools\n---\n\n# Macbeth\n",
      },
      electron: {
        md: "---\nname: electron\ndescription: Electron apps\n---\n\n# Electron\n",
      },
    });

    const result = await listSkills(skillsDir);
    expect(result.isError).toBeUndefined();
    expect(result.content[0]!.text).toContain("**macbeth**: How to use Macbeth MCP tools");
    expect(result.content[0]!.text).toContain("**electron**: Electron apps");
  });

  it("surfaces YAML block-scalar descriptions in list_skills", async () => {
    const skillsDir = makeSkillsDir({
      Notes: {
        md:
          "---\nname: notes\ndescription: |\n  Create and append notes.\n  Prefer AX over AppleScript.\n---\n\n# Notes\n",
      },
    });

    const meta = await parseSkillMeta(skillsDir, "Notes");
    expect(meta?.description).toBe("Create and append notes.\nPrefer AX over AppleScript.");

    const result = await listSkills(skillsDir);
    expect(result.content[0]!.text).toContain(
      "**Notes**: Create and append notes.\nPrefer AX over AppleScript."
    );
  });
});

describe("parseFrontmatterDescription", () => {
  it("reads a single-line description", () => {
    expect(parseFrontmatterDescription("name: x\ndescription: Hello world\n", "fb")).toBe(
      "Hello world"
    );
  });

  it("reads a literal block scalar and stops before the next top-level key", () => {
    const fm = "name: safari\ndescription: |\n  Line one\n  Line two\nother: value\n";
    expect(parseFrontmatterDescription(fm, "fb")).toBe("Line one\nLine two");
  });

  it("folds a `>` block scalar onto one line per paragraph", () => {
    const fm = "description: >\n  Hello\n  world\n\n  Next para\n";
    expect(parseFrontmatterDescription(fm, "fb")).toBe("Hello world\nNext para");
  });

  it("falls back when description is missing or an empty block", () => {
    expect(parseFrontmatterDescription("name: only\n", "Skill: x")).toBe("Skill: x");
    expect(parseFrontmatterDescription("description: |\nname: x\n", "Skill: x")).toBe("Skill: x");
  });
});

describe("resolveSkillScriptPath", () => {
  it("rejects path traversal outside the skills directory", () => {
    const skillsDir = makeSkillsDir({
      macbeth: { md: "# x\n" },
    });
    // From skills/<name>/scripts/, three levels up leaves the skills root.
    const result = resolveSkillScriptPath(skillsDir, "macbeth", "../../../etc/passwd");
    expect(result).toEqual({ ok: false, error: "Invalid script path." });
  });
});

describe("bundled skills/", () => {
  it("ships a loadable core macbeth skill at the repo skills root", async () => {
    const skillsDir = fileURLToPath(new URL("../../../skills", import.meta.url));
    const result = await loadSkill(skillsDir);
    expect(result.isError).toBeUndefined();
    const text = result.content[0]!.text;
    expect(text).toMatch(/^---\nname: macbeth\n/m);
    expect(text).toContain("query_tree");
    expect(text).toContain("connect_app");
    expect(text).toContain("windowId");
  });
});
