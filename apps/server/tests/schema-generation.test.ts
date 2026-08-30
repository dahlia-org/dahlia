import { cpSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

import { describe, expect, it } from "vitest";

describe("auth schema generation", () => {
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

  it("keeps the committed SQLite migration history synchronized with the declarative schema", () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-sqlite-schema-"));
    const packageDirectory = new URL("..", import.meta.url);
    try {
      cpSync(new URL("../drizzle/sqlite/", import.meta.url), directory, { recursive: true });
      const migrations = readdirSync(directory).toSorted();
      const generated = spawnSync("pnpm", [
        "exec", "drizzle-kit", "generate",
        "--dialect", "sqlite",
        "--schema", "./src/db/sqlite-schema.ts",
        "--out", directory,
        "--name", "schema-drift",
      ], { cwd: packageDirectory, encoding: "utf8" });
      expect(generated.status, generated.stderr || generated.stdout).toBe(0);
      expect(readdirSync(directory).toSorted()).toEqual(migrations);
    } finally {
      rmSync(directory, { force: true, recursive: true });
    }
  });
});
