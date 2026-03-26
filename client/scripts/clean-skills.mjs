#!/usr/bin/env node
import { existsSync, rmSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const clientDir = resolve(__dirname, "..");
const targetDir = resolve(clientDir, "skills");

if (existsSync(targetDir)) {
  rmSync(targetDir, { recursive: true, force: true });
  process.stdout.write(`Removed ${targetDir}\n`);
}
