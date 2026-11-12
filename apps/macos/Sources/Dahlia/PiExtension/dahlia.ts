// Dahlia's Pi extension. Dahlia owns every policy decision; this file only forwards them to Pi.
// Requests to Dahlia travel over the RPC extension-UI channel: `ctx.ui.input("dahlia:<method>", <JSON>)`.
import { createBashTool, createEditTool, createLsTool, createReadTool, createWriteTool, DefaultPackageManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { anthropicMessagesApi, createProvider, googleGenerativeAIApi, openAIResponsesApi } from "@earendil-works/pi-ai";
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  registerDatabricksConnectionLoginCommand,
  registerDatabricksLoginCommand,
  registerDatabricksMCPServicesCommand,
  registerDatabricksModelServicesCommand,
  registerDatabricksProviders,
} from "./databricks-provider.ts";

import { reviewMCP } from "./mcp-review.ts";

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

async function bridge(ctx: any, method: string, payload: unknown): Promise<any> {
  const value = await ctx.ui.input(`dahlia:${method}`, JSON.stringify(payload));
  if (value === undefined) throw new Error(`Dahlia did not answer ${method}`);
  return JSON.parse(value);
}

export default function (pi: any) {
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
  registerDatabricksProviders(pi);

  pi.on("before_provider_request", (event: any, ctx: any) => {
    const enforce = strictSchemaPayload[ctx.model?.api];
    if (!outputSchema || env.PI_OUTPUT_STRICT_SCHEMA !== "1" || !enforce) return;
    return enforce(event.payload);
  });

  if (mode === "chat") {
    // Keep automatic discovery disabled (it includes ~/.agents/skills); contribute only this account's packages.
    pi.on("resources_discover", async (event: any) => {
      const agentDir = env.PI_CODING_AGENT_DIR!;
      const settingsManager = SettingsManager.create(event.cwd, agentDir, { projectTrusted: false });
      const resources = await new DefaultPackageManager({ cwd: event.cwd, agentDir, settingsManager }).resolve(async () => "skip");
      const paths = (entries: typeof resources.skills) => entries
        .filter((entry) => entry.enabled && entry.metadata.origin === "package" && entry.metadata.scope === "user")
        .map((entry) => entry.path);
      return { skillPaths: paths(resources.skills), promptPaths: paths(resources.prompts) };
    });

    if (env.DAHLIA_PI_MCP_COMMAND) {
      const [command, ...args] = JSON.parse(env.DAHLIA_PI_MCP_COMMAND);
      pi.registerMcpServer("dahlia", { command, args, exposure: "direct", description: "Dahlia meetings, projects, and workspaces" });
    }

    // Everything chat does on this Mac's disk runs under Seatbelt (pi.sb): bash commands, and the file operations of
    // `read`, `ls`, `write`, and `edit`, so the kernel decides each path as it is opened and a symlink cannot lead outside.
    // Pi itself stays outside the sandbox, so nothing chat runs can read Pi's sign-ins or talk to its MCP servers.
    const sandbox: string[] = JSON.parse(env.DAHLIA_PI_SANDBOX ?? "[]");
    const hidden: string[] = JSON.parse(env.DAHLIA_PI_SANDBOX_HIDDEN_ENV ?? "[]");
    const sandboxEnv = (env: NodeJS.ProcessEnv) => Object.fromEntries(Object.entries(env).filter(([key]) => !hidden.includes(key)));
    // The real home and temporary folders are out of reach in the sandbox, which gets one folder of its own for both
    // (tools such as git keep their settings there). They are set inside the sandbox only: the shell Pi starts a
    // command with runs outside it, and Pi loads code from its own TMPDIR.
    const home = env.DAHLIA_PI_SANDBOX_TMPDIR;
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
    const files = {
      readFile: (path: string) => sandboxed(["/bin/cat", "--", path]),
      writeFile: async (path: string, content: string) => void await sandboxed(["/bin/sh", "-c", 'cat > "$1"', "sh", path], content),
      mkdir: async (path: string) => void await sandboxed(["/bin/mkdir", "-p", "--", path]),
      access: async (path: string) => void await sandboxed(["/bin/sh", "-c", '[ -r "$1" ] || { echo "Cannot read $1" >&2; exit 1; }', "sh", path]),
      // Pi's own detection would open the file outside the sandbox.
      detectImageMimeType: async (path: string) => {
        const head = (await sandboxed(["/usr/bin/head", "-c", "12", "--", path])).toString("latin1");
        if (head.startsWith("\x89PNG")) return "image/png";
        if (head.startsWith("\xff\xd8\xff")) return "image/jpeg";
        if (head.startsWith("GIF8")) return "image/gif";
        return head.startsWith("RIFF") && head.slice(8) === "WEBP" ? "image/webp" : null;
      },
    };
    // `ls -p` marks folders, so listing a folder also answers the `stat` Pi asks for each entry.
    const folders = new Map<string, boolean>();
    const succeeds = (args: string[]) => sandboxed(args).then(() => true, () => false);
    const listing = {
      exists: (path: string) => succeeds(["/bin/test", "-e", path]),
      stat: async (path: string) => {
        const isFolder = folders.get(path) ?? await succeeds(["/bin/test", "-d", path]);
        return { isDirectory: () => isFolder };
      },
      readdir: async (path: string) => {
        const entries = (await sandboxed(["/bin/ls", "-1Ap", "--", path])).toString().split("\n").filter(Boolean);
        return entries.map((entry) => {
          const name = entry.replace(/\/$/, "");
          folders.set(join(path, name), entry.endsWith("/"));
          return name;
        });
      },
    };
    const quoted = (word: string) => `'${word.replaceAll("'", `'\\''`)}'`;
    if (sandbox.length > 0) {
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
      const tool = pi.getAllTools().find((tool: any) => tool.name === name);
      // These run under Seatbelt through the tools registered above, never as Pi's own tool of the same name.
      if (["read", "ls", "write", "edit", "bash"].includes(name)) {
        const isSandboxed = sandbox.length > 0 && tool?.sourceInfo?.source !== "builtin";
        return isSandboxed ? undefined : { block: true, reason: "This tool is not available in Dahlia's chat." };
      }

      // Pi lists an MCP tool under its server's namespace; the alias is the server name.
      const server: string | undefined = tool?.sourceInfo?.path === "builtin:mcp" ? tool.namespace?.aliases?.[0] : undefined;
      if (server && chatMcpServers.has(server)) {
        const readOnly = server === "dahlia" ? readOnlyDahliaTool.test(name) : tool.annotations?.readOnlyHint === true;
        if (readOnly) return;
        // Dahlia owns the approval mode; asking per call applies a change made during the turn to the next tool.
        const approvalMode = await bridge(ctx, "approvalMode", {});
        if (approvalMode === "fullAccess") return;
        let reason: string | undefined;
        if (approvalMode === "autoReview") {
          const model = await bridge(ctx, "reviewModel", {});
          const verdict = await reviewMCP(ctx, name, event.input, model);
          if (ctx.signal?.aborted) return { block: true, reason: "MCP AI review was cancelled." };
          if (verdict.outcome === "allow" && verdict.risk !== "unknown") return;
          if (verdict.risk === "critical") {
            return { block: true, reason: `MCP AI review blocked a critical action: ${verdict.reason}` };
          }
          reason = `MCP AI review ${verdict.risk === "unknown" ? "failed" : "requires your approval"}: ${verdict.reason}`;
        }
        const decision = await bridge(ctx, "approval", {
          kind: "mcpToolCall",
          server,
          tool: name.slice(`mcp__${server}__`.length),
          arguments: event.input,
          reason,
        });
        if (decision !== "accept") return { block: true, reason: "The user declined this tool call." };
        return;
      }

      return { block: true, reason: "This tool is not available in Dahlia's chat." };
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
