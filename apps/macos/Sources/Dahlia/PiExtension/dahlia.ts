// Dahlia's Pi extension. Dahlia owns every policy decision; this file only forwards them to Pi.
// Requests to Dahlia travel over the RPC extension-UI channel: `ctx.ui.input("dahlia:<method>", <JSON>)`.
import { createBashTool, createEditTool, createLsTool, createReadTool, createWriteTool, DefaultPackageManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { anthropicMessagesApi, createProvider, googleGenerativeAIApi, openAIResponsesApi } from "@earendil-works/pi-ai";
import { execFile } from "node:child_process";
import { existsSync, lstatSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import {
  registerDatabricksConnectionLoginCommand,
  registerDatabricksLoginCommand,
  registerDatabricksMCPServicesCommand,
  registerDatabricksModelServicesCommand,
  registerDatabricksProviders,
} from "./databricks-provider.ts";

import { omnigentTools, registerThreadTools, threadTools } from "./thread-tools.ts";
import { botTools, registerBotTools, registerEventTools } from "./event-tools.ts";
import { registerLearningTools, learningTools } from "./learning-tools.ts";
import { reviewMCP } from "./mcp-review.ts";
import { learnTemplatePath, registerHermesSkills } from "./pi-hermes-skills/index.ts";

const env = process.env;
const mode = env.DAHLIA_PI_MODE ?? "control";
const bridgedProviders = (env.DAHLIA_PI_BRIDGED_PROVIDERS ?? "").split(",").filter(Boolean);
// The APIs of the models Dahlia writes to models.json for bridged providers (Databricks routes and the Dahlia Server).
const bridgedAPIs = {
  "anthropic-messages": anthropicMessagesApi,
  "google-generative-ai": googleGenerativeAIApi,
  "openai-responses": openAIResponsesApi,
};
const outputSchema = env.PI_OUTPUT_JSON_SCHEMA ? JSON.parse(readFileSync(env.PI_OUTPUT_JSON_SCHEMA, "utf8")) : undefined;
// Keywords each API rejects (Claude answers 400) or does not document; Dahlia validates the reply after decoding.
const claudeUnsupported = new Set(["minLength", "maxLength", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "maxItems"]);
const geminiUnsupported = new Set(["minLength", "maxLength", "pattern"]);

// Removes schema keywords, but never property names that happen to spell one.
function stripped(schema: any, drop: (key: string, value: any) => boolean, isPropertyMap = false): any {
  if (Array.isArray(schema)) return schema.map((item) => stripped(item, drop));
  if (typeof schema !== "object" || schema === null) return schema;
  return Object.fromEntries(Object.entries(schema)
    .filter(([key, value]) => isPropertyMap || !drop(key, value))
    .map(([key, value]) => [key, stripped(value, drop, !isPropertyMap && ["properties", "$defs", "definitions"].includes(key))]));
}

// The request body change that enforces the schema, for each API that takes one.
const strictSchemaPayload: Record<string, (payload: any) => any> = {
  "openai-responses": openAIFormat,
  "openai-codex-responses": openAIFormat,
  // Claude also takes `minItems` 0 or 1 only. Pi may already set `output_config.effort`.
  "anthropic-messages": (payload) => ({
    ...payload,
    output_config: {
      ...(payload.output_config ?? {}),
      format: {
        type: "json_schema",
        schema: stripped(outputSchema, (key, value) => claudeUnsupported.has(key) || (key === "minItems" && value > 1)),
      },
    },
  }),
  // Pi's Google SDK request: `config` becomes `generationConfig` on the wire.
  "google-generative-ai": (payload) => ({
    ...payload,
    config: {
      ...payload.config,
      responseMimeType: "application/json",
      responseJsonSchema: stripped(outputSchema, (key) => geminiUnsupported.has(key)),
    },
  }),
};

function openAIFormat(payload: any) {
  const format = { type: "json_schema", name: "dahlia_output", strict: true, schema: outputSchema };
  return { ...payload, text: { ...(payload.text ?? {}), format } };
}
const readOnlyDahliaTool = /^mcp__dahlia__(get|query|list|search)_/;
// The MCP servers Dahlia registered for this chat (its own and the user's); any other server is blocked.
const chatMcpServers = new Set<string>(JSON.parse(env.DAHLIA_PI_MCP_SERVERS ?? "[]"));
// The extension that connects MCP servers: Pi's own, or pi-mcp-elicitation in its place. Pi names it as the tools' source.
const mcpExtension = env.DAHLIA_PI_MCP_EXTENSION || "builtin:mcp";

async function bridge(ctx: any, method: string, payload: unknown): Promise<any> {
  const value = await ctx.ui.input(`dahlia:${method}`, JSON.stringify(payload));
  if (value === undefined) throw new Error(`Dahlia did not answer ${method}`);
  return JSON.parse(value);
}

// The context Dahlia attaches to a chat message (as in mcp-review.ts) is not what the user asked.
export const stripAmbient = (text: string) => text
  .replace(/^<context>\n[\s\S]*?<\/context>\s*/, "")
  .replace(/<(thread_request|thread_results) source="dahlia" untrusted="true">[\s\S]*?<\/\1>/g, "")
  .replace(/<live_transcript(?: source="dahlia")?>[\s\S]*?<\/live_transcript>/g, "")
  .trim();

// Pi follows links while discovering skills outside Seatbelt. Only offer ordinary account skill files.
function accountSkillPaths(directory: string, root = true): string[] {
  try {
    if (!lstatSync(directory).isDirectory()) return [];
    const entries = readdirSync(directory, { withFileTypes: true });
    if (entries.some((entry) => entry.name === "SKILL.md" && entry.isFile())) return [join(directory, "SKILL.md")];
    return entries.flatMap((entry) => {
      if (entry.name.startsWith(".") || entry.name === "node_modules" || entry.isSymbolicLink()) return [];
      const path = join(directory, entry.name);
      if (entry.isDirectory()) return accountSkillPaths(path, false);
      return root && entry.isFile() && entry.name.endsWith(".md") ? [path] : [];
    });
  } catch (error: any) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
}

export default async function (pi: any) {
  // A bridged provider's credential is Dahlia's token, resolved for each use: every model request, and every request
  // of an MCP whose mcp.json entry names the provider in `auth.provider`. Its models come from models.json.
  let bridgeContext: any;
  pi.on("session_start", (_event: any, ctx: any) => {
    bridgeContext = ctx;
  });
  for (const provider of bridgedProviders) {
    pi.registerProvider(createProvider({
      id: provider,
      auth: {
        apiKey: {
          name: provider,
          // Pi checks availability (model listing) before the session starts; no request is sent with this value.
          resolve: async () => ({ auth: { apiKey: bridgeContext ? await bridge(bridgeContext, "token", { provider }) : "unresolved" } }),
        },
      },
      models: [],
      api: bridgedAPIs,
    }));
  }

  // Unity AI Gateway sign-ins serve chat's MCP servers and every process's models.
  registerDatabricksProviders(pi, bridgedProviders);

  // Native MCP connects every configured server before tool hooks. Dahlia supplies this process's scope here;
  // the shared mcp.json stays empty so another chat cannot change what this process starts.
  const failedMcpServers: string[] = [];
  for (const [name, config] of Object.entries(JSON.parse(env.DAHLIA_PI_MCP_CONFIG ?? "{}"))) {
    if (!chatMcpServers.has(name)) continue;
    try {
      pi.registerMcpServer(name, config);
    } catch {
      // A malformed connector must not prevent sandbox and approval hooks below from being installed.
      // Do not expose the rejected configuration or exception: either may contain credentials.
      failedMcpServers.push(name);
    }
  }
  pi.on("session_start", (_event: any, ctx: any) => {
    for (const name of failedMcpServers) ctx.ui.notify(`Unable to register MCP server ${name}. Check its connector settings.`, "error");
  });

  pi.on("before_provider_request", (event: any, ctx: any) => {
    let payload = event.payload;
    // Responses can make optional arguments required when Gateway providers omit strict.
    if (ctx.model?.api === "openai-responses" && payload.tools) {
      payload = { ...payload, tools: payload.tools.map((tool: any) =>
        tool.type === "function" && tool.strict === undefined ? { ...tool, strict: false } : tool) };
    }
    const enforce = strictSchemaPayload[ctx.model?.api];
    return outputSchema && env.PI_OUTPUT_STRICT_SCHEMA === "1" && enforce ? enforce(payload) : payload;
  });

  if (mode === "chat" || mode === "skills") {
    // Keep automatic discovery disabled (it includes ~/.agents/skills); use only this account's resources.
    pi.on("resources_discover", async (event: any) => {
      const agentDir = env.PI_CODING_AGENT_DIR!;
      const settingsManager = SettingsManager.create(event.cwd, agentDir, { projectTrusted: false });
      const resources = await new DefaultPackageManager({ cwd: event.cwd, agentDir, settingsManager }).resolve(async () => "skip");
      const paths = (entries: typeof resources.skills) => entries
        .filter((entry) => entry.enabled && entry.metadata.origin === "package" && entry.metadata.scope === "user")
        .map((entry) => entry.path);
      return {
        skillPaths: [...accountSkillPaths(join(agentDir, "skills")), ...paths(resources.skills)],
        promptPaths: [learnTemplatePath, ...paths(resources.prompts)],
      };
    });
  }

  // Review and Curator processes reuse chat's skills, so every mode that lists skills gets the budgeted index.
  // Skill files, usage and Curator state belong to Dahlia's AgentSkillService (`agent_skill_states`); the package only
  // detects uses and, in a Curator process, applies the transitions through it. Dahlia schedules reviews and consolidation.
  const curatorProcess = mode === "chat" && env.DAHLIA_PI_PROFILE === "review" && env.DAHLIA_PI_CURATOR === "1";
  const store = (action: string, fields: object = {}) => bridge(bridgeContext, "skillStore", { action, ...fields });
  registerHermesSkills(pi, {
    // Chat passes the order it computed at launch; other processes keep Pi's order.
    rank: (env.PI_SKILL_INDEX_RANK ?? "").split(",").filter(Boolean),
    store: curatorProcess
      ? { bump: async () => {}, all: () => store("all"), set: (name, fields, expected) => store("set", { name, fields, expected }), archive: (name, expected) => store("archive", { name, expected }) }
      : { bump: async (name, kind) => { if (mode === "chat" && bridgeContext) await bridge(bridgeContext, "skillUsage", { name, kind }); } },
    tools: mode === "chat" ? (name, args, ctx) => bridge(ctx, name, args) : false,
    role: env.DAHLIA_PI_PROFILE === "review" ? (env.DAHLIA_PI_CURATOR === "1" ? "curator" : "review") : undefined,
    review: false,
    curator: curatorProcess ? { report: (ctx, report) => bridge(ctx, "curatorReport", report) } : false,
    settings: curatorProcess ? { curator: JSON.parse(env.DAHLIA_PI_CURATOR_SETTINGS ?? "{}") } : undefined,
    guidance: false,
    optimizer: mode !== "chat" ? false : {
      description: "Optimize an account skill's SKILL.md with GEPA (hermes-agent-self-evolution): build evaluation examples from "
        + "this account's conversations, evolve the instructions, and stage a better-scoring version for the user's approval in "
        + "Settings → Skills. Nothing changes until the user approves. A run takes minutes and hundreds of model calls; start it "
        + "only when the user asks. Pass the user's extra requirements for the rewrite as `focus`.",
      begin: async (ctx, name) => {
        const input = await bridge(ctx, "optimizerInput", { name });
        if (input?.success === false) throw new Error(input.error);
        const messages = input.messages.map((m: any) => ({ ...m, task_input: stripAmbient(m.task_input ?? "") }));
        return { raw: input.raw, messages, token: input.run_id };
      },
      finish: (ctx, run, outcome) => bridge(ctx, "optimizerResult", { run_id: run.token, name: run.name, ...outcome }),
    },
    learn: mode !== "chat" ? false : {
      agent: "Dahlia",
      tools: ["bash", "read", "ls", "write", "edit", "cronjob", "memory", "skill_view", "skill_manage"],
    },
  });

  if (mode === "chat") {
    pi.registerTool({
      name: "dah_create_backup",
      label: "Create Dahlia backup",
      description: "Create a verified tar.gz backup of the specified Local Workspace in this chat's account using Dahlia's GUI backup service. Returns a local file path for MCP upload. Excludes audio and Server Workspaces.",
      parameters: { type: "object", properties: { workspace_id: { type: "string", description: "Workspace TypeID (ws_...) to back up." } }, required: ["workspace_id"], additionalProperties: false },
      execute: async (_id: string, params: unknown, _signal: AbortSignal, _update: unknown, ctx: any) => ({
        content: [{ type: "text", text: JSON.stringify(await bridge(ctx, "createBackup", params)) }],
      }),
    });
    registerThreadTools(pi, bridge);
    registerThreadTools(pi, bridge, omnigentTools);
    if ((env.DAHLIA_PI_PROFILE ?? "interactive") === "intake") registerEventTools(pi, bridge);
    registerBotTools(pi, bridge, env.DAHLIA_PI_PROFILE ?? "interactive");
    let blockedThisRun = false;
    pi.on("agent_start", () => { blockedThisRun = false; });
    const block = (reason: string) => {
      blockedThisRun = true;
      return { block: true, reason };
    };
    const approve = async (ctx: any, name: string, payload: any, confirmFullAccess = false) => {
      // Use the same native bounds and registered-server checks for AI, manual and Full access decisions.
      if (await bridge(ctx, "approvalCheck", payload) !== true) return block("This tool call cannot be approved.");
      // Dahlia owns the approval mode; asking per call applies a change made during the turn to the next tool.
      const approvalMode = await bridge(ctx, "approvalMode", {});
      if (approvalMode === "fullAccess" && !confirmFullAccess) return;
      let reason: string | undefined = payload.reason;
      if (approvalMode === "autoReview") {
        const model = await bridge(ctx, "reviewModel", {});
        // Only the reviewer sees earlier denials; a classifier cannot approve a workaround in this run.
        const triage = blockedThisRun ? null : await bridge(ctx, "reviewTriage", {});
        const verdict = await reviewMCP(ctx, name, payload.arguments, model, triage);
        if (ctx.signal?.aborted) return block("MCP AI review was cancelled.");
        if (verdict.outcome === "allow" && verdict.risk !== "unknown") return;
        if (verdict.risk === "critical") {
          return block(`MCP AI review blocked a critical action: ${verdict.reason}`);
        }
        reason = `MCP AI review ${verdict.risk === "unknown" ? "failed" : "requires your approval"}: ${verdict.reason}`;
      }
      const decision = await bridge(ctx, "approval", { ...payload, reason });
      if (decision !== "accept") return block("The user declined this tool call.");
      return;
    };
    registerLearningTools(pi, bridge, approve, mcpExtension);
    if (env.DAHLIA_PI_MCP_COMMAND) {
      const [command, ...args] = JSON.parse(env.DAHLIA_PI_MCP_COMMAND);
      pi.registerMcpServer("dahlia", { command, args, exposure: "direct", description: "Dahlia meetings, projects, and workspaces" });
    }
    const webServer = "dahlia_web_access";
    const webSandbox: string[] = JSON.parse(env.DAHLIA_PI_WEB_SANDBOX ?? "[]");
    const webEnabled = (env.DAHLIA_PI_PROFILE ?? "interactive") === "interactive"
      && !!env.DAHLIA_PI_WEB_ACCESS && !!env.DAHLIA_PI_WEB_NODE && webSandbox.length > 0;
    if (webEnabled) {
      const scratch = join(env.PI_CODING_AGENT_DIR!, "web-access-runtime");
      // A PATH entry can be a version-manager shim. Ask Node for its actual interpreter before applying the
      // worker sandbox; compiled Pi executables (including managed Pi) are never used as JS interpreters.
      const node = await new Promise<string>((resolve, reject) => {
        execFile(env.DAHLIA_PI_WEB_NODE!, ["--print", "process.execPath"], { timeout: 5000, encoding: "utf8" },
          (error, stdout) => error ? reject(error) : resolve(stdout.trim()));
      });
      const command = webSandbox.map((arg) => arg.startsWith("NODE=") ? `NODE=${node}`
        : arg.startsWith("NODE_RUNTIME=") ? `NODE_RUNTIME=${dirname(node)}` : arg);
      // The worker and every extractor child inherit Seatbelt. Start with an empty environment: host CLI tokens,
      // browser-cookie opt-ins, cloud sign-ins and Node preload hooks must not leak into this account's web tools.
      pi.registerMcpServer(webServer, {
        command: command[0],
        args: [...command.slice(1), "/usr/bin/env", "-i", `HOME=${scratch}`, `TMPDIR=${scratch}`,
          `PI_CODING_AGENT_DIR=${env.PI_CODING_AGENT_DIR}`, `PATH=${env.PATH ?? "/usr/bin:/bin"}`,
          node, env.DAHLIA_PI_WEB_ACCESS],
        exposure: "direct", description: "Web search and public page fetching",
      });
    }

    // Everything chat does on this Mac's disk runs under Seatbelt (pi.sb): bash commands, and the file operations of
    // `read`, `ls`, `write`, and `edit`, so the kernel decides each path as it is opened and a symlink cannot lead outside.
    // Pi itself stays outside the sandbox, so nothing chat runs can read Pi's sign-ins or talk to its MCP servers.
    const sandbox: string[] = JSON.parse(env.DAHLIA_PI_SANDBOX ?? "[]");
    // The MCP snapshot may contain literal credentials; only the native MCP client may receive it.
    const hidden: string[] = ["DAHLIA_PI_MCP_CONFIG", ...JSON.parse(env.DAHLIA_PI_SANDBOX_HIDDEN_ENV ?? "[]")];
    const sandboxEnv = (env: NodeJS.ProcessEnv) => Object.fromEntries(Object.entries(env).filter(([key]) => !hidden.includes(key)));
    // The real home and temporary folders are out of reach in the sandbox, which gets one folder of its own for both
    // (tools such as git keep their settings there). They are set inside the sandbox only: the shell Pi starts a
    // command with runs outside it, and Pi loads code from its own TMPDIR.
    const home = env.DAHLIA_PI_SANDBOX_TMPDIR ?? process.cwd();
    const inSandbox = (args: string[]) => [...sandbox, "/usr/bin/env", `HOME=${home}`, `TMPDIR=${home}`, ...args];
    const sandboxed = (args: string[], input?: string) => new Promise<Buffer>((resolve, reject) => {
      const options = { encoding: "buffer" as const, maxBuffer: 1 << 30, env: sandboxEnv(process.env) };
      const [command, ...rest] = inSandbox(args);
      const child = execFile(command, rest, options, (error, stdout, stderr) =>
        error ? reject(new Error(stderr.toString().trim() || error.message)) : resolve(stdout));
      // A command the sandbox stops exits without reading its input; the callback above reports that failure.
      child.stdin?.on("error", () => {});
      child.stdin?.end(input);
    });
    // File operations receive Pi's resolved paths, after @/tilde expansion. Runtime read exceptions are not model access.
    const checkFilePath = (path: string, writing = false) => {
      if (env.DAHLIA_PI_PROFILE !== "bot") return;
      let ancestor = resolve(path);
      for (;;) {
        try { ancestor = realpathSync(ancestor); break; }
        catch (error: any) {
          if (error.code !== "ENOENT" || dirname(ancestor) === ancestor) throw error;
          ancestor = dirname(ancestor);
        }
      }
      const root = realpathSync(process.cwd());
      const suffix = relative(root, ancestor);
      if (suffix === ".." || suffix.startsWith("../") || isAbsolute(suffix)) throw new Error("Super Agent file tools only access its home.");
      if (writing && dirname(ancestor) === root && ["AGENTS.md", "agent.json", "SOUL.md"].includes(basename(ancestor))) {
        throw new Error("AGENTS.md and agent.json belong to Dahlia, and SOUL.md changes only through soul_write.");
      }
    };
    const fileOperation = (path: string, args: string[], input?: string, writing = false) => {
      checkFilePath(path, writing);
      return sandboxed(args, input);
    };
    const files = {
      readFile: (path: string) => fileOperation(path, ["/bin/cat", "--", path]),
      writeFile: async (path: string, content: string) => void await fileOperation(path, ["/bin/sh", "-c", 'cat > "$1"', "sh", path], content, true),
      mkdir: async (path: string) => void await fileOperation(path, ["/bin/mkdir", "-p", "--", path], undefined, true),
      access: async (path: string) => void await fileOperation(path, ["/bin/sh", "-c", '[ -r "$1" ] || { echo "Cannot read $1" >&2; exit 1; }', "sh", path]),
      // Pi's own detection would open the file outside the sandbox.
      detectImageMimeType: async (path: string) => {
        const head = (await fileOperation(path, ["/usr/bin/head", "-c", "12", "--", path])).toString("latin1");
        if (head.startsWith("\x89PNG")) return "image/png";
        if (head.startsWith("\xff\xd8\xff")) return "image/jpeg";
        if (head.startsWith("GIF8")) return "image/gif";
        return head.startsWith("RIFF") && head.slice(8) === "WEBP" ? "image/webp" : null;
      },
    };
    // `ls -p` marks folders, so listing a folder also answers the `stat` Pi asks for each entry.
    const folders = new Map<string, boolean>();
    const succeeds = (path: string, args: string[]) => fileOperation(path, args).then(() => true, () => false);
    const listing = {
      exists: (path: string) => succeeds(path, ["/bin/test", "-e", path]),
      stat: async (path: string) => {
        checkFilePath(path);
        const isFolder = folders.get(path) ?? await succeeds(path, ["/bin/test", "-d", path]);
        return { isDirectory: () => isFolder };
      },
      readdir: async (path: string) => {
        const entries = (await fileOperation(path, ["/bin/ls", "-1Ap", "--", path])).toString().split("\n").filter(Boolean);
        return entries.map((entry) => {
          const name = entry.replace(/\/$/, "");
          folders.set(join(path, name), entry.endsWith("/"));
          return name;
        });
      },
    };
    const quoted = (word: string) => `'${word.replaceAll("'", `'\\''`)}'`;
    if (sandbox.length > 0 || env.DAHLIA_PI_PROFILE === "bot") {
      pi.registerTool(createReadTool(process.cwd(), { operations: files }));
      pi.registerTool(createLsTool(process.cwd(), { operations: listing }));
      pi.registerTool(createWriteTool(process.cwd(), { operations: files }));
      pi.registerTool(createEditTool(process.cwd(), { operations: files }));
      pi.registerTool(createBashTool(process.cwd(), {
        spawnHook: ({ command, cwd, env }: any) => ({
          command: `exec ${inSandbox(["/bin/bash", "-c", command]).map(quoted).join(" ")}`,
          cwd,
          env: sandboxEnv(env),
        }),
      }));
    }

    pi.on("tool_call", async (event: any, ctx: any) => {
      const name = event.toolName;
      const profile = env.DAHLIA_PI_PROFILE ?? "interactive";
      if (profile === "review" && !["memory", "skills_list", "skill_view", "skill_manage"].includes(name)) {
        return block("This tool is unavailable during background review.");
      }
      if (profile === "scheduled" && !["read", "ls", "skills_list", "skill_view"].includes(name) && !name.startsWith("mcp__")) {
        return block("Scheduled tasks can only read approved sources.");
      }
      if (profile === "intake") {
        if (name === "event_record") return;
        if (!name.startsWith("mcp__")) return block("Intake can only read its source and record events.");
      }
      const fileTool = ["read", "ls", "write", "edit"].includes(name);
      // Dahlia Bot reads Dahlia's meetings and its home, and acts only through its own tools.
      if (profile === "bot") {
        if (botTools.bot.some((tool) => tool.name === name) || threadTools.some((tool) => tool.name === name)) return;
        if (!fileTool && !name.startsWith("mcp__dahlia__")) return block("Super Agent only reads Dahlia's meetings and its home, and works through its own tools.");
        // The files that steer the bot change only through Dahlia; Seatbelt refuses these writes too.
        const path = resolve(process.cwd(), String(event.input?.path ?? ""));
        if (["write", "edit"].includes(name) && dirname(path) === process.cwd() && ["AGENTS.md", "agent.json", "SOUL.md"].includes(basename(path))) {
          return block("AGENTS.md and agent.json belong to Dahlia, and SOUL.md changes only through soul_write.");
        }
      }
      if (name === "memory" && env.DAHLIA_PI_MEMORY_ENABLED !== "1") return block("Memory is disabled.");
      if (learningTools.includes(name)) return;
      const tool = pi.getAllTools().find((tool: any) => tool.name === name);
      // These run under Seatbelt through the tools registered above, never as Pi's own tool of the same name.
      if (["read", "ls", "write", "edit", "bash"].includes(name)) {
        const isSandboxed = sandbox.length > 0 && tool?.sourceInfo?.source !== "builtin";
        return isSandboxed ? undefined : block("This tool is not available in Dahlia's chat.");
      }

      if (name === "dah_create_backup" || threadTools.some((tool) => tool.name === name)) return;
      // Starting a session runs work outside this Mac, so it is approved like an MCP tool that writes.
      if (omnigentTools.some((tool) => tool.name === name)) {
        return name === "omni_create_session"
          ? approve(ctx, name, { kind: "mcpToolCall", server: "omnigent", tool: name,
            arguments: { ...event.input, workspace: env.DAHLIA_PI_OMNIGENT_WORKSPACE } })
          : undefined;
      }

      const server: string | undefined = tool?.sourceInfo?.path === mcpExtension ? tool.namespace?.aliases?.[0] : undefined;
      // This reserved server runs under its own filesystem/credential boundary, independently of URL validation.
      if (webEnabled && server === webServer) {
        const input = event.input ?? {};
        const urls = [input.url, ...(Array.isArray(input.urls) ? input.urls : [])].filter((url) => url !== undefined);
        if (input.auth !== undefined || urls.some((url) => !/^https?:\/\//i.test(String(url)))) {
          return block("Web access only fetches http and https URLs, without browser sign-ins.");
        }
        return;
      }

      // Pi lists an MCP tool under its server's namespace; the alias is the server name.
      if (server && chatMcpServers.has(server)) {
        const readOnly = server === "dahlia" ? readOnlyDahliaTool.test(name) : tool.annotations?.readOnlyHint === true;
        // Intake reads its one source and nothing of Dahlia's.
        if (profile === "intake") return readOnly && server !== "dahlia" ? undefined : block("Intake can only read its source.");
        if (profile === "bot") return readOnly && server === "dahlia" ? undefined : block("Super Agent only reads Dahlia's meetings.");
        if (profile === "scheduled") {
          const allowed = new Set<string>(JSON.parse(env.DAHLIA_PI_ALLOWED_TOOLS ?? "[]"));
          if (!readOnly || !allowed.has(name)) return block("This tool was not approved for this schedule.");
          // Native validation binds each call to the still-running immutable profile and approval revision.
          const permitted = await bridge(ctx, "scheduledTool", { name, readOnly });
          return permitted === true ? undefined : block("This scheduled tool is no longer available.");
        }
        if (readOnly) return;
        return approve(ctx, name, {
          kind: "mcpToolCall", server, tool: name.slice(`mcp__${server}__`.length), arguments: event.input,
        });
      }

      return block("This tool is not available in Dahlia's chat.");
    });
  }

  if (mode === "control") {
    registerDatabricksLoginCommand(pi);
    registerDatabricksMCPServicesCommand(pi);
    registerDatabricksModelServicesCommand(pi);
    registerDatabricksConnectionLoginCommand(pi);
    // ModelRegistry exposes no login API to extensions; Dahlia pins the Pi version this relies on.
    const runtime = (ctx: any) => ctx.modelRegistry.runtime;

    pi.registerCommand("dahlia-login", {
      description: "Sign in to a provider for Dahlia",
      handler: async (args: string, ctx: any) => {
        const provider = args.trim();
        try {
          await runtime(ctx).login(provider, "oauth", {
            signal: new AbortController().signal,
            // Choose the default (browser) method; manual-code prompts stay pending while the browser callback completes.
            prompt: async (request: any) =>
              request.type === "select" ? request.options[0].id : new Promise<string>(() => {}),
            notify: (event: any) => {
              if (event.type === "auth_url") ctx.ui.notify(`dahlia:auth_url ${event.url}`);
            },
          }, { agentName: "Dahlia", getDeviceId: () => env.DAHLIA_PI_DEVICE_ID });
          ctx.ui.notify("dahlia:login_succeeded");
        } catch (error: any) {
          ctx.ui.notify(`dahlia:login_failed ${error?.message ?? String(error)}`, "error");
        }
      },
    });

    pi.registerCommand("dahlia-logout", {
      description: "Sign out of a provider for Dahlia",
      handler: async (args: string, ctx: any) => {
        await runtime(ctx).logout(args.trim());
        ctx.ui.notify("dahlia:logout_succeeded");
      },
    });
  }
}
