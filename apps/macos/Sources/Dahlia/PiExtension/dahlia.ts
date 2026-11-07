// Dahlia's Pi extension. Dahlia owns every policy decision; this file only forwards them to Pi.
// Requests to Dahlia travel over the RPC extension-UI channel: `ctx.ui.input("dahlia:<method>", <JSON>)`.
import { anthropicMessagesApi, createProvider, googleGenerativeAIApi, openAIResponsesApi } from "@earendil-works/pi-ai";
import { readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const env = process.env;
const mode = env.DAHLIA_PI_MODE ?? "control";
const bridgedProviders = (env.DAHLIA_PI_BRIDGED_PROVIDERS ?? "").split(",").filter(Boolean);
// The APIs of the models Dahlia writes to models.json for bridged providers (Databricks routes and the Dahlia Server).
const bridgedAPIs = {
  "anthropic-messages": anthropicMessagesApi,
  "google-generative-ai": googleGenerativeAIApi,
  "openai-responses": openAIResponsesApi,
};
const outputSchema = env.DAHLIA_PI_OUTPUT_SCHEMA ? JSON.parse(readFileSync(env.DAHLIA_PI_OUTPUT_SCHEMA, "utf8")) : undefined;
const strictSchemaAPIs = new Set(["openai-responses", "openai-codex-responses"]);
const readOnlyDahliaTool = /^mcp__dahlia__(get|query|list|search)_/;
// The MCP servers Dahlia registered for this chat (its own and the account's gateway MCPs); any other server is blocked.
const chatMcpServers = new Set<string>(JSON.parse(env.DAHLIA_PI_MCP_SERVERS ?? "[]"));

// The on-disk path (case, symlinks) of an existing file, or undefined.
function canonical(path: string): string | undefined {
  try {
    return realpathSync.native(path);
  } catch {
    return undefined;
  }
}

// Chat may read only these folders (its workspace and Dahlia's preset skills).
const readableRoots = (JSON.parse(env.DAHLIA_PI_READABLE_ROOTS ?? "[]") as string[]).flatMap((root) => canonical(root) ?? []);

// Resolves a tool path the way a user means it (`@`, `~`, `file://`), then to its canonical form inside a readable root.
function readablePath(raw: string, cwd: string): string | undefined {
  let path = raw.trim().replace(/^@/, "");
  if (path.startsWith("file://")) path = fileURLToPath(path);
  if (path === "~" || path.startsWith("~/")) path = homedir() + path.slice(1);
  const resolved = canonical(isAbsolute(path) ? path : resolve(cwd, path));
  return resolved && readableRoots.some((root) => resolved === root || resolved.startsWith(root + sep)) ? resolved : undefined;
}

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

  pi.on("before_provider_request", (event: any, ctx: any) => {
    if (!outputSchema || env.DAHLIA_PI_STRICT_SCHEMA !== "1" || !strictSchemaAPIs.has(ctx.model?.api)) return;
    const payload = event.payload as any;
    const format = { type: "json_schema", name: "dahlia_output", strict: true, schema: outputSchema };
    return { ...payload, text: { ...(payload.text ?? {}), format } };
  });

  if (mode === "chat") {
    if (env.DAHLIA_PI_MCP_COMMAND) {
      const [command, ...args] = JSON.parse(env.DAHLIA_PI_MCP_COMMAND);
      pi.registerMcpServer("dahlia", { command, args, exposure: "direct", description: "Dahlia meetings, projects, and workspaces" });
    }

    // Chat is read-only on this Mac: `read` and `ls` within the readable roots, and MCP tools (Dahlia's and the gateway's).
    pi.on("tool_call", async (event: any, ctx: any) => {
      const name = event.toolName;
      if (name === "read" || name === "ls") {
        const path = readablePath(String(event.input.path ?? "."), ctx.cwd);
        if (!path) return { block: true, reason: "Chat can read only its workspace and Dahlia's skills." };
        // Pi then opens exactly the path that was checked.
        event.input.path = path;
        return;
      }

      const tool = pi.getAllTools().find((tool: any) => tool.name === name);
      // Pi lists an MCP tool under its server's namespace; the alias is the server name.
      const server: string | undefined = tool?.sourceInfo?.path === "builtin:mcp" ? tool.namespace?.aliases?.[0] : undefined;
      if (server && chatMcpServers.has(server)) {
        const readOnly = server === "dahlia" ? readOnlyDahliaTool.test(name) : tool.annotations?.readOnlyHint === true;
        if (readOnly) return;
        // Dahlia owns the approval mode; asking per call applies a change made during the turn to the next tool.
        if ((await bridge(ctx, "approvalMode", {})) === "autoReview") return;
        const decision = await bridge(ctx, "approval", {
          kind: "mcpToolCall",
          server,
          tool: name.slice(`mcp__${server}__`.length),
          arguments: event.input,
        });
        if (decision !== "accept") return { block: true, reason: "The user declined this tool call." };
        return;
      }

      return { block: true, reason: "This tool is not available in Dahlia's chat." };
    });
  }

  if (mode === "control") {
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
