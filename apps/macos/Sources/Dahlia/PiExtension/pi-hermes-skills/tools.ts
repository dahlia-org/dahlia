// Hermes Agent's skill tools (`tools/skills_tool.py`, `tools/skill_manager_tool.py`) over Pi's account skills directory.
import { randomUUID } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { scanContent } from "./guard.ts";
import type { SkillRecord, UsageStore } from "./usage.ts";

export const skillToolSchemas: any[] = JSON.parse(readFileSync(new URL("./hermes/tools.json", import.meta.url), "utf8"));
export const skillToolNames = skillToolSchemas.map((schema) => schema.name as string);

/** Runs one skill tool and answers its JSON result. */
export type SkillToolExecutor = (name: string, args: any, ctx: any) => Promise<unknown>;

/** `review` and `curator` are background passes; they follow upstream's stricter rules. */
export type Role = "review" | "curator";

export function registerSkillTools(pi: any, execute: SkillToolExecutor) {
  for (const schema of skillToolSchemas) {
    pi.registerTool({
      ...schema,
      label: schema.name,
      execute: async (_id: string, args: any, _signal: AbortSignal, _update: unknown, ctx: any) => ({
        content: [{ type: "text", text: JSON.stringify(await execute(schema.name, args, ctx)) }],
      }),
    });
  }
}

type Snapshot = { files: Map<string, Buffer>; modes: Map<string, number> };
const MAX_FILE = 1_048_576;
const groups = ["references", "templates", "assets", "scripts"];
export const validName = (name: unknown): name is string =>
  typeof name === "string" && name.length <= 64 && /^[a-z0-9][a-z0-9._-]*$/.test(name) && name !== "." && name !== "..";

/** Every standalone writer uses the same account ownership and lock checks. */
export function assertWritableSkill(root: string, name: string, file: string | undefined, record: SkillRecord | undefined) {
  if (!validName(name)) throw new Error("Invalid skill name (lowercase, max 64 characters).");
  if (record?.locked) throw new Error("Skill is locked. Unlock it before changing it.");
  const real = (path: string) => existsSync(path) ? realpathSync(path) : path;
  if (file && real(file) !== join(real(root), name, "SKILL.md")) {
    throw new Error("Bundled and package skills are read-only. Create an account skill under a different name.");
  }
}

/**
 * Skills in `root` are the account's and writable; skills Pi lists from elsewhere are read-only. A background pass
 * (`role`) must view a file before changing it, archives instead of deleting, and, as the Curator, touches only
 * unprotected skills it manages.
 */
