// The Databricks provider: Unity AI Gateway sign-ins, for MCP servers today. As its own extension, it registers the
// sign-ins that mcp.json names; Dahlia's extension imports the sign-in command for its control process.
// Each sign-in is a Pi provider without models whose OAuth credential Pi stores in auth.json and refreshes; an mcp.json
// entry takes it through `auth.provider`. The provider ID is the workspace host, and the credential also carries the
// workspace origin and OAuth client, so any process can refresh it by ID alone. Pi never starts a sign-in by itself:
// a server whose credential cannot be refreshed needs `/databricks-login` again.
import { createProvider, openAIResponsesApi } from "@earendil-works/pi-ai";
import { createHash, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { homedir } from "node:os";
import { join } from "node:path";

// The Databricks CLI's public client, until Pi publishes a Client ID Metadata Document of its own. Without a
// registered redirect URL, it accepts http://localhost on these ports. MCP servers take the gateway's scope; listing
// them is a Unity Catalog API.
const defaultClientId = "databricks-cli";
const defaultScopes = "ai-gateway unity-catalog offline_access";
const callbackPorts = { first: 8020, last: 8040 };
const loopbackHosts = new Set(["localhost", "127.0.0.1"]);

export type Client = { clientId: string; redirectUrl?: string; scopes: string };
export type Credential = { type: "oauth"; access: string; refresh: string; expires: number; origin: string } & Client;

const base64url = (bytes: Buffer) => bytes.toString("base64url");

// Registers the sign-ins that mcp.json names. Pi's own provider IDs have no dot; a workspace host does.
export default function registerDatabricksMCPProviders(pi: any) {
  const directory = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");
  let servers: any[];
  try {
    servers = Object.values(JSON.parse(readFileSync(join(directory, "mcp.json"), "utf8")).mcpServers ?? {});
  } catch {
    return;
  }
  const ids = new Set(servers.map((server) => server?.auth?.provider).filter((id) => typeof id === "string" && id.includes(".")));
  for (const id of ids) pi.registerProvider(provider(id));
}

// `/databricks-login <workspace URL> [--client-id <id>] [--redirect-url <url>] [--scopes <a,b>]` registers the
// workspace's provider, then signs in. The client options are for a client the organization registered; without them
// it signs in as the Databricks CLI. Progress goes out as notifications: `databricks:auth_url <url>`, then
// `databricks:login_succeeded` or `databricks:login_failed <message>`.
export function registerDatabricksLoginCommand(pi: any) {
  pi.registerCommand("databricks-login", {
    description: "Sign in to a Databricks workspace for its Unity AI Gateway MCP servers",
    handler: async (args: string, ctx: any) => {
      try {
        const { origin, client } = loginArguments(args);
        const id = new URL(origin).host;
        ctx.modelRegistry.registerProvider(provider(id, { origin, client }));
        // ModelRegistry exposes no login API to extensions; Dahlia checks this when Pi updates.
        await ctx.modelRegistry.runtime.login(id, "oauth", {
          signal: new AbortController().signal,
          prompt: () => new Promise<string>(() => {}),
          notify: (event: any) => {
            if (event.type === "auth_url") ctx.ui.notify(`databricks:auth_url ${event.url}`);
          },
        });
        ctx.ui.notify("databricks:login_succeeded");
      } catch (error: any) {
        ctx.ui.notify(`databricks:login_failed ${error?.message ?? String(error)}`, "error");
      }
    },
  });
}

// `/databricks-mcp-services <workspace URL> [--provider <id>]` lists the Unity AI Gateway MCP services in `system.ai`
// that a sign-in can see: `databricks:mcp_services <JSON array of full names>`, `databricks:mcp_services_sign_in_required`,
// or `databricks:mcp_services_failed <message>`. The sign-in is the workspace's own, or `--provider`'s, such as the
// account's bridged provider. The token stays in this process.
export function registerDatabricksMCPServicesCommand(pi: any) {
  pi.registerCommand("databricks-mcp-services", {
    description: "List a Databricks workspace's Unity AI Gateway MCP services",
    handler: async (args: string, ctx: any) => {
      try {
        const [workspace = "", option, providerId] = args.trim().split(/\s+/);
        if (option !== undefined && (option !== "--provider" || !providerId)) throw new Error(`Unknown or incomplete option: ${option}`);
        const origin = new URL(workspace).origin;
        const id = providerId ?? new URL(origin).host;
        // Refreshing reads the workspace and client from the stored credential, so the provider needs only its ID.
        if (!ctx.modelRegistry.getRegisteredProviderIds().includes(id)) ctx.modelRegistry.registerProvider(provider(id));
        const token = await ctx.modelRegistry.getApiKeyForProvider(id);
        if (!token) return void ctx.ui.notify("databricks:mcp_services_sign_in_required");
        ctx.ui.notify(`databricks:mcp_services ${JSON.stringify(await listMCPServices(origin, token, AbortSignal.timeout(60_000)))}`);
      } catch (error: any) {
        ctx.ui.notify(`databricks:mcp_services_failed ${error?.message ?? String(error)}`, "error");
      }
    },
  });
}

// The active MCP services under `system.ai`, by full name such as `system.ai.github`. Services in other schemas are not
// listed: finding them walks every catalog and schema.
export async function listMCPServices(origin: string, token: string, signal: AbortSignal): Promise<string[]> {
  const names = new Set<string>();
  let pageToken: string | undefined;
  for (let page = 0; page < 100; page++) {
    const url = new URL(`${origin}/api/2.1/unity-catalog/mcp-services`);
    url.search = new URLSearchParams({ parent: "schemas/system.ai", view: "BASIC", ...(pageToken ? { page_token: pageToken } : {}) }).toString();
    const response = await fetch(url, { headers: { authorization: `Bearer ${token}` }, redirect: "error", signal });
    if (!response.ok) {
      // Databricks explains a refusal, such as a missing scope, in the body.
      const detail: any = await response.json().catch(() => undefined);
      const reason = [detail?.error_code, detail?.message].filter((part) => typeof part === "string").join(": ");
      throw new Error(`Listing MCP services failed (HTTP ${response.status}${reason ? `, ${reason}` : ""})`);
    }
    const body: any = await response.json();
    for (const service of body.mcp_services ?? []) {
      const name = typeof service?.name === "string" ? service.name.replace(/^mcp-services\//, "") : "";
      const status = service?.config?.connection?.status;
      if (name.startsWith("system.ai.") && (status === undefined || status === "ACTIVE")) names.add(name);
    }
    pageToken = body.next_page_token || undefined;
    if (!pageToken) break;
  }
  return [...names].sort();
}

// `/databricks-connection-login <workspace URL> <MCP service> [--client-id <id>]` signs the user in to the service's
// own connection (GitHub behind `system.ai.github`, for example), which the gateway needs before it serves the
// service's tools. The code that comes back is not exchanged, so the workspace's sign-in stays as it is. Progress goes
// out as `databricks:connection_auth_url <url>`, then `databricks:connection_login_succeeded` or
// `databricks:connection_login_failed <message>`.
export function registerDatabricksConnectionLoginCommand(pi: any) {
  pi.registerCommand("databricks-connection-login", {
    description: "Sign in to the connection behind a Unity AI Gateway MCP service",
    handler: async (args: string, ctx: any) => {
      try {
        const [workspace = "", service = "", ...rest] = args.trim().split(/\s+/);
        if (!/^[\w.-]+$/.test(service)) throw new Error("Name the MCP service, such as system.ai.github");
        const { origin, client } = loginArguments([workspace, ...rest].join(" "));
        await authorize(origin, client, {
          signal: new AbortController().signal,
          notify: (event: any) => ctx.ui.notify(`databricks:connection_auth_url ${event.url}`),
        }, `${origin}/ai-gateway/mcp-services/${service}`);
        ctx.ui.notify("databricks:connection_login_succeeded");
      } catch (error: any) {
        ctx.ui.notify(`databricks:connection_login_failed ${error?.message ?? String(error)}`, "error");
      }
    },
  });
}

function loginArguments(args: string) {
  const [workspace = "", ...rest] = args.trim().split(/\s+/);
  const options = new Map<string, string>();
  for (let index = 0; index < rest.length; index += 2) {
    const [name, value] = [rest[index], rest[index + 1]];
    if (!["--client-id", "--redirect-url", "--scopes"].includes(name) || value === undefined) {
      throw new Error(`Unknown or incomplete option: ${name}`);
    }
    options.set(name, value);
  }
  const url = new URL(workspace);
  // Plain HTTP only reaches a server on this Mac, as Pi allows for `auth.provider`.
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopbackHosts.has(url.hostname))) {
    throw new Error("The workspace URL must use HTTPS");
  }
  const redirectUrl = options.get("--redirect-url");
  if (redirectUrl) {
    const redirect = new URL(redirectUrl);
    if (redirect.protocol !== "http:" || !loopbackHosts.has(redirect.hostname) || !redirect.port || redirect.search || redirect.hash) {
      throw new Error("--redirect-url must be http://localhost or http://127.0.0.1 with a port");
    }
  }
  const scopes = (options.get("--scopes") ?? defaultScopes).split(/[\s,]+/).filter(Boolean);
  // Without offline_access there is no refresh token, and the sign-in would end within the hour.
  if (!scopes.includes("offline_access") || scopes.length < 2) {
    throw new Error("--scopes must include offline_access and an API scope such as ai-gateway");
  }
  return { origin: url.origin, client: { clientId: options.get("--client-id") ?? defaultClientId, redirectUrl, scopes: scopes.join(" ") } };
}

