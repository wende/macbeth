#!/usr/bin/env node
import { cpSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const clientDir = resolve(__dirname, "..");
const sourceDir = resolve(clientDir, "..", "skills");
const targetDir = resolve(clientDir, "skills");

if (!existsSync(sourceDir)) {
  throw new Error(`Source skills directory not found: ${sourceDir}`);
}

rmSync(targetDir, { recursive: true, force: true });
mkdirSync(clientDir, { recursive: true });
cpSync(sourceDir, targetDir, { recursive: true });

process.stdout.write(`Synced skills to ${targetDir}\n`);
