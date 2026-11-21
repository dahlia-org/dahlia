import assert from "node:assert/strict";
import { test } from "node:test";
import { registerLearn } from "../Sources/Dahlia/PiExtension/pi-hermes-skills/learn.ts";

test("/learn keeps the request verbatim and defaults to the current conversation", () => {
  let hook;
  registerLearn({ on: (name, handler) => { assert.equal(name, "input"); hook = handler; } });
  const notes = 'docs/api.md  focus on "auth"\n- skip v1 $1 ${@}';
  const expanded = hook({ text: `/learn ${notes}` }).text;
  assert.ok(expanded.startsWith("[/learn]"));
  assert.ok(expanded.includes(`THE REQUEST:\n${notes}\n`));
  assert.ok(!expanded.includes("${@:-"));
  assert.ok(hook({ text: "/learn" }).text.includes("THE REQUEST:\nthe workflow we just went through in this conversation"));
  assert.equal(hook({ text: "/learnings" }), undefined);
  assert.equal(hook({ text: "please /learn this" }), undefined);
});
