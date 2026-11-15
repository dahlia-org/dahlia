import assert from "node:assert/strict";
import { test } from "node:test";
import { registerThreadTools, threadTools } from "../Sources/Dahlia/PiExtension/thread-tools.ts";

test("thread tools forward only their registered method and original parameters", async () => {
  const registered = [];
  const calls = [];
  registerThreadTools({ registerTool: (tool) => registered.push(tool) }, async (...args) => { calls.push(args); return { ok: true }; });
  assert.equal(registered.length, 8);
  for (const tool of registered) {
    const params = { input: "hello", thread_id: "other" };
    const context = {};
    const result = await tool.execute("call", params, undefined, undefined, context);
    assert.deepEqual(calls.at(-1), [context, tool.name.replace("dahlia_", ""), params]);
    assert.deepEqual(JSON.parse(result.content[0].text), { ok: true });
    assert.equal(tool.parameters.additionalProperties, false);
  }
  assert.equal(threadTools.some((t) => /delete|approve/.test(t.name)), false);
});