export function fileSkillTools(options: {
  root: string;
  store: UsageStore;
  skills: () => { name: string; filePath: string }[];
  role?: Role;
  /** A proposal may replace only the content it was derived from. Checked after the record store is read. */
  expected?: { name: string; content: string };
}): SkillToolExecutor {
  const { root, store, role } = options;
  const fresh = new Map<string, string>();

  const catalog = () => {
    const files = new Map(options.skills().filter((skill) => existsSync(skill.filePath)).map((skill) => [skill.name, skill.filePath]));
    for (const name of existsSync(root) ? readdirSync(root) : []) {
      if (validName(name) && !files.has(name) && existsSync(join(root, name, "SKILL.md"))) files.set(name, join(root, name, "SKILL.md"));
    }
    return files;
  };
  const records = async () => (await store.all?.()) ?? {};

  return async (tool, args, _ctx) => {
    const skills = catalog();
    if (tool === "skills_list") {
      const names = args?.category ? [] : [...skills.keys()].sort();
      return {
        success: true,
        skills: names.map((name) => ({ name, description: description(readText(skills.get(name)!, dirname(skills.get(name)!))) ?? "" })),
        categories: [], count: names.length, hint: "Use skill_view(name) to see full content, tags, and linked files",
      };
    }
    if (tool === "skill_view") {
      const file = skills.get(args?.name);
      if (!file) throw new Error("Skill not found. Use skills_list first.");
      const directory = dirname(file);
      const path = args.file_path ?? "SKILL.md";
      const target = path === "SKILL.md" ? file : supportingPath(path, directory);
      const text = readText(target, directory);
      if (role) fresh.set(`${args.name}/${path}`, text);
      // Upstream counts a view as use too; the Curator's own reads would restart every clock it inspects.
      if (role !== "curator") await Promise.all([store.bump(args.name, "view"), store.bump(args.name, "use")]).catch(() => {});
      return {
        success: true, name: args.name, description: description(text) ?? "", content: text, path: target, skill_dir: directory,
        linked_files: linkedFiles(directory),
        usage_hint: "To view linked files, call skill_view(name, file_path) where file_path is e.g. 'references/api.md' or 'assets/config.yaml'",
      };
    }
    if (tool !== "skill_manage") throw new Error("Unknown skill tool.");

    const operations = args?.operations;
    if (!Array.isArray(operations) || operations.length === 0) throw new Error("Expected a nonempty operations array.");
    if (operations.length > 1 && operations.some((op: any) => op?.action === "delete")) throw new Error("delete must be the sole operation.");
    // A damaged record store fails the change: it holds the locks.
    const known = await records();
    const before = new Map<string, Snapshot | null>();
    const working = new Map<string, Map<string, Buffer>>();
    for (const op of operations) {
      const { name, action } = op ?? {};
      if (!validName(name) || typeof action !== "string") throw new Error("Invalid skill operation or name (lowercase, max 64 characters).");
      const listed = skills.get(name);
      assertWritableSkill(root, name, listed, known[name]);
      const directory = join(root, name);
      if (!before.has(name)) {
        const snapshot = existsSync(directory) ? readPackage(directory) : null;
        if (options.expected?.name === name && snapshot?.files.get("SKILL.md")?.toString("utf8") !== options.expected.content) {
          throw new Error("The skill changed during optimization; optimize it again.");
        }
        before.set(name, snapshot);
        working.set(name, new Map(snapshot?.files ?? []));
      }
      const files = working.get(name)!;
      const path = op.file_path ?? "SKILL.md";
      if (path !== "SKILL.md") supportingPath(path, directory);
      if (action !== "create" && !files.has("SKILL.md")) throw new Error("Skill not found. Create it first.");
      if (role && action !== "create") {
        const original = before.get(name)?.files.get(path);
        if (original && fresh.get(`${name}/${path}`) !== original.toString("utf8")) {
          throw new Error("Read the current target file with skill_view during this review before changing it.");
        }
        if (action === "delete") deleteGuard(name, op.absorbed_into, known[name], skills);
      }
      if (role === "curator" && action !== "create" && before.get(name) !== null) curationGuard(name, known[name]);
      if (action === "delete" && known[name]?.pinned) {
        throw new Error(`Skill '${name}' is pinned and cannot be deleted by skill_manage. Ask the user to unpin it if they want to delete it. Patches and edits are allowed on pinned skills; only deletion is blocked.`);
      }
      apply(op, action, path, files);
      validate(files, name);
    }
    // Recheck external edits immediately before replacing the packages.
    for (const [name, original] of before) {
      const directory = join(root, name);
      const current = existsSync(directory) ? readPackage(directory) : null;
      if (!samePackage(current, original)) throw new Error("Skill changed while editing. Read it again and retry.");
    }
    const deleted = [...working].find(([, files]) => files.size === 0)?.[0];
    if (role && deleted) {
      // Autonomous deletes stay recoverable: upstream archives them instead of removing the package.
      await (store.archive ?? (() => Promise.reject(new Error("This store cannot archive skills."))))(deleted);
      return { success: true, message: `Skill '${deleted}' archived. Content absorbed into '${operations[0].absorbed_into ?? ""}'.` };
    }
    const replaced: string[] = [];
    try {
      for (const [name, files] of working) {
        replace(join(root, name), files, before.get(name)?.modes);
        replaced.push(name);
      }
    } catch (error) {
      for (const name of replaced) {
        const original = before.get(name);
        replace(join(root, name), original?.files ?? new Map(), original?.modes);
      }
      throw error;
    }
    const now = new Date().toISOString();
    for (const [name, files] of working) {
      const original = before.get(name);
      if (!original) {
        // Only background passes hand a skill to the Curator.
        await store.set?.(name, {
          created_by: role ? "agent" : "learn", created_at: now, use_count: 0, view_count: 0, patch_count: 0,
          last_used_at: null, last_viewed_at: null, last_patched_at: null, state: "active", pinned: false, archived_at: null,
        });
      } else if (files.size === 0) {
        await store.set?.(name, null);
      } else {
        await store.bump(name, "patch").catch(() => {});
      }
    }
    return { success: true, message: "Skill operations saved atomically." };
  };
}

