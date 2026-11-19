import assert from "node:assert/strict";
import { test } from "node:test";
import {
  constraints, evolve, isRelevantToSkill, parseObject, parseProposal, parseScore, registerSkillOptimizer, reflectionPrompt, selectFromPareto, splitSkill,
} from "../Sources/Dahlia/PiExtension/skill-evolution.ts";

const field = (name, value) => `[[ ## reasoning ## ]]\nok\n\n[[ ## ${name} ## ]]\n${value}\n\n[[ ## completed ## ]]`;

// A model for which the skill improves once it asks for a checklist.
function fakeContext(calls) {
  const answer = (systemPrompt, text) => {
    if (!systemPrompt) return "Here you go:\n```markdown\nReview the change. Always end with a CHECKLIST.\n```";
    if (text.includes("[[ ## user_message ## ]]")) {
      return field("scoring", JSON.stringify({ relevant: true, expected_behavior: "Ends with a checklist", difficulty: "Hard", category: "review" }));
    }
    if (text.includes("[[ ## artifact_text ## ]]")) {
      return field("test_cases", JSON.stringify(Array.from({ length: 12 }, (_, i) => ({ task_input: `Review change ${i}`, expected_behavior: "Ends with a checklist" }))));
    }
    if (text.includes("[[ ## agent_output ## ]]")) {
      const good = text.includes("- [ ]");
      return `[[ ## reasoning ## ]]\n.\n\n[[ ## correctness ## ]]\n${good ? 1 : 0.2}\n\n[[ ## procedure_following ## ]]\n${good ? 1 : 0.2}\n\n`
        + `[[ ## conciseness ## ]]\nnot a number\n\n[[ ## feedback ## ]]\n${good ? "Good." : "Add a checklist."}\n\n[[ ## completed ## ]]`;
    }
    return field("output", text.includes("CHECKLIST") ? "Looks fine.\n- [ ] tests" : "Looks fine.");
  };
  return {
    model: { id: "fake" },
    modelRegistry: {
      streamSimple: (_model, prompt) => {
        calls.push(prompt);
        return { result: async () => ({ stopReason: "stop", content: [{ type: "text", text: answer(prompt.systemPrompt, prompt.messages[0].content[0].text) }] }) };
      },
    },
  };
}

test("evolve mines conversations, tops up with synthetic cases and keeps an improving candidate", async () => {
  const calls = [];
  const raw = "---\nname: code-review\ndescription: Review code --- and +++ diff headers.\n---\n\nReview the change carefully and explain every issue you find in detail.\n";
  const messages = [
    { task_input: "Please do a code review of my diff", assistant_response: "Done" },
    { task_input: "short" },
    { task_input: "Here is my key sk-ant-api0123456789 please review", assistant_response: "" },
  ];
  const result = await evolve(fakeContext(calls), { name: "code-review", raw, messages, iterations: 3 });
  assert.equal(result.examples.mined, 1);
  assert.equal(result.examples.synthetic, 12);
  assert.equal(result.changed, true);
  assert.ok(result.improvement > 0);
  assert.equal(result.skill, "---\nname: code-review\ndescription: Review code --- and +++ diff headers.\n---\n\nReview the change. Always end with a CHECKLIST.\n");
  // Secrets and short messages never reach the model.
  assert.ok(calls.every((prompt) => !JSON.stringify(prompt).includes("sk-ant-api")));
});

test("the chat tool runs with Dahlia's input, reports progress, and records every outcome", async () => {
  let tool;
  const sent = [];
  const bridge = async (_ctx, method, payload) => {
    sent.push([method, payload]);
    if (method === "optimizerInput") {
      return { run_id: "r", name: "code-review", raw: "---\nname: code-review\ndescription: d\n---\n\nReview the change carefully and explain every issue you find in detail.\n", messages: [] };
    }
    return true;
  };
  registerSkillOptimizer({ registerTool: (value) => { tool = value; } }, bridge);
  assert.equal(tool.name, "skill_optimize");
  const updates = [];
  const calls = [];
  const result = await tool.execute("id", { name: "code-review", focus: "Keep it in Japanese." }, undefined, (u) => updates.push(u), fakeContext(calls));
  const body = JSON.parse(result.content[0].text);
  assert.equal(body.staged, true);
  assert.equal(sent.at(-1)[0], "optimizerResult");
  assert.equal(sent.at(-1)[1].run_id, "r");
  assert.ok(updates.some((u) => u.content[0].text.startsWith("Iteration 1/")));
  // The user's requirements reach every rewrite.
  assert.ok(calls.filter((p) => !p.systemPrompt).every((p) => p.messages[0].content[0].text.endsWith("Keep it in Japanese.")));

  // A failed run is still recorded before the tool reports the error.
  sent.length = 0;
  const failing = { ...fakeContext([]), modelRegistry: { streamSimple: () => ({ result: async () => ({ stopReason: "error", errorMessage: "boom" }) }) } };
  await assert.rejects(tool.execute("id", { name: "code-review" }, undefined, undefined, failing));
  assert.deepEqual(sent.at(-1), ["optimizerResult", { run_id: "r", name: "code-review", error: "boom" }]);
});

