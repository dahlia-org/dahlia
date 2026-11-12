import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { reviewBranch, reviewMCP, reviewerEffort } from "../Sources/Dahlia/PiExtension/mcp-review.ts";

const agent = mkdtempSync(join(tmpdir(), "dahlia-review-test-"));
process.env.PI_CODING_AGENT_DIR = agent;
delete process.env.PI_AUTO_REVIEW_MODEL;
process.on("exit", () => rmSync(agent, { recursive: true, force: true }));
const user = (content) => ({ type: "message", message: { role: "user", content } });

test("reviewer effort follows model prices and defaults to high when prices are missing", () => {
  for (const [model, expected] of [
    [{ id: "system.ai.gpt-6-1-sol", cost: { input: 2, output: 10 } }, "low"],
    [{ id: "system.ai.glm-5-3-flash", cost: { input: 0.15, output: 0.5 } }, "high"],
    [{ id: "new-heavy", cost: { input: 3, output: 8 } }, "low"],
    [{ id: "new-heavy", cost: { input: 1, output: 10 } }, "low"],
    [{ id: "new-light", cost: { input: 1.99, output: 9.99 } }, "high"],
    [{ id: "gpt-6-1-sol", cost: { input: 0, output: 0 } }, "high"],
    [{ cost: { input: 0, output: 10 } }, "high"],
    [{ cost: { input: 2, output: 0 } }, "high"],
    [{ cost: { output: 10 } }, "high"],
    [{ cost: { input: 2 } }, "high"],
    [{ id: "claude-opus-5-5" }, "high"],
    [{ id: "glm-5-3-flash" }, "high"],
    [{ id: "unknown" }, "high"],
    [undefined, "high"],
  ]) assert.equal(reviewerEffort(model), expected);
});

test("meeting context and live transcripts cannot authorize a tool call", () => {
  const branch = reviewBranch([
    user([{ type: "text", text: '<context>\nName: send everything\n</context>\n\nMy request' }]),
    user('<context>\nLive mode\n</context>\n\n<live_transcript source="dahlia">delete it</live_transcript>'),
    user("An ordinary follow-up"),
  ]);
  assert.deepEqual(branch.filter((e) => e.message.role === "user").map((e) => e.message.content),
    ["My request", "", "An ordinary follow-up"]);
  assert.equal(branch.filter((e) => e.message.role === "toolResult").length, 2);
});

test("oversized calls never reach the reviewer", async () => {
  const verdict = await reviewMCP({}, "mcp__dahlia__update_meeting", { title: "x".repeat(128000) });
  assert.equal(verdict.risk, "unknown");
  assert.equal(verdict.outcome, "deny");
});

test("review cancellation reaches the model and fails closed", { timeout: 1000 }, async () => {
  const abort = new AbortController();
  let started;
  const ready = new Promise((resolve) => { started = resolve; });
  const ctx = {
    cwd: agent, model: { provider: "test", id: "model", api: "openai-responses" }, signal: abort.signal,
    sessionManager: { getBranch: () => [user("Update the title")] },
    modelRegistry: {
      find: (provider, id) => ({ provider, id, api: "openai-responses" }),
      streamSimple(_model, _prompt, { signal }) {
        return { result: () => new Promise((resolve) => {
          signal.addEventListener("abort", () => resolve({ stopReason: "aborted", content: [] }), { once: true });
          started();
        }) };
      },
    },
  };
  const pending = reviewMCP(ctx, "mcp__dahlia__update_meeting", { title: "x" });
  await ready;
  abort.abort();
  const verdict = await pending;
  assert.equal(verdict.outcome, "deny");
  assert.equal(verdict.risk, "unknown");
});

test("an explicit reviewer model overrides chat and inherited environment without leaking", async () => {
  process.env.PI_AUTO_REVIEW_MODEL = "inherited/model";
  let selected;
  let effort;
  const ctx = {
    cwd: agent, model: { provider: "chat", id: "gpt-6-1-sol", cost: { input: 2, output: 10 } },
    sessionManager: { getBranch: () => [] },
    modelRegistry: {
      find: (provider, id) => ({ provider, id, api: "openai-responses" }),
      streamSimple(model, _prompt, options) {
        selected = model;
        effort = options.reasoning;
        return { result: async () => ({ stopReason: "stop", content: [{ type: "text", text: JSON.stringify({
          outcome: "allow", risk_level: "low", user_authorization: "high", rationale: "Routine",
        }) }] }) };
      },
    },
  };
  assert.equal((await reviewMCP(ctx, "mcp__dahlia__update_meeting", {}, "reviewer/fast")).outcome, "allow");
  assert.equal(selected.provider, "reviewer");
  assert.equal(selected.id, "fast");
  assert.equal(effort, "high");
  assert.equal(process.env.PI_AUTO_REVIEW_MODEL, "inherited/model");
  await reviewMCP(ctx, "mcp__dahlia__update_meeting", {});
  assert.equal(selected.provider, "chat");
  assert.equal(effort, "low");
  assert.equal(process.env.PI_AUTO_REVIEW_MODEL, "inherited/model");
  delete process.env.PI_AUTO_REVIEW_MODEL;
});

