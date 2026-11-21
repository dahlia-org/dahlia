// hermes-agent-self-evolution Phase 1 (evolve one SKILL.md with GEPA) as a chat tool, so the user follows the run and can
// give further instructions. See hermes/UPSTREAM.md. A host supplies the skill and the conversations to learn from, and
// decides what happens to the result; without one, the skill file and Pi's sessions are used directly.
import { readFileSync, writeFileSync } from "node:fs";
import { assertWritableSkill, fileSkillTools } from "./tools.ts";
import type { UsageStore } from "./usage.ts";

const upstream = JSON.parse(readFileSync(new URL("./hermes/evolution.json", import.meta.url), "utf8"));

// evolution/core/config.py EvolutionConfig defaults.
export const config = {
  iterations: 10, maxSkillSize: 15_000, maxPromptGrowth: 0.2,
  evalDatasetSize: 20, trainRatio: 0.5, valRatio: 0.25,
  // GEPA engine defaults: reflection minibatch of 3, perfect score 1 skipped.
  minibatch: 3, perfectScore: 1,
};

// evolution/core/external_importers.py SECRET_PATTERNS: such messages never enter a dataset.
const secretPatterns = new RegExp(
  "(sk-ant-api\\S+|sk-or-v1-\\S+|sk-\\S{20,}|ghp_\\S+|ghu_\\S+|xoxb-\\S+|xapp-\\S+|ntn_\\S+|AKIA[0-9A-Z]{16}|Bearer\\s+\\S{20,}"
    + "|-----BEGIN\\s+(RSA\\s+)?PRIVATE\\sKEY-----|ANTHROPIC_API_KEY|OPENAI_API_KEY|OPENROUTER_API_KEY|SLACK_BOT_TOKEN|GITHUB_TOKEN"
    + "|AWS_SECRET_ACCESS_KEY|DATABASE_URL|\\bpassword\\s*[=:]\\s*\\S+|\\bsecret\\s*[=:]\\s*\\S+|\\btoken\\s*[=:]\\s*\\S{10,})",
  "i",
);
export const containsSecret = (text: string) => secretPatterns.test(text);

type Example = { task_input: string; expected_behavior: string; difficulty: string; category: string; source: string };
type Scored = { score: number; output: string; feedback: string };
export type Message = { task_input: string; assistant_response?: string };
export type OptimizerResult = Awaited<ReturnType<typeof evolve>>;
export type OptimizerRun = { name: string; token?: string };

/** What a host provides to run `skill_optimize`. */
export interface OptimizerHost {
  /** Replaces the tool description, for example to say where the user approves the result. */
  description?: string;
  /** The skill's SKILL.md and recent user requests with their replies, newest first. `token` comes back in `finish`. */
  begin(ctx: any, name: string): Promise<{ raw: string; messages: Message[]; token?: string }>;
  /** Called once with the result or the error. Its answer is reported to the model; `{ success: false, error }` fails the tool. */
  finish(ctx: any, run: OptimizerRun, outcome: OptimizerResult | { error: string }): Promise<unknown>;
}

const defaultDescription = "Optimize a skill's SKILL.md with GEPA (hermes-agent-self-evolution): build evaluation examples from "
  + "earlier conversations, evolve the instructions, and propose a better-scoring version for the user's approval. Nothing "
  + "changes until the user approves. A run takes minutes and hundreds of model calls; start it only when the user asks. "
  + "Pass the user's extra requirements for the rewrite as `focus`.";

export function registerSkillOptimizer(pi: any, host: OptimizerHost) {
  pi.registerTool({
    name: "skill_optimize",
    label: "Optimize skill",
    description: host.description ?? defaultDescription,
    parameters: {
      type: "object",
      properties: {
        name: { type: "string", description: "Skill to optimize." },
        focus: { type: "string", description: "The user's requirements for the rewritten skill, if any." },
      },
      required: ["name"],
      additionalProperties: false,
    },
    execute: async (_id: string, params: any, signal: AbortSignal, onUpdate: any, ctx: any) => {
      let input: Awaited<ReturnType<OptimizerHost["begin"]>>;
      try {
        input = await host.begin(ctx, params.name);
      } catch (error: any) {
        return { isError: true, content: [{ type: "text", text: error?.message ?? String(error) }] };
      }
      const run = { name: params.name, token: input.token };
      try {
        const progress = (text: string) => onUpdate?.({ content: [{ type: "text", text }] });
        const result = await evolve(
          { model: ctx.model, modelRegistry: ctx.modelRegistry, signal },
          { name: params.name, raw: input.raw, messages: input.messages, focus: params.focus },
          progress,
        );
        const staged: any = await host.finish(ctx, run, result);
        if (staged?.success === false) throw new Error(staged.error);
        return { content: [{ type: "text", text: JSON.stringify({ ...result, staged }) }] };
      } catch (error: any) {
        await host.finish(ctx, run, { error: error?.message ?? String(error) });
        throw error;
      }
    },
  });
}

