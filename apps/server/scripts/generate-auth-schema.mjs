import { spawnSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const projectDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const cli = resolve(projectDirectory, "node_modules/.bin/auth");
const config = resolve(projectDirectory, "scripts/better-auth-schema.config.ts");

for (const [dialect, output] of [
  ["postgresql", "src/db/generated/postgres-auth-schema.ts"],
  ["sqlite", "src/db/generated/sqlite-auth-schema.ts"],
]) {
  const file = resolve(process.cwd(), output);
  const generated = spawnSync(cli, [
    "generate",
    "--adapter", "drizzle",
    "--dialect", dialect,
    "--config", config,
    "--output", file,
    "--yes",
  ], { cwd: projectDirectory, encoding: "utf8" });
  if (generated.status !== 0) throw new Error(generated.stderr || generated.stdout);

  const source = await readFile(file, "utf8");
  await writeFile(file, source
    .replace('import { relations } from "drizzle-orm";\n', "")
    .replace('import { relations, sql } from "drizzle-orm";', 'import { sql } from "drizzle-orm";')
    .replace('import { defineRelationsPart } from "drizzle-orm";\n', "")
    .replace('import { defineRelationsPart, sql } from "drizzle-orm";', 'import { sql } from "drizzle-orm";')
    .replace(/\n\nexport const \w+Relations = relations[\s\S]*$/, "\n")
    .replace(/\n\nexport const authRelations[\s\S]*$/, "\n"));
}