// skill_manager_guards.py `_background_review_delete_guard` and the `absorbed_into` checks of `_delete_skill`.
function deleteGuard(name: string, absorbedInto: unknown, record: SkillRecord | undefined, skills: Map<string, string>) {
  if (record?.created_by !== "agent") throw new Error("Autonomous deletion is limited to agent-created skills.");
  if (record.scheduled) throw new Error(`Skill '${name}' is used by a scheduled task. Autonomous maintenance cannot archive it; keep it active.`);
  const target = typeof absorbedInto === "string" ? absorbedInto.trim() : "";
  if (!target) {
    throw new Error(`Refusing background curator delete of skill '${name}': the consolidation pass may only archive a skill it has absorbed into an umbrella. Pass absorbed_into=<umbrella> (the umbrella must already exist) to record a verified consolidation. Pruning a skill with no forwarding target is not permitted here — the deterministic inactivity prune handles staleness archival separately. Keeping '${name}' active.`);
  }
  if (target === name) throw new Error(`absorbed_into='${target}' cannot equal the skill being deleted.`);
  if (!skills.has(target)) throw new Error(`absorbed_into='${target}' does not exist. Create or patch the umbrella skill first, then retry the delete.`);
}

/** The Curator changes only the unprotected skills it manages. */
export function curationGuard(name: string, record: SkillRecord | undefined) {
  if (record?.created_by !== "agent" || record.pinned || record.locked) throw new Error("Curator cannot change a user-created, pinned, or locked skill.");
  if (record.scheduled) throw new Error("Curator cannot change a skill used by a scheduled task.");
}

function apply(op: any, action: string, path: string, files: Map<string, Buffer>) {
  switch (action) {
    case "create":
      if (files.size > 0 || typeof op.content !== "string") throw new Error("Skill already exists or create content missing.");
      files.set("SKILL.md", Buffer.from(op.content));
      return;
    case "patch": {
      if (typeof op.content === "string") {
        if (path !== "SKILL.md") throw new Error("Full rewrite applies only to SKILL.md.");
        files.set(path, Buffer.from(op.content));
        return;
      }
      const content = files.get(path)?.toString("utf8");
      const old = op.old_string;
      if (typeof old !== "string" || !old || typeof op.new_string !== "string" || content === undefined || !content.includes(old)) {
        throw new Error("old_string must match the current file.");
      }
      if (op.replace_all !== true && content.split(old).length !== 2) throw new Error("old_string is ambiguous.");
      files.set(path, Buffer.from(content.split(old).join(op.new_string)));
      return;
    }
    case "write_file":
      if (path === "SKILL.md" || typeof op.file_content !== "string") throw new Error("Use patch for SKILL.md; write_file requires file_content.");
      files.set(path, Buffer.from(op.file_content));
      return;
    case "remove_file":
      if (path === "SKILL.md" || !files.delete(path)) throw new Error("Supporting file not found.");
      return;
    case "delete":
      files.clear();
      return;
    default:
      throw new Error("Use create, patch, write_file, remove_file, or delete.");
  }
}

function frontmatter(text: string): string[] | null {
  const lines = text.split(/\r?\n/);
  const end = lines.indexOf("---", 1);
  return lines[0] === "---" && end > 0 ? lines.slice(1, end) : null;
}