/** Whether a result is worth proposing: changed, better on the held-out examples, and within the constraints. */
export const isImprovement = (result: OptimizerResult) =>
  result.changed && result.improvement > 0 && result.constraints.every((check) => check.passed);

/**
 * Pi alone: reads the skill file Pi listed and this directory's other Pi sessions. With a UI, the user confirms the
 * replacement; otherwise the proposal is saved next to the skill as `<file>.optimized`.
 */
export function fileOptimizer(
  options: { root: string; store: UsageStore; skills: () => { name: string; filePath: string }[] },
): OptimizerHost {
  const find = async (name: string) => {
    const skill = options.skills().find((candidate) => candidate.name === name);
    if (!skill) throw new Error(`Skill '${name}' not found. Use one of the listed skills.`);
    assertWritableSkill(options.root, name, skill.filePath, (await options.store.all?.())?.[name]);
    return skill;
  };
  return {
    begin: async (ctx, name) => {
      const raw = readFileSync((await find(name)).filePath, "utf8");
      return { raw, messages: await sessionMessages(ctx), token: raw };
    },
    finish: async (ctx, run, outcome) => {
      if ("error" in outcome || !isImprovement(outcome)) return false;
      let file = (await find(run.name)).filePath;
      if (readFileSync(file, "utf8") !== run.token) return { success: false, error: "The skill changed during optimization; optimize it again." };
      const scores = `${outcome.baseline_score.toFixed(2)} → ${outcome.evolved_score.toFixed(2)}`;
      const approved = ctx?.hasUI && await ctx.ui.confirm(`Replace skill '${run.name}'?`, `Held-out score ${scores}.`);
      file = (await find(run.name)).filePath;
      if (readFileSync(file, "utf8") !== run.token) return { success: false, error: "The skill changed during optimization; optimize it again." };
      if (approved) {
        const manage = fileSkillTools({ ...options, expected: { name: run.name, content: run.token ?? "" } });
        await manage("skill_manage", { operations: [{ action: "patch", name: run.name, content: outcome.skill }] }, ctx);
        return { applied: true };
      }
      writeFileSync(`${file}.optimized`, outcome.skill);
      return { applied: false, proposal: `${file}.optimized` };
    },
  };
}

/** Upstream `HermesSessionImporter` over Pi sessions: each user request with the first reply after it, newest first. */
export async function sessionMessages(ctx: any, limit = 300): Promise<Message[]> {
  const { SessionManager } = await import("@earendil-works/pi-coding-agent");
  const current = ctx?.sessionManager?.getSessionFile?.();
  const text = (message: any) => typeof message?.content === "string" ? message.content
    : (message?.content ?? []).flatMap((part: any) => (part?.type === "text" ? [part.text] : [])).join("\n");
  const pairs: Message[] = [];
  for (const session of await SessionManager.list(ctx.cwd)) {
    if (session.path === current) continue;
    const entries = SessionManager.open(session.path).getEntries().filter((entry: any) => entry.type === "message");
    let reply = "";
    for (let i = entries.length - 1; i >= 0 && pairs.length < limit; i--) {
      const message = entries[i].message;
      if (message.role === "assistant") reply = text(message) || reply;
      if (message.role !== "user") continue;
      const request = text(message);
      if (request) pairs.push({ task_input: request, assistant_response: reply });
      reply = "";
    }
    if (pairs.length >= limit) break;
  }
  return pairs;
}