// A sign-in's provider. Only `/databricks-login` knows the workspace and client to sign in with; refreshing reads them
// from the stored credential.
export function provider(id: string, signIn?: { origin: string; client: Client }) {
  return createProvider({
    id,
    name: id,
    models: [],
    // Pi requires an implementation; no model of this provider ever streams.
    api: { "openai-responses": openAIResponsesApi },
    auth: {
      oauth: {
        name: `Unity AI Gateway (${id})`,
        login: async (interaction: any) => {
          if (!signIn) throw new Error(`Sign in with /databricks-login https://${id}`);
          return login(signIn.origin, signIn.client, interaction);
        },
        refresh: async (credential: Credential, signal: AbortSignal) => ({
          ...credential,
          ...(await requestToken(credential, { grant_type: "refresh_token", refresh_token: credential.refresh }, signal)),
        }),
        toAuth: async (credential: Credential) => ({ apiKey: credential.access }),
      },
    },
  });
}

// The authorization code flow with PKCE against the workspace's OIDC endpoints and a loopback callback.
export async function login(origin: string, client: Client, interaction: any): Promise<Credential> {
  const { code, redirectUri, verifier } = await authorize(origin, client, interaction);
  const tokens = await requestToken(
    { origin, clientId: client.clientId },
    { grant_type: "authorization_code", code, redirect_uri: redirectUri, code_verifier: verifier },
    interaction.signal,
  );
  return { ...tokens, origin, ...client };
}

