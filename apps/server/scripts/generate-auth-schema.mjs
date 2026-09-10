import { readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const projectDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const cli = resolve(projectDirectory, "node_modules/.bin/auth");
const config = resolve(projectDirectory, "scripts/better-auth-schema.config.ts");

for (const [provider, output] of [
  ["pg", "src/db/generated/postgres-auth-schema.ts"],
  ["sqlite", "src/db/generated/sqlite-auth-schema.ts"],
]) {
  const file = resolve(process.cwd(), output);
  const generated = spawnSync(cli, [
    "generate",
    "--config", config,
    "--output", file,
    "--yes",
  ], {
    cwd: projectDirectory,
    encoding: "utf8",
    env: { ...process.env, DAHLIA_AUTH_SCHEMA_PROVIDER: provider },
  });
  if (generated.status !== 0) throw new Error(generated.stderr || generated.stdout);
  if (provider === "pg") {
    // Better Auth 1.7 emits a UUIDv4 default for generateId: "uuid". Runtime always supplies UUIDv7.
    const source = readFileSync(file, "utf8").replace(/\s*\.default\(sql`pg_catalog\.gen_random_uuid\(\)`\)/g, "")
      .replace('import { sql } from "drizzle-orm";\n', "")
      .replace('{ defineRelationsPart, sql }', '{ defineRelationsPart }')
      .replace(/uuid\("id"\)\s*\.primaryKey\(\)/g, 'uuid("id").primaryKey()')
      // Better Auth models these nullable session entity references as text even with UUID IDs.
      .replace(/(impersonatedBy|activeOrganizationId|activeTeamId): text\(("[^"]+")\)/g, '$1: uuid($2)')
      // OAuth assertion replay IDs are protocol-owned hashes supplied with forceAllowId.
      .replace(/(oauthClientAssertion = authSchema.table\("oauth_client_assertion", \{\s*id: )uuid\("id"\)/, '$1text("id")');
    writeFileSync(file, source);
  }
}
