import { cpSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";

import { describe, expect, it } from "vitest";

describe("auth schema generation", { timeout: 30_000 }, () => {
  it("reproduces the committed Better Auth schemas", () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-auth-schema-"));
    try {
      const script = new URL("../scripts/generate-auth-schema.mjs", import.meta.url);
      const generated = spawnSync(process.execPath, [script.pathname], { cwd: directory, encoding: "utf8" });
      expect(generated.status, generated.stderr || generated.stdout).toBe(0);
      for (const name of ["postgres-auth-schema.ts", "sqlite-auth-schema.ts"]) {
        const schema = readFileSync(join(directory, "src/db/generated", name), "utf8");
        expect(schema).toBe(readFileSync(new URL(`../src/db/generated/${name}`, import.meta.url), "utf8"));
        expect(schema).toMatch(/import \{ defineRelationsPart(?:, sql)? \} from "drizzle-orm";/);
        expect(schema).toContain("export const authRelations = defineRelationsPart(");
      }
    } finally {
      rmSync(directory, { force: true, recursive: true });
    }
  });

  it.each(["sqlite", "postgresql"] as const)("keeps the committed %s migration history synchronized with the declarative schema", (dialect) => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-app-schema-"));
    const packageDirectory = new URL("..", import.meta.url);
    try {
      cpSync(new URL(`../drizzle/${dialect === "sqlite" ? "sqlite" : "postgres"}/`, import.meta.url), directory, { recursive: true });
      const migrations = readdirSync(directory).toSorted();
      const generated = spawnSync("pnpm", [
        "exec", "drizzle-kit", "generate",
        "--dialect", dialect,
        "--schema", dialect === "sqlite" ? "./src/db/sqlite-schema.ts" : "./src/db/postgres-app-schema.ts",
        "--out", directory,
        "--name", "schema-drift",
      ], { cwd: packageDirectory, encoding: "utf8" });
      expect(generated.status, generated.stderr || generated.stdout).toBe(0);
      expect(readdirSync(directory).toSorted()).toEqual(migrations);
    } finally {
      rmSync(directory, { force: true, recursive: true });
    }
  });

  it("reproduces runtime helper SQL and preserves initial migrations", () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-runtime-schema-"));
    try {
      for (const dialect of ["postgres", "sqlite"]) {
        cpSync(new URL(`../drizzle/${dialect}`, import.meta.url), join(directory, "drizzle", dialect), { recursive: true });
      }
      cpSync(new URL("../scripts/runtime-support", import.meta.url), join(directory, "scripts/runtime-support"), { recursive: true });
      const generated = spawnSync(process.execPath, ["--import", createRequire(import.meta.url).resolve("tsx"), new URL("../scripts/generate-runtime-support.mjs", import.meta.url).pathname], {
        cwd: directory, encoding: "utf8",
      });
      expect(generated.status, generated.stderr || generated.stdout).toBe(0);
      for (const dialect of ["postgres", "sqlite"]) {
        // Policies are schema-owned; compare the hand-written runtime helpers before them.
        for (const migration of readdirSync(join(directory, "drizzle", dialect))) {
          expect(readFileSync(new URL(`../drizzle/${dialect}/${migration}/migration.sql`, import.meta.url), "utf8").split("CREATE POLICY")[0]!.trimEnd())
            .toBe(readFileSync(join(directory, "drizzle", dialect, migration, "migration.sql"), "utf8").split("CREATE POLICY")[0]!.trimEnd());
        }
      }
    } finally {
      rmSync(directory, { force: true, recursive: true });
    }
  });

  it("keeps the Agent migration history synchronized with its schema", () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-agent-schema-"));
    const packageDirectory = new URL("..", import.meta.url);
    try {
      cpSync(new URL("../drizzle/postgres-agent/", import.meta.url), directory, { recursive: true });
      const migrations = readdirSync(directory).toSorted();
      const generated = spawnSync("pnpm", [
        "exec", "drizzle-kit", "generate", "--dialect", "postgresql",
        "--schema", "./src/db/postgres-agent-schema.ts", "--out", directory, "--name", "schema-drift",
      ], { cwd: packageDirectory, encoding: "utf8" });
      expect(generated.status, generated.stderr || generated.stdout).toBe(0);
      expect(readdirSync(directory).toSorted()).toEqual(migrations);
    } finally {
      rmSync(directory, { force: true, recursive: true });
    }
  });
});
