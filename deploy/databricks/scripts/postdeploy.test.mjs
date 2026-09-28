import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import assert from "node:assert/strict";
import { it } from "node:test";

it("only enables search extensions and preserves failures", () => {
  const dir = mkdtempSync(join(tmpdir(), "dahlia-postdeploy-"));
  const script = fileURLToPath(new URL("./postdeploy.sh", import.meta.url));
  const calls = join(dir, "calls.jsonl");
  writeFileSync(join(dir, "databricks"), `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.CALLS, JSON.stringify({ args }) + "\\n");
if (process.env.FAIL === args[1]) {
  console.error("PERMISSION_DENIED: " + args[1]);
  process.exit(1);
}
`, { mode: 0o755 });
  const run = (fail = "") => {
    writeFileSync(calls, "");
    return spawnSync("bash", [script, "test-profile", "test-project"], {
      encoding: "utf8",
      env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, CALLS: calls, FAIL: fail },
    });
  };
  const readCalls = () => readFileSync(calls, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  try {
    const enabled = run();
    assert.equal(enabled.status, 0, enabled.stderr);
    const recorded = readCalls();
    assert.equal(recorded.length, 1);
    assert.deepEqual(recorded[0].args, ["api", "post",
      "/api/2.0/postgres/projects/test-project/search-extensions", "--json", "{}", "--profile", "test-profile"]);
    const denied = run("post");
    assert.equal(denied.status, 1);
    assert.match(denied.stderr, /PERMISSION_DENIED/);
    assert.equal(readCalls().length, 1);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
