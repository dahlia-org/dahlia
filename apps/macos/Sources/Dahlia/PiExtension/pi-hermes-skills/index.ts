// pi-hermes-skills: Hermes Agent's skill features for Pi. A budgeted skill index ordered by usage, usage records, the
// skill tools, background skill reviews, the Curator, `skill_optimize` (hermes-agent-self-evolution) and `/learn`.
// A host may replace where records live, how tools run, and how optimization starts and ends.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { backgroundRole, enforceBudget, startBackground } from "./background.ts";
import { applyTransitions, type CuratorReport, type CuratorSettings, renderCandidates, restoreSkill } from "./curator.ts";
import { type LearnOptions, learnTemplatePath, registerLearn } from "./learn.ts";
import { fileOptimizer, type OptimizerHost, registerSkillOptimizer } from "./optimizer.ts";
import { type IndexedSkill, registerSkillIndex, type SkillIndexHooks } from "./skill-index.ts";
import { fileSkillTools, registerSkillTools, type Role, type SkillToolExecutor, validName } from "./tools.ts";
import { agentDir, fileStore, rankFromRecords, trackUsage, type UsageStore } from "./usage.ts";

export { learnTemplatePath } from "./learn.ts";
export type { CuratorReport, CuratorSettings } from "./curator.ts";
export type { OptimizerHost, OptimizerResult, OptimizerRun } from "./optimizer.ts";
export type { Role, SkillToolExecutor } from "./tools.ts";
export type { SkillRecord, UsageStore } from "./usage.ts";

const prompts: Record<string, string> = JSON.parse(readFileSync(new URL("./hermes/prompts.json", import.meta.url), "utf8"));

/** The `hermesSkills` object in Pi's settings.json. */
export interface HermesSkillsSettings {
  index: { budget: number | null };
  /** Upstream `skills.creation_nudge_interval`: tool-calling responses between reviews; 0 turns reviews off. */
  review: { enabled: boolean; interval: number; model: string | null };
  curator: CuratorSettings;
  optimizer: { enabled: boolean };
}

type Overrides = { [K in keyof HermesSkillsSettings]?: Partial<HermesSkillsSettings[K]> };

export interface HermesSkillsHost {
  /** Takes precedence over settings.json. */
  settings?: Overrides;
  /** Index order, most recently used first. Otherwise `PI_SKILL_INDEX_RANK`, then the store's records. */
  rank?: string[];
  /** Defaults to `skills/.usage.json` in Pi's agent directory. */
  store?: UsageStore;
  /** Runs `skills_list`, `skill_view` and `skill_manage`; `false` leaves them out. Defaults to the account skills directory. */
  tools?: SkillToolExecutor | false;
  /** Set when this process is a background pass, which gets upstream's budgets. */
  role?: Role;
  /** `false` when the host schedules skill reviews itself. */
  review?: false;
  /**
   * `false` leaves out `/hermes-curator`. With `report`, the command only applies the transitions and hands over the
   * counts and the consolidation candidates; the host runs consolidation itself. Pi has no resident process, so
   * whoever runs the command (cron, launchd, a host app) decides when the Curator runs.
   */
  curator?: false | { report(ctx: any, report: CuratorReport): Promise<unknown> };
  /** `false` leaves out `skill_optimize`. Defaults to the skill file and this directory's Pi sessions. */
  optimizer?: OptimizerHost | false;
  /** `false` leaves out `/learn`. */
  learn?: LearnOptions | false;
  /** `false` when the host adds Hermes's skills guidance to the system prompt itself. */
  guidance?: false;
}

export const defaultSettings: HermesSkillsSettings = {
  index: { budget: null },
  review: { enabled: true, interval: 10, model: null },
  curator: { enabled: true, staleAfterDays: 14, archiveAfterDays: 30, consolidate: false, model: null },
  optimizer: { enabled: true },
};

export function resolveSettings(fromFile: any, fromHost: Overrides = {}): HermesSkillsSettings {
  const file = fromFile && typeof fromFile === "object" ? fromFile : {};
  const merged: any = {};
  for (const key of Object.keys(defaultSettings) as (keyof HermesSkillsSettings)[]) {
    merged[key] = { ...defaultSettings[key], ...file[key], ...fromHost[key] };
  }
  return merged;
}

// Upstream's review suffix, without memory.
const reviewSuffix = "\n\nYou can only call skill management tools. Other tools will be denied at runtime — do not attempt them.";

