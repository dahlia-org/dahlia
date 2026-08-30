import { mkdtempSync, readFileSync, rmSync } from "node:fs";
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
});