// evolution/skills/skill_module.py load_skill and reassemble_skill.
export function splitSkill(raw: string) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)([\s\S]*)$/.exec(raw);
  if (!match) return { frontmatter: "", body: raw };
  return { frontmatter: match[1].trim(), body: match[2].trim() };
}
export const reassembleSkill = (frontmatter: string, body: string) => `---\n${frontmatter}\n---\n\n${body}\n`;

/** evolution/skills/evolve_skill.py `evolve`, with GEPA's reflective loop optimizing the skill body itself. */
export async function evolve(
  ctx: any,
  input: { name: string; raw: string; messages: Message[]; iterations?: number; focus?: string },
  progress: (text: string) => void = () => {},
) {
  const rng = random(0);
  const lm = (systemPrompt: string, text: string) => complete(ctx, systemPrompt, text);
  const { frontmatter, body: baseline } = splitSkill(input.raw);
  const iterations = input.iterations ?? config.iterations;

  // 2. Evaluation dataset: real conversations first (upstream `sessiondb`), topped up with synthetic cases.
  progress("Building evaluation examples from this account's conversations…");
  let examples = await mineExamples(lm, input.messages, input.name, input.raw, rng);
  const mined = examples.length;
  if (examples.length < config.evalDatasetSize / 2) {
    examples = examples.concat(await synthesize(lm, input.raw, config.evalDatasetSize - examples.length));
  }
  if (examples.length < 3) throw new Error("Not enough evaluation examples could be built for this skill.");
  shuffle(examples, rng);
  const nTrain = Math.max(1, Math.floor(examples.length * config.trainRatio));
  const nVal = Math.max(1, Math.floor(examples.length * config.valRatio));
  const train = examples.slice(0, nTrain);
  const val = examples.slice(nTrain, nTrain + nVal);
  const holdout = examples.slice(nTrain + nVal);

  // 4-5. GEPA: a pool of candidates, the per-example Pareto front on the validation set, reflective mutation.
  const evaluate = (body: string, batch: Example[]) => Promise.all(batch.map((example) => score(lm, body, example)));
  progress(`Scoring the current skill on ${val.length} validation examples (${mined} from conversations, ${examples.length - mined} synthetic)…`);
  const pool: { body: string; val: number[] }[] = [{ body: baseline, val: (await evaluate(baseline, val)).map((s) => s.score) }];
  let proposals = 0;
  let cursor = 0;
  const order = shuffle([...train.keys()], rng);
  for (let step = 0; step < iterations; step++) {
    progress(`Iteration ${step + 1}/${iterations}: ${pool.length - 1} improved candidate(s) so far…`);
    const parent = pool[selectFromPareto(pool.map((c) => c.val), rng)];
    const batch = Array.from({ length: Math.min(config.minibatch, train.length) }, () => train[order[cursor++ % order.length]]);
    const before = await evaluate(parent.body, batch);
    if (before.every((s) => s.score >= config.perfectScore)) continue;
    const proposal = parseProposal(await lm("", reflectionPrompt(parent.body, batch, before, input.focus)));
    proposals += 1;
    if (!proposal || proposal === parent.body || !constraints(proposal, baseline).every((c) => c.passed)) continue;
    const after = await evaluate(proposal, batch);
    // StrictImprovementAcceptance.
    if (sum(after.map((s) => s.score)) <= sum(before.map((s) => s.score))) continue;
    pool.push({ body: proposal, val: (await evaluate(proposal, val)).map((s) => s.score) });
  }
  const best = pool.reduce((a, b) => (mean(b.val) > mean(a.val) ? b : a));

  // 7-8. Constraints on the evolved body, then the holdout comparison.
  progress("Comparing the original and the best candidate on held-out examples…");
  const checks = constraints(best.body, baseline);
  const testSet = holdout.length > 0 ? holdout : val;
  const baselineScore = mean((await evaluate(baseline, testSet)).map((s) => s.score));
  const evolvedScore = best === pool[0] ? baselineScore : mean((await evaluate(best.body, testSet)).map((s) => s.score));
  return {
    skill: reassembleSkill(frontmatter, best.body),
    changed: best !== pool[0],
    constraints: checks,
    baseline_score: baselineScore,
    evolved_score: evolvedScore,
    improvement: evolvedScore - baselineScore,
    baseline_size: baseline.length,
    evolved_size: best.body.length,
    iterations, proposals, candidates: pool.length,
    examples: { mined, synthetic: examples.length - mined, train: train.length, val: val.length, holdout: holdout.length },
  };
}