/** The frontmatter `description`, as a scalar or a block. */
export function description(text: string): string | null {
  const lines = frontmatter(text);
  const index = lines?.findIndex((line) => line.startsWith("description:")) ?? -1;
  if (!lines || index < 0) return null;
  const value = lines[index].slice(12).trim();
  if ([">", "|", ">-", "|-", ">+", "|+"].includes(value)) {
    const block = [];
    for (const line of lines.slice(index + 1)) {
      if (line && !/^\s/.test(line)) break;
      block.push(line.trim());
    }
    return block.join("\n");
  }
  return value.replace(/^["']+|["']+$/g, "");
}

const count = (text: string) => [...text].length;

function validate(files: Map<string, Buffer>, name: string) {
  if (files.size === 0) return;
  const text = files.get("SKILL.md")?.toString("utf8");
  const about = text === undefined ? null : description(text);
  const named = text !== undefined && frontmatter(text)?.some((line) => [`name: ${name}`, `name: "${name}"`, `name: '${name}'`].includes(line));
  if (text === undefined || count(text) > 100_000
    || !about || count(about) > 1024 || !named) {
    throw new Error("SKILL.md requires matching name and description YAML frontmatter (description ≤1024, content ≤100000 characters).");
  }
  for (const [path, content] of files) {
    if (path !== "SKILL.md" && content.length > MAX_FILE) throw new Error("Supporting file exceeds 1 MiB.");
    const decoded = new TextDecoder("utf-8", { fatal: true });
    let utf8: string | undefined;
    try {
      utf8 = decoded.decode(content);
    } catch {}
    if (utf8 !== undefined) scanContent(utf8);
  }
}

function supportingPath(path: unknown, directory: string) {
  const parts = typeof path === "string" ? path.split("/") : [];
  if (parts.length < 2 || !groups.includes(parts[0]) || parts.some((part) => part === "" || part === "." || part === "..")) {
    throw new Error("Use a relative supporting path under references/, templates/, scripts/, or assets/.");
  }
  const target = join(directory, ...parts);
  if (existsSync(target) && !realpathSync(target).startsWith(realpathSync(directory) + sep)) {
    throw new Error("Symbolic links are not supported in managed skills.");
  }
  return target;
}

function readText(file: string, directory: string) {
  if (!realpathSync(file).startsWith(realpathSync(directory) + sep)) throw new Error("Skill path escapes its directory.");
  if (statSync(file).size > MAX_FILE) throw new Error("Supporting files are limited to 1 MiB.");
  return readFileSync(file, "utf8");
}

function walk(directory: string, visit: (path: string) => void) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isSymbolicLink()) throw new Error("Symbolic links are unsupported in managed skills.");
    if (entry.isDirectory()) walk(path, visit);
    else if (entry.isFile()) visit(path);
  }
}

function linkedFiles(directory: string) {
  const linked: Record<string, string[]> = {};
  for (const group of groups) {
    const base = join(directory, group);
    if (!existsSync(base)) continue;
    const paths: string[] = [];
    walk(base, (path) => paths.push(relative(directory, path)));
    if (paths.length > 0) linked[group] = paths.sort();
  }
  return linked;
}

function readPackage(directory: string): Snapshot {
  if (lstatSync(directory).isSymbolicLink()) throw new Error("Symbolic skill directories are unsupported.");
  const snapshot: Snapshot = { files: new Map(), modes: new Map() };
  walk(directory, (path) => {
    const stat = statSync(path);
    if (stat.size > MAX_FILE) throw new Error("Supporting files are limited to 1 MiB.");
    const key = relative(directory, path).split(sep).join("/");
    snapshot.files.set(key, readFileSync(path));
    snapshot.modes.set(key, stat.mode & 0o777);
  });
  return snapshot;
}

function samePackage(a: Snapshot | null, b: Snapshot | null) {
  if (!a || !b) return a === b;
  return a.files.size === b.files.size && [...a.files].every(([path, data]) => b.files.get(path)?.equals(data) && a.modes.get(path) === b.modes.get(path));
}

/** Writes the whole package beside the old one and swaps it in, keeping unchanged files' permissions. */
function replace(directory: string, files: Map<string, Buffer>, modes?: Map<string, number>) {
  const parent = dirname(directory);
  mkdirSync(parent, { recursive: true, mode: 0o700 });
  if (files.size === 0) return rmSync(directory, { recursive: true, force: true });
  const staging = join(parent, `.skill-${randomUUID()}`);
  try {
    for (const [path, data] of files) {
      const target = join(staging, ...path.split("/"));
      mkdirSync(dirname(target), { recursive: true });
      writeFileSync(target, data);
      chmodSync(target, modes?.get(path) ?? 0o644);
    }
    const old = existsSync(directory) ? join(parent, `.skill-${randomUUID()}`) : null;
    if (old) renameSync(directory, old);
    try {
      renameSync(staging, directory);
    } catch (error) {
      if (old) renameSync(old, directory);
      throw error;
    }
    if (old) rmSync(old, { recursive: true, force: true });
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
}
