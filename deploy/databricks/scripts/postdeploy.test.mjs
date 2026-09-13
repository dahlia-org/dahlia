import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import assert from "node:assert/strict";
import { it } from "node:test";

it("registers missing models, resumes partial deployments, and preserves failure diagnostics", () => {
  const dir = mkdtempSync(join(tmpdir(), "dahlia-postdeploy-"));
  const script = fileURLToPath(new URL("./postdeploy.sh", import.meta.url));
  const state = join(dir, "state.json");
  const calls = join(dir, "calls.jsonl");
  writeFileSync(state, "[]");
  writeFileSync(calls, "");
  writeFileSync(join(dir, "databricks"), `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.CALLS, JSON.stringify(args) + "\\n");
const names = JSON.parse(fs.readFileSync(process.env.STATE, "utf8"));
const command = args[1];
if (command === process.env.FAIL_COMMAND && (!process.env.FAIL_MODEL || args[3] === process.env.FAIL_MODEL)) {
  console.error("PERMISSION_DENIED: missing CREATE_SERVICE");
  process.exit(1);
}
if (command === "list-model-services") {
  console.log(JSON.stringify(names.map(name => ({name}))));
} else if (command === "get-model-service") {
  const model = args[2].replace("model-services/", "models/");
  console.log(JSON.stringify({config: {routing: {destinations: [{
    destination_type: "DESTINATION_TYPE_PAY_PER_TOKEN_FOUNDATION_MODEL",
    pay_per_token_config: {model}
  }]}}}));
} else if (command === "create-model-service") {
  const name = "model-services/" + args[2].replace("schemas/", "") + "." + args[3];
  if (names.includes(name)) {
    console.error("ALREADY_EXISTS");
    process.exit(1);
  }
  names.push(name);
  fs.writeFileSync(process.env.STATE, JSON.stringify(names));
  console.log("{}");
} else {
  console.log("{}");
}
`, { mode: 0o755 });
  const run = (failCommand = "", failModel = "") => spawnSync("bash", [script, "test-profile", "test_catalog", "ai", "test-project"], {
    encoding: "utf8",
    env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, STATE: state, CALLS: calls, FAIL_COMMAND: failCommand, FAIL_MODEL: failModel },
  });
  const readCalls = () => readFileSync(calls, "utf8").trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
  try {
    const partial = run("create-model-service", "gpt-6-astra");
    assert.equal(partial.status, 1);
    assert.match(partial.stderr, /PERMISSION_DENIED/);
    assert.match(partial.stdout, /test_catalog.ai.gpt-6-astra/);
    assert.equal(JSON.parse(readFileSync(state, "utf8")).length, 1);

    const legacyEmbedding = "model-services/test_catalog.ai.embedding";
    writeFileSync(state, JSON.stringify([...JSON.parse(readFileSync(state, "utf8")), legacyEmbedding]));
    const resumed = run();
    assert.equal(resumed.status, 0, resumed.stderr);
    assert.match(resumed.stdout, /Keeping existing model service: model-services\/test_catalog.ai.gpt-5-6-luna/);
    assert.equal(JSON.parse(readFileSync(state, "utf8")).length, 14);
    for (const [name, source] of [
      ["deepseek-v4-1-flash", "deepseek-v4-1-flash"],
      ["deepseek-v4-pro-0813", "deepseek-v4-pro-0813"],
      ["glm-5-3-flash", "glm-5-3-flash"],
      ["glm-5-3", "glm-5-3"],
      ["gemini-3-8-flash", "gemini-3-8-flash"],
      ["gemini-3-7-flash", "gemini-3-7-flash"],
      ["qwen3-embedding-0-6b", "qwen3-embedding-0-6b"],
      ["codex-auto-review", "gpt-5-6-luna"],
    ]) {
      const call = readCalls().find(args => args[1] === "create-model-service" && args[3] === name);
      const config = JSON.parse(call[call.indexOf("--json") + 1]);
      assert.equal(config.config.routing.destinations[0].pay_per_token_config.model, `models/system.ai.${source}`);
    }
    assert.equal(readCalls().some(args => args[1] === "create-model-service" && args[3] === "deepseek-v4-pro"), false);
    assert.ok(JSON.parse(readFileSync(state, "utf8")).includes(legacyEmbedding));
    assert.equal(readCalls().some(args => args[1] === "create-model-service" && args[3] === "embedding"), false);
    const resource = readFileSync(new URL("../resources/dahlia_server.yml", import.meta.url), "utf8");
    assert.match(resource, /name: DAHLIA_EMBEDDING_MODEL\s+value: \$\{var.catalog\}\.\$\{var.ai_schema\}\.qwen3-embedding-0-6b/);
    assert.ok(readCalls().every(args => args[args.indexOf("--profile") + 1] === "test-profile"));

    writeFileSync(calls, "");
    const repeated = run();
    assert.equal(repeated.status, 0, repeated.stderr);
    assert.equal(readCalls().some(args => ["create-model-service", "get-model-service"].includes(args[1])), false);

    writeFileSync(calls, "");
    const denied = run("list-model-services");
    assert.notEqual(denied.status, 0);
    assert.match(denied.stderr, /PERMISSION_DENIED/);
    assert.equal(readCalls().some(args => args[1] === "create-model-service"), false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
