import { personalWorkspaceId } from "./auth/workspace";
import { installPublicIDs } from "./public-http";
import { wireValue } from "./public-wire";
import { meetingMetadata } from "./sync/text-content";
import { summaryJobResponse, type SummaryService } from "./summary/service";
import { OpenAPIHono } from "@hono/zod-openapi";
import { HTTPException } from "hono/http-exception";
import { textSearchRequest } from "./api/schemas";
import { registerApi, openapiDocument } from "./api/contracts";
import { problemResponse, problemMiddleware } from "./api/problem";
import { TrieRouter } from "hono/router/trie-router";
import { bodyLimit } from "hono/body-limit";
import { secureHeaders } from "hono/secure-headers";
import { streamSSE } from "hono/streaming";
import {
  bearerAuthChallengeResponse,
  OAuthError,
  OAuthErrorCode,
  type AuthInfo,
} from "@modelcontextprotocol/server";
import { z } from "zod";
import { accountSettingsPatchSchema } from "./account-settings";

import {
  AuthenticationError,
  IdentityProjectionError,
  IdentityService,
  type Identity,
} from "./auth/identity";
import { createProtectedResourceMetadata, type DahliaAuth } from "./auth/better-auth";
import {
  ALL_APIS_SCOPE,
  GATEWAY_SCOPES,
  MCP_CAPABILITY_SCOPES,
  MCP_READ_SCOPE,
  MCP_SCOPE,
} from "./auth/scopes";
import type { AuthStore } from "./auth/store";
import { EXTERNAL_ORGANIZATION_ID } from "./auth/ids";
import { mcpResource, type AppConfig } from "./config";
import { RequestError } from "./storage/upload";
import type { ObjectStorage } from "./storage/storage";
import { createServerMcpHandler, MCP_MAX_REQUEST_BYTES } from "./mcp";
import { MeetingSyncService } from "./sync/service";
import { SCREENSHOT_VARIANTS, type ScreenshotVariant, type ScreenshotTransformer } from "./sync/screenshot-variants";
import { decodeSyncCursor, SyncStoreUnavailableError, SyncTransactionError } from "./sync/store";
import type { SearchTokenizer } from "./search/tokenizer";
import type { SearchEmbedder } from "./search/embedding";

import { gatewayError, GatewayRequestError, GatewayService } from "./ai-gateway/service";

export const AUTH_MAX_REQUEST_BYTES = 64 * 1024;
const SYNC_JSON_MAX_REQUEST_BYTES = 8 * 1024 * 1024;
const teamInputSchema = z.object({ name: z.string().trim().min(1).max(100) }).strict();

export const authBodyLimit = bodyLimit({
  maxSize: AUTH_MAX_REQUEST_BYTES,
  onError: (context) => context.json({ error: "request_too_large" }, 413),
});
const mcpBodyLimit = bodyLimit({
  maxSize: MCP_MAX_REQUEST_BYTES,
  onError: (context) => context.json({ error: "request_too_large" }, 413),
});
const syncBodyLimit = bodyLimit({
  maxSize: SYNC_JSON_MAX_REQUEST_BYTES,
  onError: (context) => context.json({ error: "request_too_large" }, 413),
});
const accountSettingsBodyLimit = bodyLimit({
  maxSize: 8 * 1024,
  onError: (context) => context.json({ error: "request_too_large" }, 413),
});

export interface AppVariables {
  identity: Identity;
}

export type DahliaServerApp = OpenAPIHono<{ Variables: AppVariables }>;

export interface ServerExtensionServices {
  auth?: DahliaAuth;
  browserIdentity(request: Request, context: unknown): Promise<Identity>;
}

export interface GatewayExtensionContext {
  identity: Identity;
  method: string;
  path: string;
}

export interface DahliaServerExtension {
  beforeGateway?(context: GatewayExtensionContext): Promise<Response | undefined>;
  registerAuthRoutes?(app: DahliaServerApp, services: ServerExtensionServices): void;
  registerRoutes?(app: DahliaServerApp, services: ServerExtensionServices): void;
  sessionCapabilities?(identity: Identity): Promise<Record<string, boolean>> | Record<string, boolean>;
}

export interface AppDependencies {
  config: AppConfig;
  fetch?: typeof fetch;
  auth?: DahliaAuth;
  authStore?: AuthStore;
  syncService?: MeetingSyncService;
  extensions?: readonly DahliaServerExtension[];
  objectStorage?: ObjectStorage;
  searchTokenizer?: SearchTokenizer;
  searchEmbedder?: SearchEmbedder;
  screenshotTransformer?: ScreenshotTransformer;
  imageAnalysisEnabled?: boolean;
  summaryService?: SummaryService;
  onSyncMutation?(ownerUserId: string, context: { waitUntil(task: Promise<unknown>): void }): void;
}

export async function authenticateMcpRequest(
  request: Request,
  verifyAccessToken: (request: Request) => Promise<AuthInfo>,
  resourceMetadataUrl: string,
): Promise<AuthInfo | Response> {
  const options = { resourceMetadataUrl };
  let authInfo: AuthInfo;
  try {
    authInfo = await verifyAccessToken(request);
  } catch {
    return bearerAuthChallengeResponse(
      new OAuthError(OAuthErrorCode.InvalidToken, "Invalid or expired Dahlia access token"),
      options,
    );
  }
  if (!MCP_CAPABILITY_SCOPES.some((scope) => authInfo.scopes.includes(scope))) {
    return bearerAuthChallengeResponse(
      new OAuthError(OAuthErrorCode.InsufficientScope, "Insufficient scope"),
      options,
    );
  }
  return authInfo;
}

const memberSchema = z.object({ email: z.string().trim().email().transform((value) => value.toLowerCase()) });

export function mutationOriginAllowed(request: Request, baseUrl: string): boolean {
  if (["GET", "HEAD", "OPTIONS"].includes(request.method)) return true;
  return request.headers.get("origin") === new URL(baseUrl).origin;
}