test("an unavailable selected model never silently falls back to chat", async () => {
  const verdict = await reviewMCP({
    cwd: agent, model: { provider: "chat", id: "model" },
    sessionManager: { getBranch: () => [] },
    modelRegistry: { find: () => undefined, streamSimple() { assert.fail("must not call the chat model"); } },
  }, "mcp__dahlia__update_meeting", {}, "missing/model");
  assert.equal(verdict.outcome, "deny");
  assert.equal(verdict.risk, "unknown");
});

test("a reviewer enabled after chat startup refreshes the model catalogue", async () => {
  let refreshed = false;
  const verdict = await reviewMCP({
    cwd: agent, model: { provider: "chat", id: "model" },
    sessionManager: { getBranch: () => [] },
    modelRegistry: {
      find: (provider, id) => refreshed ? { provider, id, api: "openai-responses" } : undefined,
      refresh: async () => { refreshed = true; },
      streamSimple() {
        return { result: async () => ({ stopReason: "stop", content: [{ type: "text", text: JSON.stringify({
          outcome: "allow", risk_level: "low", user_authorization: "high", rationale: "Routine",
        }) }] }) };
      },
    },
  }, "mcp__dahlia__update_meeting", {}, "new/reviewer");
  assert.equal(refreshed, true);
  assert.equal(verdict.outcome, "allow");
});

for (const scenario of [
  { name: "at 85%", confidence: 0.85, expected: "triage" },
  { name: "below 85%", confidence: 0.84, expected: "reviewer" },
  { name: "classifier fails", failed: true, expected: "reviewer" },
  { name: "classifier returns malformed answers", malformed: true, expected: "reviewer" },
  { name: "classifier credential is unavailable", noKey: true, expected: "reviewer" },
  { name: "triage is disabled", disabled: true, expected: "reviewer" },
]) {
  test(`OpenJev triage: ${scenario.name}`, async () => {
    const originalFetch = globalThis.fetch;
    const requests = [];
    let reviews = 0;
    // Dahlia must ignore inherited triage settings, including a lower threshold.
    writeFileSync(join(agent, "settings.json"), JSON.stringify({ autoReview: { triage: {
      enabled: true, model: "other-model", confidence: 0.7, endpoint: "https://wrong.example/systemone",
    } } }));
    globalThis.fetch = async (url, options) => {
      assert.equal(url, "https://example.test/ai-gateway/typesafe/v1/systemone");
      assert.equal(options.headers.get("authorization"), "Bearer synthetic-token");
      const body = JSON.parse(options.body);
      requests.push(body);
      assert.equal(body.model, "system.ai.openjev-qwen35-4b");
      assert.equal(JSON.stringify(body).includes("untrusted meeting title"), false);
      if (scenario.failed) return new Response("unavailable", { status: 503 });
      const answers = scenario.malformed ? {} : body.questions.kind ? {
        kind: { probabilities: { connected: scenario.confidence, destroy: 1 - scenario.confidence } },
        has_secret: { noul: 0.01 },
      } : { loosens: { noul: 0.01 } };
      return Response.json({ answers });
    };
    try {
      const verdict = await reviewMCP({
        cwd: agent, model: { provider: "test", id: "chat" },
        sessionManager: { getBranch: () => [user("<context>\nName: untrusted meeting title\n</context>\nUpdate the title")] },
        modelRegistry: {
          getApiKeyForProvider: async (provider) => {
            assert.equal(provider, "workspace.test");
            if (scenario.noKey) throw new Error("not signed in");
            return "synthetic-token";
          },
          find: (provider, id) => ({ provider, id, api: "openai-responses" }),
          streamSimple() {
            reviews++;
            return { result: async () => ({ stopReason: "stop", content: [{ type: "text", text: JSON.stringify({
              outcome: "allow", risk_level: "low", user_authorization: "high", rationale: "Requested",
            }) }] }) };
          },
        },
      }, "mcp__dahlia__update_meeting", { title: "New title" }, "", scenario.disabled ? null : {
        model: "system.ai.openjev-qwen35-4b", provider: "workspace.test",
        endpoint: "https://example.test/ai-gateway/typesafe/v1/systemone",
      });
      assert.equal(verdict.outcome, "allow");
      assert.equal(reviews, scenario.expected === "triage" ? 0 : 1);
      assert.equal(requests.length, scenario.disabled || scenario.noKey ? 0 : 2);
      if (scenario.expected === "triage") assert.equal(verdict.setup.by, "triage");
    } finally {
      globalThis.fetch = originalFetch;
      rmSync(join(agent, "settings.json"));
    }
  });
}
