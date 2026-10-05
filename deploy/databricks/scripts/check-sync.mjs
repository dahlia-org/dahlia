import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

// Exercise the CLI's actual sync selection without uploading workspace files.
const output = execFileSync(
  "databricks",
  ["bundle", "sync", "--dry-run", "--full", "--output", "json", ...process.argv.slice(2)],
  { cwd: fileURLToPath(new URL("..", import.meta.url)), encoding: "utf8" },
);
const events = output.trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
const uploads = events.filter((event) => event.type === "start").flatMap((event) => event.put ?? []);
assert.ok(
  uploads.includes("deploy/databricks/notebooks/create_otel_tables.py"),
  "The OTel notebook must be included in bundle sync uploads",
);
// The Server App deploys the repository root; it receives the workspace manifests, Server and shared UI only.
for (const file of ["package.json", "pnpm-workspace.yaml", "pnpm-lock.yaml", "turbo.json", "apps/server/package.json", "packages/ui/package.json"]) {
  assert.ok(uploads.includes(file), `${file} must be included in bundle sync uploads`);
}
const unrelated = uploads.filter((file) => !/^(?:package\.json|pnpm-workspace\.yaml|pnpm-lock\.yaml|turbo\.json|apps\/(?:server|hindsight)\/|packages\/ui\/|deploy\/databricks\/notebooks\/)/.test(file));
assert.deepEqual(unrelated, [], "Bundle sync must not upload files outside the Server workspace, Hindsight and notebooks");
console.log("Bundle sync uploads the OTel notebook and only the Server workspace, Hindsight and notebook files.");