// Opens the authorization page and waits for its code. Naming an MCP service as the `resource` (RFC 8707) makes the
// workspace sign the user in to the service's own connection, such as GitHub, before it answers.
async function authorize(origin: string, client: Client, interaction: any, resource?: string) {
  const verifier = base64url(randomBytes(64));
  const state = base64url(randomBytes(32));
  const redirect = client.redirectUrl ? new URL(client.redirectUrl) : undefined;
  const callbackPath = redirect?.pathname ?? "/";
  const callback = Promise.withResolvers<string>();
  interaction.signal.addEventListener("abort", () => callback.reject(interaction.signal.reason), { once: true });
  const server = createServer((request, response) => {
    const url = new URL(request.url ?? "/", "http://localhost");
    if (url.pathname !== callbackPath) return void response.writeHead(404).end();
    const code = url.searchParams.get("state") === state ? url.searchParams.get("code") : null;
    response.writeHead(code ? 200 : 400, { "content-type": "text/plain; charset=utf-8" })
      .end(code ? "Signed in. You can close this page." : "Sign-in failed.");
    if (code) callback.resolve(code);
    else callback.reject(new Error(url.searchParams.get("error_description") ?? url.searchParams.get("error") ?? "Invalid authorization response"));
  });
  try {
    // A registered redirect URL is sent exactly as registered; the Databricks CLI's takes the first free port.
    let redirectUri = client.redirectUrl ?? "";
    if (redirect) await listen(server, [Number(redirect.port)]);
    else redirectUri = `http://localhost:${await listen(server, range(callbackPorts.first, callbackPorts.last))}`;
    const url = new URL(`${origin}/oidc/v1/authorize`);
    url.search = new URLSearchParams({
      response_type: "code",
      client_id: client.clientId,
      redirect_uri: redirectUri,
      scope: client.scopes,
      state,
      code_challenge: base64url(createHash("sha256").update(verifier).digest()),
      code_challenge_method: "S256",
      ...(resource ? { resource } : {}),
    }).toString();
    interaction.notify({ type: "auth_url", url: url.href });
    return { code: await callback.promise, redirectUri, verifier };
  } finally {
    server.close();
  }
}

const range = (first: number, last: number) => Array.from({ length: last - first + 1 }, (_, index) => first + index);

// Listens on the first free port. `localhost` is served on 127.0.0.1; browsers fall back to it when ::1 refuses.
async function listen(server: Server, ports: number[]): Promise<number> {
  for (const port of ports) {
    const listening = await new Promise<boolean>((resolve) => {
      server.once("error", () => resolve(false));
      server.listen(port, "127.0.0.1", () => resolve(true));
    });
    server.removeAllListeners("error");
    if (listening) return port;
  }
  throw new Error(`No free port for the Databricks sign-in callback (${ports.join(", ")})`);
}

async function requestToken(
  { origin, clientId, refresh: previousRefresh }: { origin: string; clientId: string; refresh?: string },
  parameters: Record<string, string>,
  signal: AbortSignal,
) {
  const response = await fetch(`${origin}/oidc/v1/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: clientId, ...parameters }),
    redirect: "error",
    signal,
  });
  if (!response.ok) throw new Error(`Databricks token request failed (HTTP ${response.status})`);
  const body: any = await response.json();
  // Databricks may keep the refresh token instead of rotating it.
  const refresh = body.refresh_token ?? previousRefresh;
  if (typeof body.access_token !== "string" || !(body.expires_in > 0) || typeof refresh !== "string") {
    throw new Error("Databricks returned an invalid token response");
  }
  return { type: "oauth" as const, access: body.access_token, refresh, expires: Date.now() + body.expires_in * 1000 };
}
