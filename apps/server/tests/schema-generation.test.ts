import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
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

  it("reproduces the committed SQLite baseline from the declarative schema", () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-sqlite-schema-"));
    const packageDirectory = new URL("..", import.meta.url);
    try {
      const generated = spawnSync("pnpm", [
        "exec", "drizzle-kit", "generate",
        "--dialect", "sqlite",
        "--schema", "./src/db/sqlite-schema.ts",
        "--out", directory,
        "--name", "baseline",
      ], { cwd: packageDirectory, encoding: "utf8" });
      expect(generated.status, generated.stderr || generated.stdout).toBe(0);
      const migrationDirectory = readdirSync(directory, { withFileTypes: true })
        .find((entry) => entry.isDirectory())?.name;
      if (!migrationDirectory) throw new Error("Drizzle Kit did not create a migration directory");
      expect(readFileSync(join(directory, migrationDirectory, "migration.sql"), "utf8"))
        .toBe(readFileSync(
          new URL("../drizzle/sqlite/20260830001528_stiff_alex_power/migration.sql", import.meta.url),
          "utf8",
        ));
    } finally {
      rmSync(directory, { force: true, recursive: true });
    }
  });
});
