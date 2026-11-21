// Hermes Agent's Curator (`agent/curator.py`): deterministic lifecycle transitions of the skills background passes
// created, and an optional LLM consolidation pass. Upstream's interval and idle checks belong to whoever schedules it.
import { existsSync, readdirSync, renameSync } from "node:fs";
import { join } from "node:path";
import type { SkillRecord, UsageStore } from "./usage.ts";

export interface CuratorSettings {
  enabled: boolean;
  staleAfterDays: number;
  archiveAfterDays: number;
  consolidate: boolean;
  /** `provider/id`; the session's model when null. */
  model: string | null;
}

export type CuratorCounts = { checked: number; markedStale: number; archived: number; reactivated: number; seeded: number };
export type CuratorReport = { counts: CuratorCounts; candidates: string | null };

const day = 86_400_000;
const time = (value: string | null | undefined) => (value ? Date.parse(value) : NaN);
/** The newest use, view or patch; creation is not activity. */
const lastActivity = (record: SkillRecord) => {
  const times = [record.last_used_at, record.last_viewed_at, record.last_patched_at].map(time).filter(Number.isFinite);
  return times.length > 0 ? Math.max(...times) : undefined;
};

/** Skills a background pass created whose package is still in the account directory. */
async function managed(store: UsageStore, root: string) {
  const records = (await store.all?.()) ?? {};
  return Object.entries(records)
    .filter(([name, record]) => record?.created_by === "agent" && existsSync(join(root, name, "SKILL.md")))
    .sort(([a], [b]) => a.localeCompare(b));
}

/** Upstream `apply_automatic_transitions`: no LLM; pinned, locked and scheduled skills are left alone. */
export async function applyTransitions(store: UsageStore, root: string, settings: CuratorSettings, now = Date.now()): Promise<CuratorCounts> {
  const staleCutoff = now - settings.staleAfterDays * day;
  const archiveCutoff = now - settings.archiveAfterDays * day;
  const counts: CuratorCounts = { checked: 0, markedStale: 0, archived: 0, reactivated: 0, seeded: 0 };
  const set = store.set ?? (() => Promise.reject(new Error("This store cannot change skill states.")));
  for (const [name, record] of await managed(store, root)) {
    counts.checked += 1;
    if (record.pinned || record.locked || record.scheduled) continue;
    const created = time(record.created_at);
    // A record without a creation time anchors its clock now and waits a full period.
    if (!Number.isFinite(created)) {
      if (await set(name, { created_at: new Date(now).toISOString() }, record) !== false) counts.seeded += 1;
      continue;
    }
    const anchor = lastActivity(record) ?? created;
    if ((record.use_count ?? 0) === 0 && anchor > staleCutoff) {
      if (record.state === "stale") {
        if (await set(name, { state: "active" }, record) !== false) counts.reactivated += 1;
      }
      continue;
    }
    if (anchor <= archiveCutoff && record.state !== "archived") {
      if (await (store.archive ?? (() => Promise.reject(new Error("This store cannot archive skills."))))(name, record) !== false) counts.archived += 1;
    } else if (anchor <= staleCutoff && record.state === "active") {
      if (await set(name, { state: "stale" }, record) !== false) counts.markedStale += 1;
    } else if (anchor > staleCutoff && record.state === "stale") {
      if (await set(name, { state: "active" }, record) !== false) counts.reactivated += 1;
    }
  }
  return counts;
}

/** Upstream `_render_candidate_list`, or null when no skill is managed. */
export async function renderCandidates(store: UsageStore, root: string): Promise<string | null> {
  const rows = await managed(store, root);
  if (rows.length === 0) return null;
  return [`Agent-created skills (${rows.length}):\n`, ...rows.map(([name, r]) => {
    const [use, view, patches] = [r.use_count ?? 0, r.view_count ?? 0, r.patch_count ?? 0];
    const last = lastActivity(r);
    return `- ${name}  provenance=agent  state=${r.state}  pinned=${r.pinned ? "yes" : "no"}  cron=${r.scheduled ? "yes" : "no"}  `
      + `activity=${use + view + patches}  use=${use}  view=${view}  patches=${patches}  `
      + `last_activity=${last === undefined ? "never" : new Date(last).toISOString().replace(/\.\d{3}Z$/, "Z")}`;
  })].join("\n");
}

/** Upstream `restore_skill`: the exact name first, then its newest timestamped duplicate. */
export async function restoreSkill(store: UsageStore, root: string, name: string) {
  const archive = join(root, ".archive");
  const entries = existsSync(archive) ? readdirSync(archive) : [];
  const duplicates = entries.filter((entry) => entry.startsWith(`${name}-`) && /^\d{14}$/.test(entry.slice(name.length + 1))).sort();
  const found = entries.includes(name) ? name : duplicates.at(-1);
  if (!found) throw new Error(`skill '${name}' not found in archive`);
  if (existsSync(join(root, name))) throw new Error(`destination already exists: ${join(root, name)}`);
  if ((await store.all?.())?.[name]?.locked) throw new Error("Skill is locked.");
  renameSync(join(archive, found), join(root, name));
  await store.set?.(name, { state: "active", archived_at: null });
}
