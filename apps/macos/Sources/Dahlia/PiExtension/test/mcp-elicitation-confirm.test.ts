import assert from "node:assert/strict";
import { test } from "node:test";
import { confirmInHost } from "../mcp-elicitation-confirm.ts";

test("host confirmation correlates cancellation and waits for native cleanup", async () => {
  const requests: any[] = [];
  let answer: (value: string) => void = () => {};
  let acknowledge: () => void = () => {};
  const ctx = { hasUI: true, ui: { input: (title: string, raw: string) => {
    requests.push({ title, ...JSON.parse(raw) });
    return title === "dahlia:confirmation"
      ? new Promise<string>((resolve) => { answer = resolve; })
      : new Promise<void>((resolve) => { acknowledge = resolve; });
  } } };
  const controller = new AbortController();
  let settled = false;
  const result = confirmInHost(ctx, "Open page?", "https://example.com", controller.signal).then((value) => { settled = true; return value; });
  controller.abort();
  assert.equal(requests.length, 2);
  assert.equal(requests[0].requestID, requests[1].requestID);
  assert.equal(requests[1].title, "dahlia:cancelConfirmation");
  answer(JSON.stringify("accept"));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(settled, false);
  acknowledge();
  assert.equal(await result, false);
});

test("normal consent has no cancel and an already cancelled prompt never opens", async () => {
  const requests: any[] = [];
  const ctx = { hasUI: true, ui: { input: async (title: string, raw: string) => {
    requests.push({ title, ...JSON.parse(raw) });
    return JSON.stringify("accept");
  } } };
  assert.equal(await confirmInHost(ctx, "Confirm", "message"), true);
  assert.equal(requests.length, 1);
  assert.equal(await confirmInHost(ctx, "Cancelled", "message", AbortSignal.abort()), false);
  assert.equal(await confirmInHost({ hasUI: false }, "Headless", "message"), false);
  assert.equal(requests.length, 1);
});
