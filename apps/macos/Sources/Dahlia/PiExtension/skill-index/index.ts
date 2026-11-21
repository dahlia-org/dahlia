// pi-skill-index: replaces Pi's skill listing with a one-line-per-skill index that fits a prompt budget.
// Every name stays listed. Over budget, the least recently used skills lose their descriptions first:
// full text, then 60 characters (Hermes Agent's index width), then the name only.
// The index is computed from inputs that do not change during a process, so the cached prompt prefix is kept.

export interface IndexedSkill {
  name: string;
  description: string;
  filePath: string;
  disableModelInvocation?: boolean;
}

export interface SkillIndexOptions {
  /** Character budget for the skill lines. */
  budget: number;
  /** Skill names, most recently used first. Unlisted skills keep Pi's order after them. */
  rank?: string[];
  /** `skill_view` lists names only; `read` adds each SKILL.md path, as Pi's own listing does. */
  loader: "skill_view" | "read";
  canListSkills?: boolean;
}

export const SHORT_DESCRIPTION = 60;
// Claude Code budgets 1% of the context window for its skill listing; about 4 characters per token.
const CHARS_PER_CONTEXT_TOKEN = 0.04;
const DEFAULT_CONTEXT_WINDOW = 200_000;

export function clip(text: string, limit = SHORT_DESCRIPTION): string {
  if (text.length <= limit) return text;
  const cut = text.slice(0, limit - 3);
  const space = cut.lastIndexOf(" ");
  // Text without spaces (Japanese) is cut at the limit.
  return (space > limit / 2 ? cut.slice(0, space) : cut).trimEnd() + "...";
}

export function formatSkillIndex(skills: IndexedSkill[], options: SkillIndexOptions): string {
  const visible = skills.filter((skill) => !skill.disableModelInvocation);
  if (visible.length === 0) return "";
  const position = new Map((options.rank ?? []).map((name, index) => [name, index]));
  const order = visible
    .map((skill, index) => ({ skill, key: position.get(skill.name) ?? position.size + index }))
    .sort((a, b) => a.key - b.key)
    .map(({ skill }) => skill);
  const full = order.map((skill) => skill.description.replace(/\s+/g, " ").trim());
  // 0: full description, 1: clipped, 2: name only.
  const level = order.map(() => 0);
  const line = (index: number) => {
    const skill = order[index];
    const description = [full[index], clip(full[index]), ""][level[index]];
    const path = options.loader === "read" ? ` (${skill.filePath})` : "";
    return `- ${skill.name}${description ? `: ${description}` : ""}${path}`;
  };
  let size = order.reduce((total, _skill, index) => total + line(index).length + 1, 0);
  // Demote from the least recently used end, one step for every skill before the next step for any.
  for (const step of [1, 2]) {
    for (let index = order.length - 1; index >= 0 && size > options.budget; index -= 1) {
      size -= line(index).length;
      level[index] = step;
      size += line(index).length;
    }
  }
  // Names alone may exceed the budget; every skill stays selectable.
  const shortened = level.some((value) => value > 0);
  const how = options.loader === "skill_view"
    ? "load it with skill_view(name) before acting."
    : "read its file before acting. Resolve relative paths against the skill's directory.";
  const more = !shortened ? [] : [options.loader === "skill_view"
    ? options.canListSkills
      ? "Some descriptions are shortened or omitted to fit; skills_list returns them in full."
      : "Some descriptions are shortened or omitted to fit; skill_view(name) returns the full instructions."
    : "Some descriptions are shortened or omitted to fit; the skill's file has the full text."];
  return [
    `These skills provide specialized instructions for specific tasks. When a task matches a skill, ${how}`,
    ...more,
    "",
    ...order.map((_skill, index) => line(index)),
  ].join("\n");
}

/** Reads `PI_SKILL_INDEX_BUDGET` (characters) and `PI_SKILL_INDEX_RANK` (comma-separated names) when options are omitted. */
export function registerSkillIndex(pi: any, overrides: Partial<Pick<SkillIndexOptions, "budget" | "rank">> = {}) {
  const env = process.env;
  const rank = overrides.rank ?? (env.PI_SKILL_INDEX_RANK ?? "").split(",").filter(Boolean);
  const fixedBudget = overrides.budget ?? (Number(env.PI_SKILL_INDEX_BUDGET) || undefined);
  pi.on("before_agent_start", (event: any, ctx: any) => {
    const options = event.systemPromptOptions;
    const tools: string[] = options.selectedTools ?? [];
    const loader = tools.includes("skill_view") ? "skill_view" : tools.includes("read") ? "read" : undefined;
    // Without a loader Pi decides how (and whether) to list skills.
    if (!loader || !options.skills?.length) return;
    const budget = fixedBudget ?? Math.round((ctx.model?.contextWindow || DEFAULT_CONTEXT_WINDOW) * CHARS_PER_CONTEXT_TOKEN);
    const index = formatSkillIndex(options.skills, { budget, rank, loader, canListSkills: tools.includes("skills_list") });
    // Pi stops listing skills itself; `/skill:name` commands come from the resource loader and still work.
    options.skills = [];
    if (index) options.sections.skills = index;
  });
}

export default function (pi: any) {
  registerSkillIndex(pi);
}
