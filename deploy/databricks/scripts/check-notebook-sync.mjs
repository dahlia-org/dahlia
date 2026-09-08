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
  uploads.includes("deploy/databricks/notebooks/create_otel_tables.sql"),
  "The OTel notebook must be included in bundle sync uploads",
);
console.log("OTel notebook is included in bundle sync uploads.");