/** RelevanceFilter.filter_and_score over the account's conversations (upstream HermesSessionImporter). */
async function mineExamples(lm: LM, messages: Message[], name: string, skillText: string, rng: () => number, max = config.evalDatasetSize) {
  const usable = messages.filter((m) => m.task_input?.length >= 10 && !containsSecret(m.task_input) && !containsSecret(m.assistant_response ?? ""));
  const candidates = usable.filter((m) => isRelevantToSkill(m.task_input, name, skillText));
  if (candidates.length < max) candidates.push(...shuffle(usable.filter((m) => !candidates.includes(m)), rng).slice(0, max * 2));
  const examples: Example[] = [];
  for (const message of candidates.slice(0, max * 3)) {
    if (examples.length >= max) break;
    try {
      const result = await predict(lm, "ScoreRelevance", {
        skill_name: name,
        skill_description: skillText.slice(0, 800),
        user_message: message.task_input.slice(0, 1000),
        assistant_response: (message.assistant_response ?? "").slice(0, 1000),
      });
      const scoring = parseObject(result.scoring ?? "");
      if (scoring?.relevant === true) {
        const example = validateExample(message.task_input, scoring.expected_behavior, scoring.difficulty, scoring.category, "session");
        if (example) examples.push(example);
      }
    } catch {
      // Upstream counts the failure and moves on to the next message.
    }
  }
  return examples;
}

/** SyntheticDatasetBuilder.generate. */
async function synthesize(lm: LM, skillText: string, count: number): Promise<Example[]> {
  const result = await predict(lm, "GenerateTestCases", { artifact_text: skillText, artifact_type: "skill", num_cases: String(count) });
  const text = String(result.test_cases ?? "");
  let cases: any;
  try {
    cases = JSON.parse(text);
  } catch {
    const match = text.match(/\[[\s\S]*\]/);
    if (!match) throw new Error(`Could not parse test cases from LLM output: ${text.slice(0, 200)}`);
    cases = JSON.parse(match[0]);
  }
  return (Array.isArray(cases) ? cases : [])
    .map((c: any) => validateExample(c?.task_input, c?.expected_behavior, c?.difficulty, c?.category, "synthetic"))
    .filter((c): c is Example => c !== null);
}

// external_importers.py `_is_relevant_to_skill`. Its keyword step reads Latin letters only, as upstream.
export function isRelevantToSkill(text: string, name: string, skillText: string) {
  const lower = text.toLowerCase();
  const skill = name.toLowerCase().replaceAll("-", " ").replaceAll("_", " ");
  if (lower.includes(skill)) return true;
  if (skill.split(/\s+/).some((word) => word.length > 3 && lower.includes(word))) return true;
  const keywords = new Set(skillText.slice(0, 500).toLowerCase().split(/\s+/).map((w) => w.replace(/[^a-z]/g, "")).filter((w) => w.length > 4));
  const words = new Set(lower.replace(/[^a-z\s]/g, "").split(/\s+/));
  return [...words].filter((w) => keywords.has(w)).length >= 2;
}

// external_importers.py `_validate_eval_example`.
function validateExample(task: any, expected: any, difficulty: any, category: any, source: string): Example | null {
  if (typeof task !== "string" || !task.trim() || typeof expected !== "string" || !expected.trim()) return null;
  const level = typeof difficulty === "string" ? difficulty.trim().toLowerCase() : "medium";
  return {
    task_input: task.slice(0, 2000),
    expected_behavior: expected.trim(),
    difficulty: ["easy", "medium", "hard"].includes(level) ? level : "medium",
    category: typeof category === "string" && category.trim() ? category.trim() : "general",
    source,
  };
}

