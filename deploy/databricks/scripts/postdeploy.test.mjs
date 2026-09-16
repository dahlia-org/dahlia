import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import assert from "node:assert/strict";
import { it } from "node:test";

it("enables only Lakebase search extensions and preserves failure diagnostics", () => {
  const dir = mkdtempSync(join(tmpdir(), "dahlia-postdeploy-"));
  const script = fileURLToPath(new URL("./postdeploy.sh", import.meta.url));
  const calls = join(dir, "calls.jsonl");
  writeFileSync(calls, "");
  writeFileSync(join(dir, "databricks"), `#!/usr/bin/env node
const fs = require("node:fs");
fs.appendFileSync(process.env.CALLS, JSON.stringify(process.argv.slice(2)) + "\\n");
if (process.env.FAIL) {
  console.error("PERMISSION_DENIED: cannot enable search extensions");
  process.exit(1);
}
`, { mode: 0o755 });
  const run = (fail = "") => spawnSync("bash", [script, "test-profile", "test-project"], {
    encoding: "utf8",
    env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, CALLS: calls, FAIL: fail },
  });
  try {
    const enabled = run();
    assert.equal(enabled.status, 0, enabled.stderr);
    assert.deepEqual(JSON.parse(readFileSync(calls, "utf8")), [
      "api",
      "post",
      "/api/2.0/postgres/projects/test-project/search-extensions",
      "--json",
      "{}",
      "--profile",
      "test-profile",
    ]);

    const denied = run("1");
    assert.equal(denied.status, 1);
    assert.match(denied.stderr, /PERMISSION_DENIED/);

    const hindsightResource = readFileSync(new URL("../resources/hindsight.app.yml", import.meta.url), "utf8");
    assert.match(hindsightResource, /name: dahlia-hindsight-\$\{bundle\.target\}/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