export function createApp(dependencies: AppDependencies): DahliaServerApp & { runStorageMaintenance(): Promise<void> } {
  const { config } = dependencies;
  const app = new OpenAPIHono<{ Variables: AppVariables }>({ defaultHook: async (result, context) => {
    if (!result.success) {
      if (result.target === "header" && result.error.issues.some((issue) => issue.path[0] === "content-length") && !context.req.header("content-length")) return problemResponse(411, "content_length_required");
      if (result.target === "json" && ["/api/v1/transactions", "/api/v1/transactions/resolve"].includes(context.req.path)) {
        const index = result.error.issues.find((issue) => issue.path[0] === "operations" && typeof issue.path[1] === "number")?.path[1];
        const input = z.object({ operations: z.array(z.object({ id: z.unknown().optional() }).loose()) }).safeParse(await context.req.json());
        const operationId = typeof index === "number" && input.success ? input.data.operations[index]?.id : undefined;
        if (typeof operationId === "string" && z.uuid().safeParse(operationId).success) return problemResponse(400, "invalid_sync_operation", { operationId });
      }
      return problemResponse(400, "invalid_request");
    }
  } });
  const store = dependencies.authStore;
  if (!store) throw new Error("The Dahlia application store must be initialized before creating the application");
  const authStore = config.authProvider === "accounts" ? store : undefined;
  const auth: DahliaAuth | undefined = config.authProvider === "accounts" ? dependencies.auth : undefined;
  if (config.authProvider === "accounts" && (!auth || !authStore)) {
    throw new Error("Better Auth must be initialized before creating the application");
  }
  const extensions = dependencies.extensions ?? [];
  const identities = new IdentityService(config, auth, async (identity) => {
    const userId = identity.source === "header" ? await store.resolveHeaderUser(identity) : identity.userId;
    if (!userId) return null;
    const resolved = { ...identity, userId, workspaceId: personalWorkspaceId(userId) };
    return await store.ensureIdentityUser(resolved) ? resolved : null;
  });
  const gateway = new GatewayService(config, dependencies.fetch);
  const sync = dependencies.syncService ?? new MeetingSyncService(
    store.sync,
    dependencies.objectStorage,
    dependencies.searchTokenizer,
    dependencies.searchEmbedder,
    dependencies.screenshotTransformer,
    config.storageBackend === "databricks" ? config.storageDatabricksVolumePath : undefined,
  );
  const mcp = createServerMcpHandler(config, sync);
  const jobOwners = new WeakMap<Request, string>();
  const mcpMetadataUrl = `${config.baseUrl}/.well-known/oauth-protected-resource/mcp`;
  const mcpRequestAuth = auth
    ? (request: Request) => authenticateMcpRequest(
        request,
        (candidate) => identities.verifyMcpAccessToken(candidate),
        mcpMetadataUrl,
      )
    : undefined;
  const services: ServerExtensionServices = {
    auth,
    browserIdentity: (request) => identities.fromBrowser(request),
  };

  app.use("*", secureHeaders());
  app.use("/api/v1/*", problemMiddleware);
  app.use("/api/v1/*", async (context, next) => {
    if (!["GET", "HEAD", "OPTIONS"].includes(context.req.method)
      && !["/api/v1/models", "/api/v1/responses"].includes(context.req.path)) {
      const requiresBrowserOrigin = config.authProvider === "accounts" && !context.req.header("authorization");
      if ((requiresBrowserOrigin || context.req.header("origin")) && !mutationOriginAllowed(context.req.raw, config.baseUrl)) return problemResponse(403, "invalid_origin");
    }
    await next();
  });
  registerApi(app, "getOpenAPI", (context) => context.json(openapiDocument()));
  app.use("/api/*", async (context, next) => {
    await next();
    const owner = jobOwners.get(context.req.raw);
    if (owner && dependencies.onSyncMutation && context.res.ok && !["GET", "HEAD", "OPTIONS"].includes(context.req.method)
      && !["/api/v1/search", "/api/v1/transactions/resolve"].includes(context.req.path)) {
      try {
        dependencies.onSyncMutation(owner, context.executionCtx);
      } catch {
        console.warn(JSON.stringify({ level: "warn", event: "job_notification_failed" }));
      }
    }
    const fileRead = ["GET", "HEAD"].includes(context.req.method)
      && /^\/api\/v1\/files\/[^/]+(?:\/content|\/variants\/[^/]+)$/.test(context.req.path)
      && (context.res.ok || context.res.status === 304);
    if (!fileRead) context.header("Cache-Control", "no-store");
  });
  app.use("/mcp", async (context, next) => {
    await next();
    context.header("Cache-Control", "no-store");
  });

  registerApi(app, "getHealth", (context) => context.json({ status: "ok" }));

  app.get("/.well-known/oauth-authorization-server", async (context) => {
    if (!auth) return context.json({ error: "not_found" }, 404);
    return context.json(await auth.api.getOAuthServerConfig());
  });
  app.get("/.well-known/openid-configuration", async (context) => {
    if (!auth) return context.json({ error: "not_found" }, 404);
    return context.json(await auth.api.getOpenIdConfig());
  });
  app.get("/.well-known/oauth-protected-resource", async (context) => {
    if (!auth) return context.json({ error: "not_found" }, 404);
    return context.json(
      await createProtectedResourceMetadata(auth)({
        resource: `${config.baseUrl}/api/v1`,
        authorization_servers: [config.baseUrl],
        scopes_supported: [...GATEWAY_SCOPES],
      }),
    );
  });
  app.get("/.well-known/oauth-protected-resource/mcp", async (context) => {
    if (!auth) return context.json({ error: "not_found" }, 404);
    return context.json(
      await createProtectedResourceMetadata(auth)({
        resource: mcpResource(config),
        authorization_servers: [config.baseUrl],
        scopes_supported: [...MCP_CAPABILITY_SCOPES],
      }),
    );
  });
  app.all("/.well-known/*", (context) => context.json({ error: "not_found" }, 404));

  app.use("/api/auth/*", authBodyLimit);
  for (const extension of extensions) extension.registerAuthRoutes?.(app, services);
  app.on(["GET", "POST"], "/api/auth/*", (context) => {
    if (!auth) return context.json({ error: "not_found" }, 404);
    return auth.handler(context.req.raw);
  });

  app.use("/api/v1/session", async (context, next) => {
    context.set("identity", await identities.fromBrowser(context.req.raw));
    await next();
  });
  registerApi(app, "getSession", async (context) => {
    const identity = context.get("identity");
    const capabilities: Record<string, boolean> = {
      admin: await isAdministrator(store, identity),
      sessions: auth !== undefined,
      sync: await store.sync.isAvailable(),
      sharing: true,
    };
    for (const extension of extensions) {
      const additions = await extension.sessionCapabilities?.(identity) ?? {};
      for (const [name, enabled] of Object.entries(additions)) {
        if (name in capabilities) throw new Error(`Duplicate session capability: ${name}`);
        capabilities[name] = enabled;
      }
    }
    return context.json({
      capabilities,
      user: {
        id: identity.userId,
        email: identity.email,
        name: identity.name,
      },
      workspace: { id: identity.workspaceId, type: "personal" },
    });
  });

  app.use("/api/v1/admin/*", authBodyLimit);
  app.use("/api/v1/admin/*", async (context, next) => {
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) {
      return context.json({ error: "invalid_origin" }, 403);
    }
    const identity = await identities.fromBrowser(context.req.raw);
    if (!await isAdministrator(store, identity)) {
      return context.json({ error: "forbidden" }, 403);
    }
    context.set("identity", identity);
    await next();
  });
  for (const kind of ["users", "organizations"] as const) {
    registerApi(app, kind === "users" ? "listServerUsers" : "listServerOrganizations", async (context) => {
      const page = z.object({ offset: z.coerce.number().int().min(0).max(1_000_000).default(0) }).safeParse(context.req.query());
      if (!page.success) return context.json({ error: "invalid_page" }, 400);
      const limit = 100;
      const items = kind === "users" ? await store.listServerUsers(limit + 1, page.data.offset)
        : await store.listServerOrganizations(limit + 1, page.data.offset);
      return context.json({ items: items.slice(0, limit), hasMore: items.length > limit });
    });
  }
  registerApi(app, "listAdministrators", async (context) => {
    const admins = await store.listAdminUsers();
    return context.json({ items: admins.map((admin) => ({ ...admin, role: "admin", removable: admins.length > 1 })), nextCursor: null });
  });
  registerApi(app, "addAdministrator", async (context) => {
    const parsed = memberSchema.safeParse(await context.req.json().catch(() => null));
    if (!parsed.success) return context.json({ error: "invalid_email" }, 400);
    if ((await store.listAdminUsers()).some((admin) => admin.email === parsed.data.email)) {
      return context.json({ error: "administrator_exists" }, 409);
    }
    const admin = await store.addAdminUser(parsed.data.email);
    return admin
      ? context.json({ ...admin, role: "admin", removable: true }, 201, { Location: `/api/v1/admin/members/${encodeURIComponent(admin.id)}` })
      : context.json({ error: "user_not_found" }, 404);
  });
  registerApi(app, "removeAdministrator", async (context) => {
    const userId = sync.parsePermissionPrincipal(context.req.param("userId")!);
    const result = await store.removeAdminUser(userId);
    if (result === "removed") return context.body(null, 204);
    return result === "last_admin"
      ? context.json({ error: "last_administrator" }, 409)
      : context.json({ error: "administrator_not_found" }, 404);
  });

  app.use("/api/v1/sessions/*", async (context, next) => {
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) {
      return context.json({ error: "invalid_origin" }, 403);
    }
    context.set("identity", await identities.fromBrowser(context.req.raw));
    await next();
  });
  registerApi(app, "listSessions", async (context) => {
    if (!auth) return context.json({ error: "not_available_in_this_auth_mode" }, 404);
    const identity = context.get("identity");
    const [current, sessions] = await Promise.all([
      auth.api.getSession({ headers: context.req.raw.headers }),
      authStore!.listDahliaSessions(identity.userId),
    ]);
    return context.json({ items:
      sessions.map((session) => ({
        id: session.id,
        createdAt: session.createdAt,
        expiresAt: session.expiresAt,
        userAgent: session.userAgent,
        current: session.sessionId === current?.session.id,
      })), nextCursor: null,
    });
  });
  registerApi(app, "revokeSession", async (context) => {
    if (!auth) return context.json({ error: "not_available_in_this_auth_mode" }, 404);
    const revoked = await authStore!.revokeDahliaSession(
      context.get("identity").userId,
      context.req.param("id")!,
    );
    return revoked ? context.body(null, 204) : context.json({ error: "session_not_found" }, 404);
  });

  registerApi(app, "getLatestSummary", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    context.header("Cache-Control", "no-store");
    return context.json(await sync.latestSummary(identity, await sync.meetingVault(identity, sync.parseId(context.req.param("meetingId")!)),
      sync.parseId(context.req.param("meetingId")!), context.req.query("manifest")));
  });
  registerApi(app, "listSummaries", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    context.header("Cache-Control", "no-store");
    return context.json(await sync.summaryVersions(identity, await sync.meetingVault(identity, sync.parseId(context.req.param("meetingId")!)),
      sync.parseId(context.req.param("meetingId")!), context.req.query("cursor"), context.req.query("limit")));
  });
  registerApi(app, "getSummary", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    context.header("Cache-Control", "no-store");
    return context.json(await sync.summaryVersion(identity, await sync.meetingVault(identity, sync.parseId(context.req.param("meetingId")!)),
      sync.parseId(context.req.param("meetingId")!), context.req.param("version")!));
  });
  registerApi(app, "getLatestSummaryJob", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    if (!dependencies.summaryService) return context.json({ error: "summary_unavailable" }, 503);
    context.header("cache-control", "no-store");
    return context.json({ job: summaryJobResponse(await dependencies.summaryService.status(identity,
      await sync.meetingVault(identity, sync.parseId(context.req.param("meetingId")!)), sync.parseId(context.req.param("meetingId")!),
      undefined)) });
  });
  for (const action of ["cancel", "retry"] as const) registerApi(app, action === "cancel" ? "cancelSummaryJob" : "retrySummaryJob", accountSettingsBodyLimit, async (context) => {
    const requiresBrowserOrigin = config.authProvider === "accounts" && !context.req.header("authorization");
    if ((requiresBrowserOrigin || context.req.header("origin")) && !mutationOriginAllowed(context.req.raw, config.baseUrl)) {
      return context.json({ error: "invalid_origin" }, 403);
    }
    const identity = action === "retry"
      ? await syncIdentity(context.req.raw)
      : await identities.fromBrowserOrGateway(context.req.raw, ALL_APIS_SCOPE);
    const service = dependencies.summaryService;
    if (!service) return context.json({ error: "summary_unavailable" }, 503);
    const vaultId = await sync.meetingVault(identity, sync.parseId(context.req.param("meetingId")!));
    const meetingId = sync.parseId(context.req.param("meetingId")!);
    const jobId = sync.parseId(context.req.param("jobId")!);
    const job = action === "cancel" ? await service.cancel(identity, vaultId, meetingId, jobId)
      : await service.retry(identity, vaultId, meetingId, jobId, await context.req.json().catch(() => null));
    if (action === "retry") context.header("Location", `/api/v1/meetings/${meetingId}/summary-jobs/${job.id}`);
    return context.json({ job: summaryJobResponse(job) }, action === "retry" ? 202 : 200);
  });
  registerApi(app, "startSummaryJob", accountSettingsBodyLimit, async (context) => {
    const requiresBrowserOrigin = config.authProvider === "accounts" && !context.req.header("authorization");
    if ((requiresBrowserOrigin || context.req.header("origin")) && !mutationOriginAllowed(context.req.raw, config.baseUrl)) {
      return context.json({ error: "invalid_origin" }, 403);
    }
    const identity = await syncIdentity(context.req.raw);
    if (!dependencies.summaryService) return context.json({ error: "summary_unavailable" }, 503);
    const vaultId = await sync.meetingVault(identity, sync.parseId(context.req.param("meetingId")!));
    const meetingId = sync.parseId(context.req.param("meetingId")!);
    const job = await dependencies.summaryService.start(identity, vaultId, meetingId, await context.req.json().catch(() => null));
    context.header("Location", `/api/v1/meetings/${meetingId}/summary-jobs/${job.id}`);
    return context.json({ job: summaryJobResponse(job) }, 202);
  });

  registerApi(app, "getSummaryJob", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    if (!dependencies.summaryService) return context.json({ error: "summary_unavailable" }, 503);
    const meetingId = sync.parseId(context.req.param("meetingId")!);
    const vaultId = await sync.meetingVault(identity, meetingId);
    const job = await dependencies.summaryService.status(identity, vaultId, meetingId, sync.parseId(context.req.param("jobId")!));
    return job ? context.json({ job: summaryJobResponse(job) }) : context.json({ error: "summary_job_not_found" }, 404);
  });

  registerApi(app, "getSettings", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    context.header("cache-control", "no-store");
    return context.json({ settings: await store.accountSettings.get(identity.userId) });
  });
  registerApi(app, "updateSettings", accountSettingsBodyLimit, async (context) => {
    const requiresBrowserOrigin = config.authProvider === "accounts" && !context.req.header("authorization");
    if ((requiresBrowserOrigin || context.req.header("origin"))
      && !mutationOriginAllowed(context.req.raw, config.baseUrl)) {
      return context.json({ error: "invalid_origin" }, 403);
    }
    const identity = await syncIdentity(context.req.raw);
    if (identity.impersonated) return context.json({ error: "impersonation_read_only" }, 403);
    const parsed = accountSettingsPatchSchema.safeParse(await context.req.json().catch(() => null));
    if (!parsed.success) return context.json({ error: "invalid_account_settings" }, 400);
    const { initialize, ...patch } = parsed.data;
    context.header("cache-control", "no-store");
    return context.json({ settings: await store.accountSettings.update(identity.userId, patch, initialize) });
  });

  async function syncIdentity(request: Request): Promise<Identity> {
    const identity = await identities.fromBrowserOrGateway(request, ALL_APIS_SCOPE);
    if (dependencies.onSyncMutation) jobOwners.set(request, identity.userId);
    return { ...identity, syncClient: { vaultTransfers: request.headers.get("X-Dahlia-Vault-Transfers") === "1" } };
  }

  registerApi(app, "getTransferAudience", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    return context.json(await sync.vaultTransferAudience(identity, sync.parseId(context.req.param("vaultId")!),
      sync.parseId(context.req.query("destinationVaultId") ?? "")));
  });
  registerApi(app, "transferVault", syncBodyLimit, async (context) => {
    const requiresBrowserOrigin = config.authProvider === "accounts" && !context.req.header("authorization");
    if ((requiresBrowserOrigin || context.req.header("origin")) && !mutationOriginAllowed(context.req.raw, config.baseUrl)) {
      return context.json({ error: "invalid_origin" }, 403);
    }
    const identity = await syncIdentity(context.req.raw);
    return context.json(await sync.transferVault(identity, sync.parseId(context.req.param("vaultId")!),
      context.req.header("Idempotency-Key"), await context.req.json().catch(() => null)));
  });
  registerApi(app, "getRelocations", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    return context.json(await sync.getVaultRelocations(identity, sync.parseId(context.req.param("vaultId")!)));
  });

  registerApi(app, "commitTransaction", syncBodyLimit, async (context) => {
    const requiresBrowserOrigin = config.authProvider === "accounts" && !context.req.header("authorization");
    if ((requiresBrowserOrigin || context.req.header("origin"))
      && !mutationOriginAllowed(context.req.raw, config.baseUrl)) {
      return context.json({ error: "invalid_origin" }, 403);
    }
    const identity = await syncIdentity(context.req.raw);
    return context.json(await sync.commitTransaction(identity, await context.req.json().catch(() => null)));
  });
  registerApi(app, "getChanges", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    return context.json(await sync.listChanges(
      identity,
      sync.parseId(context.req.param("vaultId")!),
      context.req.query("cursor"),
      context.req.query("highWaterCursor"),
    ));
  });
  registerApi(app, "resolveTransaction", syncBodyLimit, async (context) => {
    const requiresBrowserOrigin = config.authProvider === "accounts" && !context.req.header("authorization");
    if ((requiresBrowserOrigin || context.req.header("origin"))
      && !mutationOriginAllowed(context.req.raw, config.baseUrl)) {
      return context.json({ error: "invalid_origin" }, 403);
    }
    const identity = await syncIdentity(context.req.raw);
    return context.json(await sync.resolveTransaction(identity, await context.req.json().catch(() => null)));
  });
  registerApi(app, "getSnapshot", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    return context.json(await sync.listSnapshot(
      identity,
      sync.parseId(context.req.param("vaultId")!),
      context.req.query("cursor"),
      context.req.query("startCursor"),
    ));
  });
  registerApi(app, "getCapabilities", async (context) => {
    await syncIdentity(context.req.raw);
    if (!await store.sync.isAvailable()) return context.json({});
    const sources = dependencies.summaryService?.methods.map((method) => method.id) ?? [];
    return context.json({
      sync: { version: 4 },
      vaultTransfers: { version: 1 },
      recordingArchive: { version: 1 },
      meetingEvents: { version: 1 },
      search: { version: 1 },
      ...(dependencies.imageAnalysisEnabled === true ? { imageAnalysis: { version: 1 } } : {}),
      ...(sources.length ? { meetingSummaryGeneration: { version: 2, sources } } : {}),
    });
  });
  registerApi(app, "search", bodyLimit({ maxSize: 16 * 1024,
    onError: (context) => context.json({ error: "search_request_too_large" }, 413) }), async (context) => {
    const identity = await syncIdentity(context.req.raw);
    context.header("Cache-Control", "no-store");
    return context.json(await sync.searchAll(identity, { ...await context.req.json().catch(() => ({})), vaultId: sync.parseId(context.req.param("vaultId")!) }, context.req.raw.signal));
  });
  registerApi(app, "textSearch", accountSettingsBodyLimit, async (context) => {
    const identity = await syncIdentity(context.req.raw);
    const body = textSearchRequest.parse(await context.req.json());
    return context.json(await sync.searchText(identity, sync.parseId(context.req.param("vaultId")!),
      body.query, body.kind, body.cursor, body.limit === undefined ? undefined : String(body.limit)));
  });
  registerApi(app, "getEvents", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    const suppliedCursor = context.req.query("cursor") ?? context.req.header("last-event-id");
    let sequence = suppliedCursor ? decodeSyncCursor(suppliedCursor) : 0;
    return streamSSE(context, async (stream) => {
      let accountSettingsKey: number | null | undefined;
      while (!stream.aborted) {
        const cursor = await sync.latestCursor(identity);
        const latest = decodeSyncCursor(cursor);
        if (latest > sequence) {
          sequence = latest;
          await stream.writeSSE({ event: "invalidation", id: cursor, data: JSON.stringify({ cursor }) });
        }
        const settingsKey = await store.accountSettings.getRevision(identity.userId);
        if (settingsKey !== accountSettingsKey) {
          accountSettingsKey = settingsKey;
          await stream.writeSSE({ event: "account_settings", data: "{}" });
        }
        await stream.sleep(2_000);
      }
    });
  });

  registerApi(app, "putTranscriptChunk",
    syncBodyLimit,
    async (context, next) => { await context.req.arrayBuffer(); await next(); },
    async (context) => {
      const identity = await identities.fromGateway(context.req.raw, ALL_APIS_SCOPE);
      const meetingId = sync.parseId(context.req.param("meetingId")!);
      const patchId = sync.parseId(context.req.param("patchId")!);
      if (!/^\d+$/.test(context.req.param("chunkIndex")!)) {
        throw new RequestError(400, "invalid_transcript_chunk_index");
      }
      const contentHash = context.req.header("x-dahlia-content-sha256")?.toLowerCase();
      if (!contentHash || !/^[0-9a-f]{64}$/.test(contentHash)) {
        throw new RequestError(400, "invalid_transcript_chunk_hash");
      }
      const bytes = new Uint8Array(await context.req.arrayBuffer());
      const actualHash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
        .map((byte) => byte.toString(16).padStart(2, "0")).join("");
      if (actualHash !== contentHash) throw new RequestError(409, "transcript_chunk_hash_mismatch");
      let body: unknown;
      try {
        body = context.req.header("x-dahlia-public-content-sha256")
          ? JSON.parse(new TextDecoder().decode(bytes))
          : wireValue(JSON.parse(new TextDecoder().decode(bytes)), "chunk", "decode");
      } catch {
        throw new RequestError(400, "invalid_transcript_chunk");
      }
      await sync.putTranscriptChunk(
        identity,
        meetingId,
        patchId,
        Number(context.req.param("chunkIndex")!),
        context.req.header("x-dahlia-public-content-sha256") ?? contentHash,
        body,
      );
      return context.body(null, 204);
    },
  );
  registerApi(app, "putRecordingContent", async (context) => {
    const requiresBrowserOrigin = config.authProvider === "accounts" && !context.req.header("authorization");
    if ((requiresBrowserOrigin || context.req.header("origin")) && !mutationOriginAllowed(context.req.raw, config.baseUrl)) {
      return context.json({ error: "invalid_origin" }, 403);
    }
    const identity = await syncIdentity(context.req.raw);
    const result = await sync.putRecordingContent(identity, sync.parseId(context.req.param("meetingId")!), context.req.param("sessionId")!, context.req.param("source")!, context.req.raw);
    context.header("Location", result.record.contentUrl);
    return context.json(result.record, result.created ? 201 : 200);
  });
  registerApi(app, "listRecordings", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    return context.json(await sync.listRecordings(identity, sync.parseId(context.req.param("meetingId")!), context.req.query("cursor")));
  });
  for (const operation of ["getRecordingContent", "headRecordingContent"] as const) registerApi(app, operation, async (context) => {
    const identity = await syncIdentity(context.req.raw);
    return sync.recordingContent(identity, sync.parseId(context.req.param("meetingId")!), context.req.param("recordingId")!, context.req.param("source")!, context.req.raw);
  });
  registerApi(app, "reserveFileUpload", accountSettingsBodyLimit, async (context) => {
    const requiresBrowserOrigin = config.authProvider === "accounts" && !context.req.header("authorization");
    if ((requiresBrowserOrigin || context.req.header("origin")) && !mutationOriginAllowed(context.req.raw, config.baseUrl)) {
      return context.json({ error: "invalid_origin" }, 403);
    }
    const identity = await syncIdentity(context.req.raw);
    const result = await sync.reserveFileUpload(identity, await context.req.json().catch(() => null));
    context.header("Location", `/api/v1/file-uploads/${result.file.id}/content`);
    return context.json(result.file, result.created ? 201 : 200);
  });
  registerApi(app, "putFileContent", async (context) => {
    const requiresBrowserOrigin = config.authProvider === "accounts" && !context.req.header("authorization");
    if ((requiresBrowserOrigin || context.req.header("origin")) && !mutationOriginAllowed(context.req.raw, config.baseUrl)) {
      return context.json({ error: "invalid_origin" }, 403);
    }
    const identity = await syncIdentity(context.req.raw);
    const result = await sync.putFileContent(identity, sync.parseId(context.req.param("fileId")!), context.req.raw);
    context.header("Location", `/api/v1/files/${result.file.id}/content`);
    return context.json(result.file, result.created ? 201 : 200);
  });
  registerApi(app, "updateFile", bodyLimit({ maxSize: 128 * 1024,
    onError: (context) => context.json({ error: "file_patch_too_large" }, 413) }), async (context) => {
    const requiresBrowserOrigin = config.authProvider === "accounts" && !context.req.header("authorization");
    if ((requiresBrowserOrigin || context.req.header("origin")) && !mutationOriginAllowed(context.req.raw, config.baseUrl)) {
      return context.json({ error: "invalid_origin" }, 403);
    }
    const identity = await syncIdentity(context.req.raw);
    return context.json(await sync.patchFile(identity, sync.parseId(context.req.param("fileId")!), await context.req.json().catch(() => null)));
  });
  registerApi(app, "getFile", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    return context.json(await sync.getFile(identity, sync.parseId(context.req.param("fileId")!)));
  });
  registerApi(app, "listFiles", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    return context.json(await sync.listFiles(identity, sync.parseId(context.req.param("vaultId")!), context.req.query("cursor")));
  });
  registerApi(app, "listVaults", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    return context.json({ items: await sync.listVaults(identity, context.req.query("userId"), context.req.query("organizationId")), nextCursor: null });
  });
  registerApi(app, "getVault", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    const vault = await sync.getVault(identity, sync.parseId(context.req.param("vaultId")!));
    return vault ? context.json(vault) : context.json({ error: "vault_not_found" }, 404);
  });
  registerApi(app, "getProject", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    const project = await sync.getProjectById(identity, sync.parseId(context.req.param("projectId")!));
    return project ? context.json(project) : context.json({ error: "project_not_found" }, 404);
  });
  registerApi(app, "getMeeting", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    const meeting = await sync.getMeetingById(identity, sync.parseId(context.req.param("meetingId")!));
    return meeting ? context.json(meetingMetadata({ ...meeting })) : context.json({ error: "meeting_not_found" }, 404);
  });
  registerApi(app, "listProjects", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    return context.json({ items: await sync.listProjects(identity, sync.parseId(context.req.param("vaultId")!)), nextCursor: null });
  });

  registerApi(app, "listMeetings", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    const vaultId = sync.parseId(context.req.param("vaultId")!);
    const page = await sync.listMeetings(
      identity,
      vaultId,
      context.req.query("query"),
      context.req.raw.signal,
      context.req.query("projectId") !== undefined ? sync.parseId(context.req.query("projectId")!) : undefined,
      context.req.query("cursor"),
      context.req.query("projectScope"),
    );
    return context.json({ ...page, nextCursor: page.nextCursor ?? null });
  });

  registerApi(app, "listTranscripts", async (context) => {
    context.header("cache-control", "no-store");
    const identity = await syncIdentity(context.req.raw);
    const vaultId = await sync.meetingVault(identity, sync.parseId(context.req.param("meetingId")!));
    const meetingId = sync.parseId(context.req.param("meetingId")!);
    return context.json(await sync.transcriptVersions(identity, vaultId, meetingId, context.req.query("cursor"), context.req.query("limit")));
  });
  for (const operation of ["getLatestTranscript", "getTranscript"] as const) registerApi(app, operation, async (context) => {
    context.header("cache-control", "no-store");
    const identity = await syncIdentity(context.req.raw);
    return context.json(await sync.transcriptContent(identity, await sync.meetingVault(identity, sync.parseId(context.req.param("meetingId")!)),
      sync.parseId(context.req.param("meetingId")!), context.req.param("version")! ?? "latest", context.req.query("manifest"), context.req.query("cursor")));
  });
  registerApi(app, "listMeetingFiles", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    return context.json(await sync.listFiles(identity, await sync.meetingVault(identity, sync.parseId(context.req.param("meetingId")!)),
      context.req.query("cursor"), sync.parseId(context.req.param("meetingId")!)));
  });
  registerApi(app, "listPermissions", async (context) => {
    const identity = await identities.fromBrowser(context.req.raw);
    return context.json({ items: await sync.listPermissions(identity, sync.parseId(context.req.param("vaultId")!)), nextCursor: null });
  });
  registerApi(app, "putOrganizationPermission", async (context) => {
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const identity = await identities.fromBrowser(context.req.raw);
    await sync.putMemberPermission(
      identity,
      sync.parseId(context.req.param("vaultId")!),
      "organization",
      sync.parsePermissionPrincipal(context.req.param("organizationId")!),
    );
    return context.body(null, 204);
  });
  registerApi(app, "deleteOrganizationPermission", async (context) => {
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const identity = await identities.fromBrowser(context.req.raw);
    await sync.deleteMemberPermission(
      identity,
      sync.parseId(context.req.param("vaultId")!),
      "organization",
      sync.parsePermissionPrincipal(context.req.param("organizationId")!),
    );
    return context.body(null, 204);
  });
  registerApi(app, "putTeamPermission", async (context) => {
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const identity = await identities.fromBrowser(context.req.raw);
    await sync.putMemberPermission(
      identity,
      sync.parseId(context.req.param("vaultId")!),
      "team",
      sync.parsePermissionPrincipal(context.req.param("teamId")!),
    );
    return context.body(null, 204);
  });
  registerApi(app, "deleteTeamPermission", async (context) => {
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const identity = await identities.fromBrowser(context.req.raw);
    await sync.deleteMemberPermission(
      identity,
      sync.parseId(context.req.param("vaultId")!),
      "team",
      sync.parsePermissionPrincipal(context.req.param("teamId")!),
    );
    return context.body(null, 204);
  });

  registerApi(app, "listOrganizations", async (context) => {
    const identity = await syncIdentity(context.req.raw);
    return context.json({ items: await sync.listOrganizations(identity), nextCursor: null });
  });
  registerApi(app, "getOrganization", async (context) => {
    if (config.authProvider !== "header" || context.req.param("organizationId")! !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    const identity = await identities.fromBrowser(context.req.raw);
    const organization = await store.getExternalOrganization(identity.userId);
    return organization ? context.json(organization) : context.json({ error: "not_found" }, 404);
  });
  registerApi(app, "listOrganizationMembers", async (context) => {
    if (config.authProvider !== "header" || context.req.param("organizationId")! !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    const identity = await identities.fromBrowser(context.req.raw);
    const members = await store.listExternalOrganizationMembers(identity.userId);
    return members
      ? context.json({ items: members.map((member) => ({
          id: member.id,
          userId: member.userId,
          role: member.role,
          user: { name: member.name, email: member.email },
        })), nextCursor: null })
      : context.json({ error: "not_found" }, 404);
  });
  registerApi(app, "listTeams", async (context) => {
    if (config.authProvider !== "header" || context.req.param("organizationId")! !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    const identity = await identities.fromBrowser(context.req.raw);
    const teams = await store.listExternalTeams(identity.userId);
    return teams ? context.json({ items: teams, nextCursor: null }) : context.json({ error: "not_found" }, 404);
  });
  registerApi(app, "createTeam", authBodyLimit, async (context) => {
    if (config.authProvider !== "header" || context.req.param("organizationId")! !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const input = teamInputSchema.safeParse(await context.req.json().catch(() => null));
    if (!input.success) return context.json({ error: "invalid_team" }, 400);
    const identity = await identities.fromBrowser(context.req.raw);
    const team = await store.createExternalTeam(identity.userId, input.data.name);
    return team ? context.json(team, 201, { Location: `/api/v1/organizations/${encodeURIComponent(team.organizationId)}/teams/${encodeURIComponent(team.id)}` }) : context.json({ error: "not_found" }, 404);
  });
  registerApi(app, "updateTeam", authBodyLimit, async (context) => {
    if (config.authProvider !== "header" || context.req.param("organizationId")! !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const input = teamInputSchema.safeParse(await context.req.json().catch(() => null));
    if (!input.success) return context.json({ error: "invalid_team" }, 400);
    const identity = await identities.fromBrowser(context.req.raw);
    const team = await store.updateExternalTeam(
      identity.userId,
      sync.parsePermissionPrincipal(context.req.param("teamId")!),
      input.data.name,
    );
    return team ? context.json(team) : context.json({ error: "not_found" }, 404);
  });
  registerApi(app, "deleteTeam", async (context) => {
    if (config.authProvider !== "header" || context.req.param("organizationId")! !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const identity = await identities.fromBrowser(context.req.raw);
    return await store.deleteExternalTeam(
      identity.userId,
      sync.parsePermissionPrincipal(context.req.param("teamId")!),
    ) ? context.body(null, 204) : context.json({ error: "not_found" }, 404);
  });
  registerApi(app, "listTeamMembers", async (context) => {
    if (config.authProvider !== "header" || context.req.param("organizationId")! !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    const identity = await identities.fromBrowser(context.req.raw);
    const members = await store.listExternalTeamMembers(
      identity.userId,
      sync.parsePermissionPrincipal(context.req.param("teamId")!),
    );
    return members
      ? context.json({ items: members.map((member) => ({ ...member, teamId: context.req.param("teamId")! })), nextCursor: null })
      : context.json({ error: "not_found" }, 404);
  });
  registerApi(app, "putTeamMember", async (context) => {
    if (config.authProvider !== "header" || context.req.param("organizationId")! !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const identity = await identities.fromBrowser(context.req.raw);
    return await store.addExternalTeamMember(
      identity.userId,
      sync.parsePermissionPrincipal(context.req.param("teamId")!),
      sync.parsePermissionPrincipal(context.req.param("userId")!),
    ) ? context.body(null, 204) : context.json({ error: "not_found" }, 404);
  });
  registerApi(app, "deleteTeamMember", async (context) => {
    if (config.authProvider !== "header" || context.req.param("organizationId")! !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const identity = await identities.fromBrowser(context.req.raw);
    return await store.removeExternalTeamMember(
      identity.userId,
      sync.parsePermissionPrincipal(context.req.param("teamId")!),
      sync.parsePermissionPrincipal(context.req.param("userId")!),
    ) ? context.body(null, 204) : context.json({ error: "not_found" }, 404);
  });
  for (const operation of ["getFileContent", "headFileContent"] as const) registerApi(app, operation, async (context) => {
    const identity = await syncIdentity(context.req.raw);
    return sync.readFile(identity, sync.parseId(context.req.param("fileId")!), context.req.method as "GET" | "HEAD", context.req.raw);
  });
  for (const operation of ["getFileVariant", "headFileVariant"] as const) registerApi(app, operation, async (context) => {
    const identity = await syncIdentity(context.req.raw);
    const variant = context.req.param("variant")!;
    if (!Object.hasOwn(SCREENSHOT_VARIANTS, variant)) return context.json({ error: "file_variant_unavailable" }, 404);
    return sync.readFile(identity, sync.parseId(context.req.param("fileId")!), context.req.method as "GET" | "HEAD", context.req.raw, variant as ScreenshotVariant);
  });
  app.on(
    ["GET", "HEAD"],
    "/mcp/resources/vaults/:vaultId/meetings/:meetingId/screenshots/:screenshotId/content",
    async (context) => {
      const identity = await identities.fromMcpResource(context.req.raw, MCP_READ_SCOPE);
      const response = await sync.readScreenshot(
        identity,
        sync.parseId(context.req.param("vaultId")),
        sync.parseId(context.req.param("meetingId")),
        sync.parseId(context.req.param("screenshotId")),
        context.req.method as "GET" | "HEAD",
        context.req.raw,
      );
      response.headers.set("Cache-Control", "no-store");
      return response;
    },
  );

  app.post("/mcp", mcpBodyLimit, async (context) => {
    const origin = context.req.header("origin");
    if (origin && origin !== new URL(config.baseUrl).origin) {
      return context.json({ error: "invalid_origin" }, 403);
    }
    const contentLength = context.req.header("content-length");
    if (contentLength && !/^\d+$/.test(contentLength)) {
      return context.json({ error: "invalid_content_length" }, 400);
    }
    if (contentLength && Number(contentLength) > MCP_MAX_REQUEST_BYTES) {
      return context.json({ error: "request_too_large" }, 413);
    }
    let authInfo: AuthInfo | Response;
    if (mcpRequestAuth) {
      authInfo = await mcpRequestAuth(context.req.raw);
      if (authInfo instanceof Response) return authInfo;
    } else {
      const identity = await identities.fromMcpHeader(context.req.raw);
      authInfo = {
        token: "",
        clientId: "trusted-proxy",
        scopes: [MCP_SCOPE],
        expiresAt: Math.floor(Date.now() / 1000) + 60,
        resource: new URL(mcpResource(config)),
        extra: { identity },
      };
    }
    return mcp.fetch(context.req.raw, { authInfo });
  });
  app.all("/mcp", (context) => context.json({ error: "method_not_allowed" }, 405, { Allow: "POST" }));

  const fallbackRoutes = new TrieRouter<"domain" | "extension">();
  for (const route of app.routes) {
    if (route.method !== "ALL" && route.path.startsWith("/api/v1/")) fallbackRoutes.add("ALL", route.path, "domain");
  }
  app.use("/api/v1/*", async (context, next) => {
    const matches = fallbackRoutes.match(context.req.method === "HEAD" ? "GET" : context.req.method, context.req.path)[0]
      .map(([kind]) => kind);
    // Domain 405s accept browser sessions; extension handlers retain gateway authentication.
    if (matches.includes("domain") && !matches.includes("extension")) {
      await next();
      return;
    }
    context.set("identity", await identities.fromGateway(
      context.req.raw,
      ALL_APIS_SCOPE,
    ));
    for (const extension of extensions) {
      const response = await extension.beforeGateway?.({
        identity: context.get("identity"),
        method: context.req.method,
        path: context.req.path,
      });
      if (response) return response;
    }
    await next();
  });
  app.get("/api/v1/models", async (context) => context.json(await gateway.models(context.req.raw)));
  app.post("/api/v1/responses", async (context) => gateway.responses(context.req.raw, context.get("identity")));

  const extensionStart = app.routes.length;
  for (const extension of extensions) extension.registerRoutes?.(app, services);
  for (const route of app.routes.slice(extensionStart)) fallbackRoutes.add("ALL", route.path, "extension");

  const methodRoutes = new TrieRouter<string>();
  const methodPaths = new Set<string>();
  for (const route of app.routes) {
    if (route.method === "ALL" || route.path.startsWith("/api/auth/") || (!route.path.startsWith("/api/") && !route.path.startsWith("/mcp/resources/"))) continue;
    methodRoutes.add("ALL", route.path, route.method);
    if (route.method === "GET") methodRoutes.add("ALL", route.path, "HEAD");
    methodPaths.add(route.path);
  }

  for (const path of methodPaths) {
    app.all(path, async (context) => {
      if ((path.startsWith("/api/v1/sessions") && !auth)
        || (path.startsWith("/api/v1/organizations/") && config.authProvider !== "header")) {
        return context.json({ error: "not_found" }, 404);
      }
      if (path.startsWith("/mcp/resources/")) await identities.fromMcpResource(context.req.raw, MCP_READ_SCOPE);
      else if (path.startsWith("/api/v1/")) await syncIdentity(context.req.raw);
      const allowed = new Set(methodRoutes.match("ALL", context.req.path)[0].map(([method]) => method));
      return context.json({ error: "method_not_allowed" }, 405, { Allow: [...allowed].join(", ") });
    });
  }

  app.all("/api/*", (context) => context.json({ error: "not_found" }, 404));

  app.onError((error, context) => {
    if (error instanceof HTTPException) return context.json({ error: "invalid_request" }, error.status);
    if (error instanceof AuthenticationError) {
      const challenge = error.oauthChallenge
        ? `Bearer resource_metadata="${config.baseUrl}/.well-known/oauth-protected-resource${
          context.req.path.startsWith("/mcp") ? "/mcp" : ""
        }"`
        : "Bearer";
      return context.json({ error: "unauthorized", message: error.message }, 401, { "WWW-Authenticate": challenge });
    }
    if (error instanceof IdentityProjectionError) {
      return context.json({ error: error.message }, 409);
    }
    if (error instanceof GatewayRequestError) return gatewayError(error);
    if (error instanceof RequestError) {
      return Response.json({ error: error.code }, { status: error.status });
    }
    if (error instanceof SyncTransactionError) {
      return Response.json({
        error: error.code,
        conflicts: error.conflicts,
        ...(error.operationId ? { operationId: error.operationId } : {}),
      }, { status: error.status });
    }
    if (error instanceof SyncStoreUnavailableError) {
      return context.json({ error: error.message }, 503);
    }
    console.error(JSON.stringify({ level: "error", event: "request_failed", route: requestRoute(context.req.path) }));
    return context.json({ error: "internal_server_error" }, 500);
  });

  installPublicIDs(app);
  return Object.assign(app, { runStorageMaintenance: () => sync.runStorageMaintenance() });
}

function requestRoute(path: string): string {
  if (path === "/mcp") return path;
  if (path.startsWith("/api/v1/")) return "/api/v1/*";
  if (path.startsWith("/api/")) return "/api/*";
  if (path.startsWith("/.well-known/")) return "/.well-known/*";
  return "other";
}

async function isAdministrator(store: AuthStore, identity: Identity): Promise<boolean> {
  try {
    return await store.isAdminUser(identity.userId);
  } catch {
    return false;
  }
}