/** SkillModule.forward scored by fitness.py LLMJudge, whose feedback GEPA reflects on. */
async function score(lm: LM, body: string, example: Example): Promise<Scored> {
  const output = String((await predict(lm, "TaskWithSkill", { skill_instructions: body, task_input: example.task_input })).output ?? "");
  if (!output.trim()) return { score: 0, output, feedback: "The response was empty." };
  const judged = await predict(lm, "JudgeSignature", {
    task_input: example.task_input, expected_behavior: example.expected_behavior, agent_output: output, skill_text: body,
  });
  // FitnessScore.composite with the length penalty for the skill size limit.
  const ratio = body.length / config.maxSkillSize;
  const penalty = ratio > 0.9 ? Math.min(0.3, (ratio - 0.9) * 3) : 0;
  const raw = 0.5 * parseScore(judged.correctness) + 0.3 * parseScore(judged.procedure_following) + 0.2 * parseScore(judged.conciseness);
  return { score: Math.max(0, raw - penalty), output, feedback: String(judged.feedback ?? "") };
}

// fitness.py `_parse_score`.
export function parseScore(value: unknown) {
  const number = typeof value === "number" ? value : Number.parseFloat(String(value).trim());
  return Number.isFinite(number) ? Math.min(1, Math.max(0, number)) : 0.5;
}

/** GEPA InstructionProposalSignature with DSPy's reflective dataset keys; the user's chat `focus` follows it. */
export function reflectionPrompt(current: string, batch: Example[], scored: Scored[], focus?: string) {
  const samples = batch.map((example, i) =>
    `# Example ${i + 1}\n## Inputs\n### task_input\n${example.task_input.trim()}\n\n## Generated Outputs\n${scored[i].output.trim()}\n\n`
    + `## Feedback\n${scored[i].feedback.trim()}\n\n`).join("\n\n");
  const prompt = upstream.reflection_prompt.replace(/<curr_param>|<side_info>/g, (marker: string) => marker === "<curr_param>" ? current : samples);
  return focus?.trim() ? `${prompt}\n\nThe user also requires the following of the new instruction:\n${focus.trim()}` : prompt;
}

