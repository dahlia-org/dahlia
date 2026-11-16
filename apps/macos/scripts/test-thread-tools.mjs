import assert from "node:assert/strict";
import { test } from "node:test";
import { omnigentTools, registerThreadTools, threadTools } from "../Sources/Dahlia/PiExtension/thread-tools.ts";

test("thread tools forward only their registered method and original parameters", async () => {
  const registered = [];
  const calls = [];
  registerThreadTools({ registerTool: (tool) => registered.push(tool) }, async (...args) => { calls.push(args); return { ok: true }; });
  assert.equal(registered.length, 8);
  assert.ok(registered.every((tool) => tool.name.startsWith("dah_thread_")));
  for (const tool of registered) {
    const params = { input: "hello", thread_id: "other" };
    const context = {};
    const result = await tool.execute("call", params, undefined, undefined, context);
    assert.deepEqual(calls.at(-1), [context, tool.name.replace("dah_", ""), params]);
    assert.deepEqual(JSON.parse(result.content[0].text), { ok: true });
    assert.equal(tool.parameters.additionalProperties, false);
  }
  assert.equal(threadTools.some((t) => /delete|approve/.test(t.name)), false);
});

test("omnigent tools forward to their same-named bridge methods", async () => {
  const registered = [];
  const calls = [];
  registerThreadTools({ registerTool: (tool) => registered.push(tool) }, async (...args) => { calls.push(args); return { ok: true }; }, omnigentTools);
  assert.deepEqual(registered.map((tool) => tool.name), ["omni_list_agents", "omni_list_sessions", "omni_create_session", "omni_get_session"]);
  for (const tool of registered) {
    await tool.execute("call", {}, undefined, undefined, {});
    assert.equal(calls.at(-1)[1], tool.name.replace("dah_", ""));
    assert.equal(tool.parameters.additionalProperties, false);
  }
});