test("upstream helpers", () => {
  assert.deepEqual(splitSkill("---\nname: a\n---\nbody --- more"), { frontmatter: "name: a", body: "body --- more" });
  assert.deepEqual(splitSkill("no frontmatter"), { frontmatter: "", body: "no frontmatter" });
  assert.equal(parseProposal("text\n````md\nuses ```code```\n````"), "uses ```code```");
  assert.equal(parseProposal("plain instruction"), "plain instruction");
  assert.equal(parseProposal("```\n\n```"), null);
  assert.deepEqual(parseObject('Sure: {"a": "{x}", "b": {"c": 1}} done'), { a: "{x}", b: { c: 1 } });
  assert.equal(parseScore("0.7"), 0.7);
  assert.equal(parseScore(3), 1);
  assert.equal(parseScore("n/a"), 0.5);
  assert.equal(isRelevantToSkill("Can you review my code?", "code-review", ""), true);
  assert.equal(isRelevantToSkill("天気は？", "code-review", "review code"), false);
  assert.deepEqual(constraints("x".repeat(13), "x".repeat(10)).map((c) => c.passed), [true, false, true]);
  // Program 1 dominates 0 on every example; 2 is the only best on the last one.
  const picks = new Set(Array.from({ length: 50 }, (_, i) => selectFromPareto([[0.1, 0.1, 0.1], [0.9, 0.9, 0.2], [0.1, 0.1, 0.8]], () => i / 50)));
  assert.deepEqual([...picks].sort(), [1, 2]);
});

test("reflection inserts skill and examples literally, including replacement metacharacters", () => {
  const literal = '$& $` $\' $$ <side_info>';
  const prompt = reflectionPrompt(literal, [{ task_input: literal }], [{ output: literal, feedback: literal }]);
  assert.equal(prompt.split(literal).length - 1, 4);
});

test("the tool surfaces native proposal rejection and records cancellation", async () => {
  let tool;
  const outcomes = [];
  registerSkillOptimizer({ registerTool: (value) => { tool = value; } }, async (_ctx, method, payload) => {
    if (method === "optimizerInput") return { run_id: "r", name: "review", raw: "---\nname: review\n---\nReview input carefully.", messages: [] };
    outcomes.push(payload);
    return { success: false, error: "Skill changed during optimization." };
  });
  await assert.rejects(tool.execute("id", { name: "review" }, undefined, undefined, fakeContext([])), /Skill changed during optimization/);
  assert.equal(outcomes.at(-1).error, "Skill changed during optimization.");
  const aborted = { ...fakeContext([]), modelRegistry: { streamSimple: () => ({ result: async () => ({ stopReason: "aborted" }) }) } };
  await assert.rejects(tool.execute("id", { name: "review" }, undefined, undefined, aborted), /aborted/);
  assert.equal(outcomes.at(-1).error, "aborted");
});

test("frontmatter delimiters must occupy a whole line", () => {
  const frontmatter = "name: review\ndescription: Explain --- and +++ diff headers.";
  assert.deepEqual(splitSkill(`---\n${frontmatter}\n---\n\nFirst.\n---\nSecond.`), { frontmatter, body: "First.\n---\nSecond." });
  assert.deepEqual(splitSkill(`---\n${frontmatter}\n---`), { frontmatter, body: "" });
  assert.deepEqual(splitSkill("---\r\nname: review\r\n---\r\nBody"), { frontmatter: "name: review", body: "Body" });
});
