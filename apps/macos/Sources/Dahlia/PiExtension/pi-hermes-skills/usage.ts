// Skill usage records, as Hermes Agent's `tools/skill_usage.py` keeps them: one JSON map keyed by skill name.
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { curationGuard } from "./tools.ts";

export type UsageKind = "use" | "view" | "patch";

/** Hermes `_empty_record` fields that this package reads or writes. */
export interface SkillRecord {
  created_by: string | null;
  use_count: number;
  view_count: number;
  patch_count: number;
  last_used_at: string | null;
  last_viewed_at: string | null;
  last_patched_at: string | null;
  created_at: string | null;
  state: string;
  pinned: boolean;
  archived_at: string | null;
  /** Set by the user; no tool or background pass changes the skill. */
  locked?: boolean;
  /** Loaded by a scheduled task, so background passes never archive it. */
  scheduled?: boolean;
}

/** Where usage is kept. A host replaces it to keep records in its own database. */
export interface UsageStore {
  bump(name: string, kind: UsageKind): Promise<void>;
  /** Every record; without it the index keeps Pi's order and the Curator has nothing to manage. */
  all?(): Promise<Record<string, SkillRecord>>;
  /** Atomically merges fields (`null` forgets); compare `expected` inside the mutation boundary and return false if obsolete. */
  set?(name: string, fields: Partial<SkillRecord> | null, expected?: SkillRecord): Promise<void | boolean>;
  /** Moves an eligible account skill to `.archive/` and marks it archived; false skips an obsolete snapshot. */
  archive?(name: string, expected?: SkillRecord): Promise<void | boolean>;
}

const stamps: Record<UsageKind, [keyof SkillRecord, keyof SkillRecord]> = {
  use: ["use_count", "last_used_at"],
  view: ["view_count", "last_viewed_at"],
  patch: ["patch_count", "last_patched_at"],
};

export const emptyRecord = (now: string): SkillRecord => ({
  created_by: null, use_count: 0, view_count: 0, patch_count: 0,
  last_used_at: null, last_viewed_at: null, last_patched_at: null,
  created_at: now, state: "active", pinned: false, archived_at: null,
});

/** Pi's agent directory (`PI_CODING_AGENT_DIR`, else `~/.pi/agent`). */
export const agentDir = () => process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");

/**
 * `skills/.usage.json` in Pi's agent directory. Each change reads, edits and renames the file while holding
 * `.usage.json.lock`. A damaged file is an error, never reset to empty, so no record is silently lost.
 */
export function fileStore(path = join(agentDir(), "skills", ".usage.json")): Required<UsageStore> {
  const read = (): Record<string, SkillRecord> => {
    let text: string;
    try {
      text = readFileSync(path, "utf8");
    } catch (error: any) {
      if (error.code === "ENOENT") return {};
      throw error;
    }
    const data = JSON.parse(text.replace(/^\uFEFF/, ""));
    if (!data || typeof data !== "object" || Array.isArray(data)) throw new Error(`${path} does not hold a JSON object`);
    return data;
  };
  const matches = (record: SkillRecord | undefined, expected: SkillRecord | undefined) =>
    expected === undefined || JSON.stringify(record) === JSON.stringify(expected);
  const change = (edit: (data: Record<string, SkillRecord>, now: string) => void | boolean) => withLock(path, (write) => {
    const data = read();
    if (edit(data, new Date().toISOString()) === false) return false;
    write(JSON.stringify(data, null, 2) + "\n");
    return true;
  });
  const store: Required<UsageStore> = {
    all: async () => read(),
    bump: async (name, kind) => {
      await change((data, now) => {
        const record: any = { ...emptyRecord(now), ...data[name] };
        const [count, stamp] = stamps[kind];
        record[count] = (Number(record[count]) || 0) + 1;
        record[stamp] = now;
        data[name] = record;
      });
    },
    set: (name, fields, expected) => change((data, now) => {
      if (!matches(data[name], expected)) return false;
      if (fields === null) delete data[name];
      else data[name] = { ...emptyRecord(now), ...data[name], ...fields };
    }),
    archive: (name, expected) => withLock(path, (write) => {
      const data = read();
      if (!matches(data[name], expected)) return false;
      curationGuard(name, data[name]);
      const root = dirname(path);
      const archive = join(root, ".archive");
      mkdirSync(archive, { recursive: true });
      let destination = join(archive, name);
      if (existsSync(destination)) destination += "-" + new Date().toISOString().replace(/\D/g, "").slice(0, 14);
      renameSync(join(root, name), destination);
      try {
        data[name] = { ...data[name], state: "archived", archived_at: new Date().toISOString() };
        write(JSON.stringify(data, null, 2) + "\n");
      } catch (error) {
        renameSync(destination, join(root, name));
        throw error;
      }
      return true;
    }),
  };
  return store;
}