// GEPA ProposalAdapter.parse: the outermost ``` block, without its info line; otherwise the whole reply.
export function parseProposal(reply: string): string | null {
  const start = reply.indexOf("```");
  const end = reply.lastIndexOf("```");
  let value = reply.trim();
  if (start + 3 < end) {
    // A longer opening fence wraps content that itself contains ```; it closes with a run of the same length.
    let fence = 3;
    while (reply[start + fence] === "`") fence++;
    const long = reply.lastIndexOf("`".repeat(fence));
    let close = end;
    if (fence > 3 && long > start + fence) close = long;
    else fence = 3;
    const content = reply.slice(start + fence, close);
    const info = content.match(/^\S*(?:[ \t]+(?:[\w-]+=(?:"[^"\n]*"|'[^'\n]*')|\{[^}\n]*\}))*[ \t]*\r?\n/);
    value = (info ? content.slice(info[0].length) : content).trim();
  }
  return value || null;
}

// constraints.py ConstraintValidator.validate_all for a skill body. A host may validate the frontmatter again on approval.
export function constraints(text: string, baseline: string) {
  const growth = (text.length - baseline.length) / Math.max(1, baseline.length);
  return [
    { constraint_name: "size_limit", passed: text.length <= config.maxSkillSize, message: `Size: ${text.length}/${config.maxSkillSize} chars` },
    { constraint_name: "growth_limit", passed: growth <= config.maxPromptGrowth, message: `Growth: ${(growth * 100).toFixed(1)}% (max +20.0%)` },
    { constraint_name: "non_empty", passed: text.trim().length > 0, message: "Artifact is non-empty" },
  ];
}

// GEPA gepa_utils.select_program_candidate_from_pareto_front over per-example validation scores.
export function selectFromPareto(scores: number[][], rng: () => number) {
  const fronts = scores[0].map((_, i) => {
    const best = Math.max(...scores.map((s) => s[i]));
    return new Set(scores.flatMap((s, p) => (s[i] === best ? [p] : [])));
  });
  // remove_dominated_programs: from the lowest aggregate up, drop a program while every front it is on has another.
  const remaining = fronts.map((front) => front.size);
  const dominated = new Set<number>();
  for (const p of [...scores.keys()].sort((a, b) => mean(scores[a]) - mean(scores[b]))) {
    const on = fronts.flatMap((front, i) => (front.has(p) ? [i] : []));
    if (on.length > 0 && on.every((i) => remaining[i] > 1)) {
      dominated.add(p);
      for (const i of on) remaining[i] -= 1;
    }
  }
  const sampling = fronts.flatMap((front) => [...front].filter((p) => !dominated.has(p)));
  return sampling.length > 0 ? sampling[Math.floor(rng() * sampling.length)] : 0;
}

type LM = (systemPrompt: string, text: string) => Promise<string>;

/** DSPy ChatAdapter: field markers in, field markers out; ChainOfThought adds `reasoning` first. */
export async function predict(lm: LM, name: string, inputs: Record<string, string>) {
  const signature = upstream[name];
  const types = signature.types ?? {};
  const outputs: [string, string][] = [["reasoning", ""], ...Object.entries(signature.outputs) as [string, string][]];
  const describe = (fields: [string, string][]) =>
    fields.map(([key, desc], i) => `${i + 1}. \`${key}\` (${types[key] ?? "str"})${desc ? `: ${desc}` : ""}`).join("\n");
  const skeleton = [...Object.keys(signature.inputs), ...outputs.map(([key]) => key)]
    .map((key) => `[[ ## ${key} ## ]]\n{${key}}${types[key] ? `        # note: the value you produce must be a single ${types[key]} value` : ""}`)
    .join("\n\n");
  const systemPrompt = `Your input fields are:\n${describe(Object.entries(signature.inputs) as [string, string][])}\n`
    + `Your output fields are:\n${describe(outputs)}\nAll interactions will be structured in the following way, with the appropriate values filled in.\n\n`
    + `${skeleton}\n\n[[ ## completed ## ]]\nIn adhering to this structure, your objective is: \n        ${signature.instructions.replaceAll("\n", "\n        ")}`;
  const text = Object.entries(inputs).map(([key, value]) => `[[ ## ${key} ## ]]\n${value}`).join("\n\n")
    + `\n\nRespond with the corresponding output fields, starting with the field ${outputs.map(([key]) => `\`[[ ## ${key} ## ]]\``).join(", then ")}, `
    + "and then ending with the marker for `[[ ## completed ## ]]`.";
  const reply = await lm(systemPrompt, text);
  const fields: Record<string, string> = {};
  const parts = reply.split(/\[\[ ## (\w+) ## \]\]/);
  for (let i = 1; i + 1 < parts.length; i += 2) fields[parts[i]] = parts[i + 1].trim();
  if (!(outputs.at(-1)![0] in fields)) throw new Error(`The model did not answer ${name}.`);
  return fields;
}

async function complete(ctx: any, systemPrompt: string, text: string): Promise<string> {
  const response = await ctx.modelRegistry.streamSimple(
    ctx.model,
    { systemPrompt, messages: [{ role: "user", content: [{ type: "text", text }], timestamp: Date.now() }] },
    { signal: ctx.signal },
  ).result();
  if (response.stopReason === "error" || response.stopReason === "aborted") throw new Error(response.errorMessage ?? response.stopReason);
  return response.content.flatMap((part: any) => (part.type === "text" ? [part.text] : [])).join("\n");
}

// external_importers.py `_parse_scoring_json`: the first balanced JSON object.
export function parseObject(text: string): any {
  try {
    const value = JSON.parse(text);
    if (value && typeof value === "object" && !Array.isArray(value)) return value;
  } catch {}
  const start = text.indexOf("{");
  if (start < 0) return null;
  let depth = 0, inString = false, escaped = false;
  for (let i = start; i < text.length; i++) {
    const ch = text[i];
    if (escaped) { escaped = false; continue; }
    if (ch === "\\" && inString) { escaped = true; continue; }
    if (ch === '"') { inString = !inString; continue; }
    if (inString) continue;
    if (ch === "{") depth++;
    if (ch === "}" && --depth === 0) {
      try { return JSON.parse(text.slice(start, i + 1)); } catch { return null; }
    }
  }
  return null;
}

const sum = (values: number[]) => values.reduce((a, b) => a + b, 0);
const mean = (values: number[]) => (values.length > 0 ? sum(values) / values.length : 0);

// GEPA seeds its selectors with random.Random(0); any fixed seed keeps a run reproducible.
function random(seed: number) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function shuffle<T>(items: T[], rng: () => number) {
  for (let i = items.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [items[i], items[j]] = [items[j], items[i]];
  }
  return items;
}
