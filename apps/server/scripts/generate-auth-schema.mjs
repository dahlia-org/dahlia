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
}
