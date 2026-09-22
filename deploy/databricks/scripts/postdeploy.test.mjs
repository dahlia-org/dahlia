import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import assert from "node:assert/strict";
import { it } from "node:test";

it("enables search extensions, grants Server access to Hindsight, and preserves failures", () => {
  const dir = mkdtempSync(join(tmpdir(), "dahlia-postdeploy-"));
  const script = fileURLToPath(new URL("./postdeploy.sh", import.meta.url));
  const calls = join(dir, "calls.jsonl");
  writeFileSync(join(dir, "databricks"), `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
const acl = args[1] === "update-permissions" ? JSON.parse(fs.readFileSync(args[args.indexOf("--json") + 1].slice(1), "utf8")) : null;
fs.appendFileSync(process.env.CALLS, JSON.stringify({ args, acl }) + "\\n");
if (process.env.FAIL === args[1]) {
  console.error("PERMISSION_DENIED: " + args[1]);
  process.exit(1);
}
if (args[0] === "apps" && args[1] === "get") console.log(JSON.stringify({ service_principal_client_id: "server-sp" }));
`, { mode: 0o755 });
  const run = (fail = "") => {
    writeFileSync(calls, "");
    return spawnSync("bash", [script, "test-profile", "test-project", "test-server", "test-hindsight"], {
      encoding: "utf8",
      env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, CALLS: calls, FAIL: fail },
    });
  };
  const readCalls = () => readFileSync(calls, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  try {
    const enabled = run();
    assert.equal(enabled.status, 0, enabled.stderr);
    const recorded = readCalls();
    assert.equal(recorded.length, 3);
    assert.deepEqual(recorded[0].args, ["api", "post",
      "/api/2.0/postgres/projects/test-project/search-extensions", "--json", "{}", "--profile", "test-profile"]);
    assert.deepEqual(recorded[1].args, ["apps", "get", "test-server", "--profile", "test-profile", "--output", "json"]);
    assert.deepEqual(recorded[2].args.slice(0, 4), ["apps", "update-permissions", "test-hindsight", "--json"]);
    assert.deepEqual(recorded[2].args.slice(5), ["--profile", "test-profile"]);
    assert.deepEqual(recorded[2].acl, { access_control_list: [{ service_principal_name: "server-sp", permission_level: "CAN_USE" }] });
    for (const [failure, count] of [["post", 1], ["get", 2], ["update-permissions", 3]]) {
      const denied = run(failure);
      assert.equal(denied.status, 1);
      assert.match(denied.stderr, /PERMISSION_DENIED/);
      assert.equal(readCalls().length, count);
    }
    const hindsightResource = readFileSync(new URL("../resources/hindsight.app.yml", import.meta.url), "utf8");
    assert.match(hindsightResource, /name: dahlia-hindsight-\$\{bundle\.target\}/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
