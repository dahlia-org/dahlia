// node --test apps/macos/scripts/test-skill-index.mjs [PI_DIST=<pi>/dist for the prompt-builder check]
import assert from "node:assert/strict";
import { test } from "node:test";
import { clip, formatSkillIndex, registerSkillIndex } from "../Sources/Dahlia/PiExtension/pi-hermes-skills/skill-index.ts";

const skill = (name, description = `Does ${name} things. Use when the user asks about ${name} work in detail.`.repeat(4)) =>
  ({ name, description, filePath: `/skills/${name}/SKILL.md` });
const lines = (index) => index.split("\n").filter((line) => line.startsWith("- "));

test("clip keeps short text and cuts long text to 60 characters", () => {
  assert.equal(clip("short"), "short");
  const latin = clip("word ".repeat(30));
  assert.ok(latin.length <= 60 && latin.endsWith("...") && !latin.includes("  "));
  assert.equal(clip("あ".repeat(100)), "あ".repeat(57) + "...");
});

test("under budget every description is full, without paths", () => {
  const skills = [skill("alpha"), skill("beta", "Line one.\n  Line two.")];
  const index = formatSkillIndex(skills, { budget: 8000, loader: "skill_view" });
  assert.deepEqual(lines(index), [`- alpha: ${skills[0].description}`, "- beta: Line one. Line two."]);
  assert.ok(index.includes("skill_view(name)") && !index.includes("/skills/") && !index.includes("skills_list"));
});

test("over budget the least recently used lose descriptions first, and names always stay", () => {
  const skills = Array.from({ length: 100 }, (_, i) => skill(`skill-${String(i).padStart(3, "0")}`));
  const rank = ["skill-099", "skill-050"];
  const index = formatSkillIndex(skills, { budget: 8000, rank, loader: "skill_view", canListSkills: true });
  const listed = lines(index);
  assert.equal(listed.length, 100);
  assert.ok(listed.join("\n").length <= 8000);
  assert.ok(listed[0].startsWith("- skill-099: ") && listed[1].startsWith("- skill-050: "));
  assert.ok(listed[0].length > 70, "the most recently used keeps its full description");
  assert.ok(listed.every((line) => !line.includes(": ") || line.split(": ")[1].length <= skills[0].description.length));
  assert.match(index, /skills_list returns them in full/);

  const tiny = lines(formatSkillIndex(skills, { budget: 500, loader: "skill_view" }));
  assert.equal(tiny.length, 100, "names alone exceed the budget but stay listed");
  assert.ok(tiny.every((line) => !line.includes(": ")));
});

test("every skill gets the short description before any loses it", () => {
  const skills = Array.from({ length: 20 }, (_, i) => skill(`s${i}`));
  const listed = lines(formatSkillIndex(skills, { budget: 20 * 70, loader: "skill_view" }));
  assert.ok(listed.every((line) => line.includes(": ") && line.split(": ")[1].length <= 60));
});

test("hidden skills are left out and the read loader keeps paths", () => {
  const index = formatSkillIndex([skill("a"), { ...skill("b"), disableModelInvocation: true }], { budget: 8000, loader: "read" });
  assert.equal(lines(index).length, 1);
  assert.ok(index.includes("(/skills/a/SKILL.md)") && index.includes("read its file"));
});

test("the hook replaces Pi's listing only when a loader is active", async () => {
  let handler;
  registerSkillIndex({ on: (_name, fn) => { handler = fn; } }, { rank: [] });
  const run = (selectedTools) => {
    const options = { selectedTools, skills: [skill("a")], sections: {} };
    handler({ systemPromptOptions: options }, { model: { contextWindow: 1_000 } });
    return options;
  };
  const replaced = run(["read", "skill_view"]);
  assert.deepEqual(replaced.skills, []);
  assert.match(replaced.sections.skills, /^These skills/);
  const untouched = run(["bash"]);
  assert.equal(untouched.skills.length, 1);
  assert.equal(untouched.sections.skills, undefined);
});

test("without usage metrics the hook preserves Pi order and only advertises available tools", () => {
  const previousRank = process.env.PI_SKILL_INDEX_RANK;
  const previousBudget = process.env.PI_SKILL_INDEX_BUDGET;
  delete process.env.PI_SKILL_INDEX_RANK;
  delete process.env.PI_SKILL_INDEX_BUDGET;
  try {
    let handler;
    registerSkillIndex({ on: (_name, fn) => { handler = fn; } });
    const skills = Array.from({ length: 100 }, (_, i) => skill(`s${i}`));
    for (const tools of [["skill_view"], ["skill_view", "skills_list"]]) {
      const options = { selectedTools: tools, skills, sections: {} };
      handler({ systemPromptOptions: options }, { model: { contextWindow: 200_000 } });
      const listed = lines(options.sections.skills);
      assert.deepEqual(listed.map((line) => line.slice(2).split(":")[0]), skills.map((skill) => skill.name));
      assert.ok(listed.join("\n").length <= 8000);
      assert.equal(options.sections.skills.includes("skills_list"), tools.includes("skills_list"));
      assert.deepEqual(options.skills, []);
    }
  } finally {
    if (previousRank === undefined) delete process.env.PI_SKILL_INDEX_RANK;
    else process.env.PI_SKILL_INDEX_RANK = previousRank;
    if (previousBudget === undefined) delete process.env.PI_SKILL_INDEX_BUDGET;
    else process.env.PI_SKILL_INDEX_BUDGET = previousBudget;
  }
});

test("Pi's prompt builder drops <available_skills> for the replaced options", { skip: !process.env.PI_DIST }, async () => {
  const { buildSystemPrompt } = await import(`${process.env.PI_DIST}/core/system-prompt.js`);
  let handler;
  registerSkillIndex({ on: (_name, fn) => { handler = fn; } }, { budget: 8000 });
  const options = { customPrompt: "Dahlia", cwd: "/tmp", selectedTools: ["read", "skill_view"], skills: [skill("alpha")], sections: {} };
  handler({ systemPromptOptions: options }, {});
  const prompt = buildSystemPrompt(options);
  const text = typeof prompt === "string" ? prompt : JSON.stringify(prompt);
  assert.ok(!text.includes("available_skills") && !text.includes("/skills/alpha/SKILL.md") && text.includes("- alpha: "));
});

test("the environment budget overrides a configured budget", () => {
  const previous = process.env.PI_SKILL_INDEX_BUDGET;
  process.env.PI_SKILL_INDEX_BUDGET = "1";
  try {
    let handler;
    registerSkillIndex({ on: (_name, fn) => { handler = fn; } }, { budget: 8000 });
    const options = { selectedTools: ["skill_view"], skills: [skill("alpha")], sections: {} };
    handler({ systemPromptOptions: options }, {});
    assert.deepEqual(lines(options.sections.skills), ["- alpha"]);
  } finally {
    if (previous === undefined) delete process.env.PI_SKILL_INDEX_BUDGET;
    else process.env.PI_SKILL_INDEX_BUDGET = previous;
  }
});
