// Background passes run in a separate Pi process, as Hermes forks a review agent: the session's history (for a skill
// review) or a fresh session (for consolidation), with only the skill tools.
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { skillToolNames, type Role } from "./tools.ts";

const ROLE = "PI_HERMES_SKILLS_ROLE";
const TIMEOUT = "PI_HERMES_SKILLS_TIMEOUT_MS";
const SCRATCH = "PI_HERMES_SKILLS_SCRATCH";
const entry = fileURLToPath(new URL("./index.ts", import.meta.url));

/** The role of this process when a background pass started it. */
export const backgroundRole = () => (process.env[ROLE] === "review" || process.env[ROLE] === "curator" ? (process.env[ROLE] as Role) : undefined);

/**
 * Upstream's budgets for a pass: a review stops after 16 responses or when its input reaches 75% of the context window
 * (at most 600000 tokens, 120000 when unknown); consolidation stops after 100 responses. A host that supervises its own
 * passes sets the role without a timeout.
 */
export function enforceBudget(pi: any, role: Role) {
  let responses = 0;
  let input = 0;
  const limit = role === "curator" ? 100 : 16;
  const budget = (ctx: any) =>
    role === "curator" ? Infinity : ctx.model?.contextWindow > 0 ? Math.min(600_000, ctx.model.contextWindow * 0.75) : 120_000;
  const over = (ctx: any) => responses >= limit || input >= budget(ctx);
  pi.on("message_end", (event: any, ctx: any) => {
    if (event.message?.role !== "assistant") return;
    responses += 1;
    const usage = event.message.usage ?? {};
    input += (usage.input ?? 0) + (usage.cacheRead ?? 0) + (usage.cacheWrite ?? 0);
    if (over(ctx)) ctx.abort();
  });
  // Pi logs hook errors and continues; abort explicitly before another request.
  pi.on("before_provider_request", (_event: any, ctx: any) => {
    if (over(ctx)) ctx.abort();
  });
  const timeout = Number(process.env[TIMEOUT]);
  if (timeout > 0) {
    pi.on("session_start", (_event: any, ctx: any) => {
      setTimeout(() => {
        ctx.abort();
        setTimeout(() => process.exit(1), 5_000).unref();
      }, timeout).unref();
    });
  }
  const scratch = process.env[SCRATCH];
  if (scratch) process.on("exit", () => rmSync(scratch, { recursive: true, force: true }));
}

/** How to start Pi again from inside Pi: the same runtime and script, or the compiled executable itself. */
function piInvocation() {
  const script = process.argv[1];
  if (script && !script.startsWith("/$bunfs/root/") && existsSync(script)) return [process.execPath, script];
  return /^(node|bun)(\.exe)?$/.test(process.execPath.split("/").at(-1) ?? "") ? ["pi"] : [process.execPath];
}

/**
 * Starts a pass and returns at once; it outlives this session. `fork` copies a session file into a scratch directory that
 * the pass removes when it exits.
 */
export function startBackground(pi: any, options: { role: Role; prompt: string; model?: string; fork?: string; cwd: string }) {
  const scratch = mkdtempSync(join(tmpdir(), "pi-hermes-skills-"));
  const session = options.fork ? ["--fork", options.fork, "--session-dir", scratch] : ["--no-session"];
  // Loaded with `-e` rather than installed: the pass needs the same path.
  const loose = pi.getAllTools?.().find((tool: any) => tool.name === "skill_manage")?.sourceInfo?.origin === "top-level";
  const [command, ...prefix] = piInvocation();
  const args = [
    ...prefix, "--mode", "json", ...session, "--tools", skillToolNames.join(","),
    ...(options.model ? ["--model", options.model] : []), ...(loose ? ["-e", entry] : []), options.prompt,
  ];
  const timeout = options.role === "curator" ? 1_800_000 : 600_000;
  const child = spawn(command, args, {
    cwd: options.cwd, detached: true, stdio: "ignore",
    env: { ...process.env, [ROLE]: options.role, [TIMEOUT]: String(timeout), [SCRATCH]: scratch },
  });
  child.on("error", () => rmSync(scratch, { recursive: true, force: true }));
  child.unref();
}