// shortcut: a lock older than 10 s is taken over (Node has no flock); two takers at once can both write. Upgrade to
// an fcntl lock if records are ever written that often.
/** Runs `change` while holding `<path>.lock`; `write` replaces the file by renaming a temporary copy. */
export async function withLock<T>(path: string, change: (write: (text: string) => void) => T): Promise<T> {
  mkdirSync(dirname(path), { recursive: true });
  const lock = `${path}.lock`;
  for (let attempt = 0; ; attempt++) {
    try {
      closeSync(openSync(lock, "wx"));
      break;
    } catch (error: any) {
      if (error.code !== "EEXIST") throw error;
      let age = 0;
      try {
        age = Date.now() - statSync(lock).mtimeMs;
      } catch {
        continue;
      }
      if (age > 10_000) rmSync(lock, { force: true });
      else if (attempt > 500) throw new Error(`${lock} is held by another process`);
      else await new Promise((done) => setTimeout(done, 20));
    }
  }
  try {
    return change((text) => {
      const temporary = `${path}.${process.pid}.tmp`;
      writeFileSync(temporary, text);
      renameSync(temporary, path);
    });
  } finally {
    rmSync(lock, { force: true });
  }
}

/** Names most recently used, viewed or first seen first; archived skills are left out. */
export function rankFromRecords(records: Record<string, SkillRecord>): string[] {
  const latest = (record: SkillRecord) =>
    Math.max(...[record.last_used_at, record.last_viewed_at, record.created_at].map((value) => Date.parse(value ?? "") || 0));
  return Object.entries(records)
    .filter(([, record]) => record && record.state !== "archived")
    .sort(([a, x], [b, y]) => latest(y) - latest(x) || a.localeCompare(b))
    .map(([name]) => name);
}

const validName = (name: string) => name.length <= 64 && /^[a-z0-9][a-z0-9._-]*$/.test(name);

/**
 * Counts a use when a skill reaches the prompt: `/skill:name`, or a successful `read` of a skill file listed by Pi.
 * `skill_view` counts itself where it is implemented.
 */
export function trackUsage(pi: any, store: UsageStore, skills: () => { name: string; filePath: string }[]) {
  const bump = (name: string) => void store.bump(name, "use").catch(() => {});
  const real = (path: string) => {
    try {
      return realpathSync(path);
    } catch {
      return path;
    }
  };
  pi.on("input", (event: any) => {
    const name = /^\/skill:(\S+)/.exec(event.text ?? "")?.[1];
    if (name && validName(name)) bump(name);
  });
  pi.on("tool_result", (event: any, ctx: any) => {
    const path = event.input?.path;
    if (event.toolName !== "read" || event.isError || typeof path !== "string") return;
    const file = real(resolve(ctx?.cwd ?? process.cwd(), path.replace(/^~(?=\/|$)/, homedir())));
    const skill = skills().find((candidate) => real(candidate.filePath) === file);
    if (skill) bump(skill.name);
  });
}
