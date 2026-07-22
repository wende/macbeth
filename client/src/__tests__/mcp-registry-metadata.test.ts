import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

interface PackageJson {
  name: string;
  version: string;
  mcpName?: string;
  engines?: { node?: string };
  license?: string;
  os?: string[];
}

interface ServerJson {
  $schema: string;
  name: string;
  title?: string;
  description: string;
  version: string;
  repository?: {
    url?: string;
    source?: string;
    id?: string;
  };
  packages?: Array<{
    registryType?: string;
    registryBaseUrl?: string;
    identifier?: string;
    version?: string;
    runtimeHint?: string;
    transport?: { type?: string };
    environmentVariables?: unknown[];
  }>;
  remotes?: unknown[];
}

const packageJson = JSON.parse(
  readFileSync(fileURLToPath(new URL("../../package.json", import.meta.url)), "utf8")
) as PackageJson;

const serverJson = JSON.parse(
  readFileSync(fileURLToPath(new URL("../../../server.json", import.meta.url)), "utf8")
) as ServerJson;

describe("Official MCP Registry metadata", () => {
  it("keeps the Registry identity and release version synchronized", () => {
    expect(packageJson.name).toBe("macbeth");
    expect(packageJson.mcpName).toBe("io.github.wende/macbeth");
    expect(serverJson.name).toBe(packageJson.mcpName);
    expect(serverJson.version).toBe(packageJson.version);
    expect(serverJson.title).toBe("Macbeth");
    expect(serverJson.description.length).toBeGreaterThan(0);
    expect(serverJson.description.length).toBeLessThanOrEqual(100);
  });

  it("describes the verified npm stdio distribution without remote or secret inputs", () => {
    expect(serverJson.$schema).toBe(
      "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json"
    );
    expect(serverJson.repository).toEqual({
      url: "https://github.com/wende/macbeth",
      source: "github",
      id: "1192861656",
    });
    expect(serverJson.packages).toHaveLength(1);
    expect(serverJson.packages?.[0]).toEqual({
      registryType: "npm",
      registryBaseUrl: "https://registry.npmjs.org",
      identifier: "macbeth",
      version: packageJson.version,
      runtimeHint: "npx",
      transport: { type: "stdio" },
    });
    expect(serverJson.remotes).toBeUndefined();
    expect(serverJson.packages?.[0].environmentVariables).toBeUndefined();
  });

  it("matches the package's documented platform and license requirements", () => {
    expect(packageJson.engines?.node).toBe(">=20");
    expect(packageJson.os).toEqual(["darwin"]);
    expect(packageJson.license).toBe("MIT");
  });
});