export function registerHermesSkills(pi: any, host: HermesSkillsHost = {}) {
  const role = host.role ?? backgroundRole();
  const root = join(agentDir(), "skills");
  let skills: IndexedSkill[] = [];
  let settings = resolveSettings(undefined, host.settings);
  const index: SkillIndexHooks = { rank: host.rank, onSkills: (listed) => { skills = listed; } };
  const store = host.store ?? fileStore();
  const listed = () => skills;

  registerSkillIndex(pi, index);
  trackUsage(pi, store, listed);
  if (host.tools !== false) registerSkillTools(pi, host.tools ?? fileSkillTools({ root, store, skills: listed, role }));
  if (host.optimizer !== false) {
    registerSkillOptimizer(pi, host.optimizer ?? fileOptimizer({ root, store, skills: listed }));
  }
  if (host.learn !== false) registerLearn(pi, host.learn ?? {});
  // Lists `/learn` with the commands whether the package is installed or loaded with `-e`; a host lists it itself.
  if (host.learn === undefined) pi.on("resources_discover", () => ({ promptPaths: [learnTemplatePath] }));
  if (role) enforceBudget(pi, role);

  if (host.guidance !== false) {
    pi.on("before_agent_start", (event: any) => {
      const prompt = event.systemPromptOptions;
      if (prompt.selectedTools?.includes("skill_manage")) prompt.promptGuidelines = [...(prompt.promptGuidelines ?? []), prompts.skills_guidance];
    });
  }

  const modelOf = (ctx: any, configured: string | null) => configured ?? (ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined);
  const curate = async (): Promise<CuratorReport> => {
    const counts = await applyTransitions(store, root, settings.curator);
    return { counts, candidates: await renderCandidates(store, root) };
  };
  const consolidate = (ctx: any, candidates: string) => startBackground(pi, {
    role: "curator", prompt: `${prompts.curator_review_prompt}\n\n${candidates}`, model: modelOf(ctx, settings.curator.model), cwd: ctx.cwd,
  });

  if (host.curator !== false) {
    const report = host.curator?.report;
    pi.registerCommand("hermes-curator", {
      description: "Curate agent-created skills now, or restore, pin or unpin one: [run | restore <name> | pin <name> | unpin <name>]",
      handler: async (args: string, ctx: any) => {
        const [action = "run", name] = args.trim().split(/\s+/).filter(Boolean);
        if (action === "run") {
          if (!settings.curator.enabled) return ctx.ui.notify("Curator is disabled (hermesSkills.curator.enabled).", "info");
          const result = await curate();
          if (report) return void await report(ctx, result);
          if (settings.curator.consolidate && result.candidates) consolidate(ctx, result.candidates);
          const { archived, markedStale, reactivated } = result.counts;
          return ctx.ui.notify(`Curator: ${archived} archived, ${markedStale} marked stale, ${reactivated} reactivated.`, "info");
        }
        if (!validName(name) || !["restore", "pin", "unpin"].includes(action)) {
          return ctx.ui.notify("Usage: /hermes-curator [run | restore <name> | pin <name> | unpin <name>]", "warning");
        }
        if (action === "restore") await restoreSkill(store, root, name);
        // Like `hermes curator pin`, only skills the Curator manages can be pinned.
        else if ((await store.all?.())?.[name]?.created_by !== "agent") return ctx.ui.notify(`'${name}' is not curated.`, "warning");
        else await store.set?.(name, { pinned: action === "pin" });
        ctx.ui.notify(`Skill '${name}': ${action} done.`, "info");
      },
    });
  }

  // Upstream `skills.creation_nudge_interval`: count responses that called tools; a skill change resets the count.
  let iterations = 0;
  const reviews = !role && host.review !== false;
  if (reviews) {
    pi.on("message_end", (event: any) => {
      if (event.message?.role === "assistant" && event.message.content?.some?.((part: any) => part?.type === "toolCall")) iterations += 1;
    });
    pi.on("tool_result", (event: any) => {
      if (event.toolName === "skill_manage" && !event.isError) iterations = 0;
    });
    pi.on("agent_end", (_event: any, ctx: any) => {
      const review = settings.review;
      const fork = ctx.sessionManager?.getSessionFile?.();
      if (!review.enabled || review.interval <= 0 || iterations < review.interval || !fork) return;
      if (!pi.getActiveTools().includes("skill_manage")) return;
      iterations = 0;
      startBackground(pi, { role: "review", prompt: prompts.skill_review_prompt + reviewSuffix, model: modelOf(ctx, review.model), fork, cwd: ctx.cwd });
    });
  }

  // Settings and records are read once per process, so the listing (and the cached prompt prefix) stays fixed.
  pi.on("session_start", async () => {
    settings = resolveSettings(pi.getSettings?.().hermesSkills, host.settings);
    index.budget = settings.index.budget ?? undefined;
    if (!settings.optimizer.enabled) pi.setActiveTools(pi.getActiveTools().filter((name: string) => name !== "skill_optimize"));
    if (!index.rank && !process.env.PI_SKILL_INDEX_RANK && store.all) {
      // Without records the index keeps Pi's order.
      index.rank = await store.all().then(rankFromRecords, () => undefined);
    }
  });
}

export default function (pi: any) {
  registerHermesSkills(pi);
}
