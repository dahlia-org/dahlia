import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import assert from "node:assert/strict";
import { it } from "node:test";

it("activates search extensions without registering model services", () => {
  const dir = mkdtempSync(join(tmpdir(), "dahlia-postdeploy-"));
  const script = fileURLToPath(new URL("./postdeploy.sh", import.meta.url));
  const calls = join(dir, "calls.jsonl");
  writeFileSync(calls, "");
  writeFileSync(join(dir, "databricks"), `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.CALLS, JSON.stringify(args) + "\\n");
if (args[0] === process.env.FAIL_COMMAND) {
  console.error("PERMISSION_DENIED");
  process.exit(1);
}
const command = args[1];
if (args[0] === "apps" && command === "get") {
  const principals = {
    "mcp-dahlia-server-test": "dahlia-app-sp",
    "hindsight-test": "hindsight-app-sp",
  };
  console.log(JSON.stringify({service_principal_client_id: principals[args[2]]}));
} else {
  console.log("{}");
}
`, { mode: 0o755 });
  const run = (failCommand = "", dahliaAppName = "mcp-dahlia-server-test", hindsightAppName = "hindsight-test") => spawnSync("bash", [
    script,
    "test-profile",
    "test_catalog",
    "test-project",
    dahliaAppName,
    hindsightAppName,
  ], {
    encoding: "utf8",
    env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, CALLS: calls, FAIL_COMMAND: failCommand },
  });
  const readCalls = () => readFileSync(calls, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
  try {
    const result = run();
    assert.equal(result.status, 0, result.stderr);
    const callsMade = readCalls();
    const catalogGrant = callsMade.find((args) => args[0] === "grants" && args[1] === "update");
    assert.deepEqual(JSON.parse(catalogGrant[catalogGrant.indexOf("--json") + 1]).changes, [
      { principal: "account users", add: ["USE_CATALOG"] },
      { principal: "dahlia-app-sp", add: ["USE_CATALOG"] },
      { principal: "hindsight-app-sp", add: ["USE_CATALOG"] },
    ]);
    assert.ok(callsMade.some((args) => args[0] === "api" && args[1] === "post"
      && args[2] === "/api/2.0/postgres/projects/test-project/search-extensions"));
    assert.equal(callsMade.some((args) => args.includes("ai-gateway")), false);
    assert.ok(callsMade.every((args) => args[args.indexOf("--profile") + 1] === "test-profile"));

    writeFileSync(calls, "");
    const denied = run("grants");
    assert.equal(denied.status, 1);
    assert.match(denied.stderr, /PERMISSION_DENIED/);
    assert.equal(readCalls().some((args) => args[0] === "api"), false);

    writeFileSync(calls, "");
    const missingPrincipal = run("", "missing-dahlia-app");
    assert.notEqual(missingPrincipal.status, 0);
    assert.match(missingPrincipal.stderr, /App service principal not found for app 'missing-dahlia-app'/);
    assert.equal(readCalls().some((args) => args[0] === "grants" && args[1] === "update"), false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
