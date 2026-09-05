import { Hono } from "hono";
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
import { EXTERNAL_ORGANIZATION_ID, type AuthStore } from "./auth/store";
import { mcpResource, type AppConfig } from "./config";
import {
  ARTIFACT_METADATA_MEDIA_TYPE,
  ArtifactRequestError,
  ArtifactService,
  artifactResponse,
} from "./artifacts/service";
import type { ObjectStorage } from "./artifacts/storage";
import { createArtifactMcpHandler, MCP_MAX_REQUEST_BYTES } from "./mcp";
import { MeetingSyncService } from "./sync/service";
import { decodeSyncCursor, SyncStoreUnavailableError, SyncTransactionError } from "./sync/store";
import type { SearchTokenizer } from "./search/tokenizer";
import type { SearchEmbedder } from "./search/embedding";
import {
  CODEX_AUTO_REVIEW_ALIAS,
  MODEL_ALIAS_PATTERN,
  UPSTREAM_MODEL_MAX_LENGTH,
} from "./ai-gateway/model-alias";
import { gatewayError, GatewayRequestError, GatewayService } from "./ai-gateway/service";

export const AUTH_MAX_REQUEST_BYTES = 64 * 1024;
const ARTIFACT_PATCH_MAX_REQUEST_BYTES = 1024;
const SYNC_JSON_MAX_REQUEST_BYTES = 8 * 1024 * 1024;
const teamInputSchema = z.object({ name: z.string().trim().min(1).max(100) });

export const authBodyLimit = bodyLimit({
  maxSize: AUTH_MAX_REQUEST_BYTES,
  onError: (context) => context.json({ error: "request_too_large" }, 413),
});
const artifactPatchBodyLimit = bodyLimit({
  maxSize: ARTIFACT_PATCH_MAX_REQUEST_BYTES,
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

export interface AppVariables {
  identity: Identity;
}

export type DahliaServerApp = Hono<{ Variables: AppVariables }>;

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
  extensions?: readonly DahliaServerExtension[];
  artifactStorage?: ObjectStorage;
  searchTokenizer?: SearchTokenizer;
  searchEmbedder?: SearchEmbedder;
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

const aliasSchema = z.string().regex(MODEL_ALIAS_PATTERN).refine((alias) => alias !== CODEX_AUTO_REVIEW_ALIAS);
const modelFieldsSchema = z.object({
  upstreamModel: z.string().trim().min(1).max(UPSTREAM_MODEL_MAX_LENGTH),
  displayName: z.string().trim().min(1).max(100).nullable().optional(),
  enabled: z.boolean(),
});
const createModelSchema = modelFieldsSchema.extend({ alias: aliasSchema });
const memberSchema = z.object({ email: z.string().trim().email().transform((value) => value.toLowerCase()) });

export function mutationOriginAllowed(request: Request, baseUrl: string): boolean {
  if (["GET", "HEAD", "OPTIONS"].includes(request.method)) return true;
  return request.headers.get("origin") === new URL(baseUrl).origin;
}

function acceptsArtifactMetadata(accept: string | undefined): boolean {
  return accept?.split(",").some((representation) => {
    const [mediaType, ...parameters] = representation.split(";").map((value) => value.trim());
    if (mediaType?.toLowerCase() !== ARTIFACT_METADATA_MEDIA_TYPE) return false;
    const quality = parameters.find((parameter) => /^q\s*=/i.test(parameter));
    if (!quality) return true;
    const match = /^q\s*=\s*(\d(?:\.\d+)?)$/i.exec(quality);
    const value = match ? Number(match[1]) : 0;
    return value > 0 && value <= 1;
  }) ?? false;
}

export function createApp(dependencies: AppDependencies) {
  const { config } = dependencies;
  const app = new Hono<{ Variables: AppVariables }>();
  const store = dependencies.authStore;
  if (!store) throw new Error("The Dahlia application store must be initialized before creating the application");
  const authStore = config.authProvider === "accounts" ? store : undefined;
  const auth: DahliaAuth | undefined = config.authProvider === "accounts" ? dependencies.auth : undefined;
  if (config.authProvider === "accounts" && (!auth || !authStore)) {
    throw new Error("Better Auth must be initialized before creating the application");
  }
  const extensions = dependencies.extensions ?? [];
  const identities = new IdentityService(config, auth, (identity) => store.ensureIdentityUser(identity));
  const gateway = new GatewayService(config, store, dependencies.fetch);
  const artifacts = new ArtifactService(config, store, dependencies.artifactStorage);
  const sync = new MeetingSyncService(
    store.sync,
    dependencies.artifactStorage,
    dependencies.searchTokenizer,
    dependencies.searchEmbedder,
  );
  const mcp = createArtifactMcpHandler(config, artifacts, sync);
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
  app.use("/api/*", async (context, next) => {
    await next();
    context.header("Cache-Control", "no-store");
  });
  app.use("/mcp", async (context, next) => {
    await next();
    context.header("Cache-Control", "no-store");
  });

  app.get("/healthz", (context) => context.json({ status: "ok" }));

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

  app.use("/api/session", async (context, next) => {
    context.set("identity", await identities.fromBrowser(context.req.raw));
    await next();
  });
  app.get("/api/session", async (context) => {
    const identity = context.get("identity");
    const capabilities: Record<string, boolean> = {
      admin: await isAdministrator(store, identity),
      databricksModels: config.provider?.backend === "databricks",
      sessions: auth !== undefined,
      sync: await store.sync.isAvailable(),
      sharing: config.syncSharingEnabled === true,
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

  app.use("/api/admin/*", authBodyLimit);
  app.use("/api/admin/*", async (context, next) => {
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
  app.get("/api/admin/models", async (context) => context.json(await gateway.adminModels(context.req.raw)));
  app.post("/api/admin/models", async (context) => {
    const parsed = createModelSchema.safeParse(await context.req.json().catch(() => null));
    if (!parsed.success) return context.json({ error: "invalid_model_alias" }, 400);
    const created = await store.createModelAlias({
      ...parsed.data,
      displayName: parsed.data.displayName ?? null,
    });
    return created
      ? context.json((await store.listModelAliases()).find((model) => model.alias === parsed.data.alias)!, 201)
      : context.json({ error: "model_alias_exists" }, 409);
  });
  app.patch("/api/admin/models/:alias", async (context) => {
    const alias = aliasSchema.safeParse(context.req.param("alias"));
    const update = modelFieldsSchema.safeParse(await context.req.json().catch(() => null));
    if (!alias.success || !update.success) {
      return context.json({ error: "invalid_model_alias" }, 400);
    }
    if (!await store.updateModelAlias(alias.data, {
      ...update.data,
      displayName: update.data.displayName ?? null,
    })) return context.json({ error: "model_alias_not_found" }, 404);
    const model = (await store.listModelAliases()).find((candidate) => candidate.alias === alias.data);
    return model
      ? context.json(model)
      : context.json({ error: "model_alias_not_found" }, 404);
  });
  app.delete("/api/admin/models/:alias", async (context) => {
    const alias = aliasSchema.safeParse(context.req.param("alias"));
    if (!alias.success) return context.json({ error: "invalid_model_alias" }, 400);
    return await store.deleteModelAlias(alias.data)
      ? context.body(null, 204)
      : context.json({ error: "model_alias_not_found" }, 404);
  });
  app.get("/api/admin/members", async (context) => {
    const admins = await store.listAdminUsers();
    return context.json(admins.map((admin) => ({ ...admin, role: "admin", removable: admins.length > 1 })));
  });
  app.post("/api/admin/members", async (context) => {
    const parsed = memberSchema.safeParse(await context.req.json().catch(() => null));
    if (!parsed.success) return context.json({ error: "invalid_email" }, 400);
    if ((await store.listAdminUsers()).some((admin) => admin.email === parsed.data.email)) {
      return context.json({ error: "administrator_exists" }, 409);
    }
    const admin = await store.addAdminUser(parsed.data.email);
    return admin
      ? context.json({ ...admin, role: "admin", removable: true }, 201)
      : context.json({ error: "user_not_found" }, 404);
  });
  app.delete("/api/admin/members/:email", async (context) => {
    const email = z.email().safeParse(context.req.param("email").trim().toLowerCase());
    if (!email.success) return context.json({ error: "invalid_email" }, 400);
    const result = await store.removeAdminUser(email.data);
    if (result === "removed") return context.body(null, 204);
    return result === "last_admin"
      ? context.json({ error: "last_administrator" }, 409)
      : context.json({ error: "administrator_not_found" }, 404);
  });

  app.use("/api/sessions/*", async (context, next) => {
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) {
      return context.json({ error: "invalid_origin" }, 403);
    }
    context.set("identity", await identities.fromBrowser(context.req.raw));
    await next();
  });
  app.get("/api/sessions", async (context) => {
    if (!auth) return context.json({ error: "not_available_in_this_auth_mode" }, 404);
    const identity = context.get("identity");
    const [current, sessions] = await Promise.all([
      auth.api.getSession({ headers: context.req.raw.headers }),
      authStore!.listDahliaSessions(identity.userId),
    ]);
    return context.json(
      sessions.map((session) => ({
        id: session.id,
        createdAt: session.createdAt,
        expiresAt: session.expiresAt,
        userAgent: session.userAgent,
        current: session.sessionId === current?.session.id,
      })),
    );
  });
  app.delete("/api/sessions/:id", async (context) => {
    if (!auth) return context.json({ error: "not_available_in_this_auth_mode" }, 404);
    const revoked = await authStore!.revokeDahliaSession(
      context.get("identity").userId,
      context.req.param("id"),
    );
    return revoked ? context.body(null, 204) : context.json({ error: "session_not_found" }, 404);
  });

  app.get("/api/v1/artifacts", async (context) => {
    const identity = await identities.fromBrowserOrGateway(context.req.raw, ALL_APIS_SCOPE);
    const page = await artifacts.list(identity.workspaceId, context.req.query("cursor"));
    return context.json({
      items: page.items.map(artifactResponse),
      ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
    });
  });
  app.post("/api/v1/artifacts", async (context) => {
    const identity = await identities.fromGateway(context.req.raw, ALL_APIS_SCOPE);
    const artifact = await artifacts.create(identity, context.req.raw);
    return context.json({
      ...artifactResponse(artifact),
      viewerUrl: `${config.baseUrl}/artifacts/${artifact.id}`,
    }, 201, {
      Location: `${config.baseUrl}/api/v1/artifacts/${artifact.id}`,
    });
  });
  app.on(["GET", "HEAD"], "/api/v1/artifacts/:artifactId", async (context) => {
    const artifact = await getReadableArtifact(context.req.raw, context.req.param("artifactId"));
    if (!artifact) return context.json({ error: "artifact_not_found" }, 404);
    if (context.req.method === "GET" && acceptsArtifactMetadata(context.req.header("accept"))) {
      return context.json(artifactResponse(artifact), 200, {
        "Content-Type": ARTIFACT_METADATA_MEDIA_TYPE,
        Vary: "Accept",
      });
    }
    const response = await artifacts.read(artifact, context.req.method as "GET" | "HEAD", context.req.raw);
    if (context.req.method === "GET") response.headers.set("Vary", "Accept");
    return response;
  });
  app.on(["GET", "HEAD"], "/api/v1/artifacts/:artifactId/content", async (context) => {
    const artifact = await getReadableArtifact(context.req.raw, context.req.param("artifactId"));
    if (!artifact) return context.json({ error: "artifact_not_found" }, 404);
    return artifacts.read(artifact, context.req.method as "GET" | "HEAD", context.req.raw);
  });
  app.put("/api/v1/artifacts/:artifactId", async (context) => {
    const id = artifacts.parseId(context.req.param("artifactId"));
    const identity = await identities.fromGateway(context.req.raw, ALL_APIS_SCOPE);
    return context.json(artifactResponse(await artifacts.put(id, identity, context.req.raw)));
  });
  app.patch("/api/v1/artifacts/:artifactId", artifactPatchBodyLimit, async (context) => {
    const id = artifacts.parseId(context.req.param("artifactId"));
    const identity = await identities.fromGateway(context.req.raw, ALL_APIS_SCOPE);
    const body = await context.req.json<unknown>().catch((): unknown => undefined);
    return context.json(artifactResponse(await artifacts.setVisibility(id, identity, body, context.req.raw.signal)));
  });
  app.delete("/api/v1/artifacts/:artifactId", async (context) => {
    const id = artifacts.parseId(context.req.param("artifactId"));
    const identity = await identities.fromGateway(context.req.raw, ALL_APIS_SCOPE);
    await artifacts.delete(id, identity, context.req.raw.signal);
    return context.body(null, 204);
  });

  app.post("/api/v1/transactions", syncBodyLimit, async (context) => {
    const requiresBrowserOrigin = config.authProvider === "accounts" && !context.req.header("authorization");
    if ((requiresBrowserOrigin || context.req.header("origin"))
      && !mutationOriginAllowed(context.req.raw, config.baseUrl)) {
      return context.json({ error: "invalid_origin" }, 403);
    }
    const identity = await identities.fromBrowserOrGateway(context.req.raw, ALL_APIS_SCOPE);
    return context.json(await sync.commitTransaction(identity, await context.req.json().catch(() => null)));
  });
  app.get("/api/v1/vaults/:vaultId/changes", async (context) => {
    const identity = await identities.fromBrowserOrGateway(context.req.raw, ALL_APIS_SCOPE);
    return context.json(await sync.listChanges(
      identity,
      sync.parseId(context.req.param("vaultId")),
      context.req.query("cursor"),
      context.req.query("highWaterCursor"),
    ));
  });
  app.get("/api/v1/events", async (context) => {
    const identity = await identities.fromBrowserOrGateway(context.req.raw, ALL_APIS_SCOPE);
    const suppliedCursor = context.req.query("cursor") ?? context.req.header("last-event-id");
    let sequence = suppliedCursor ? decodeSyncCursor(suppliedCursor) : 0;
    return streamSSE(context, async (stream) => {
      while (!stream.aborted) {
        const cursor = await sync.latestCursor(identity);
        const latest = decodeSyncCursor(cursor);
        if (latest > sequence) {
          sequence = latest;
          await stream.writeSSE({ event: "invalidation", id: cursor, data: JSON.stringify({ cursor }) });
        }
        await stream.sleep(2_000);
      }
    });
  });

  app.put(
    "/api/v1/vaults/:vaultId/meetings/:meetingId/transcripts/:patchId/chunks/:chunkIndex",
    syncBodyLimit,
    async (context) => {
      const identity = await identities.fromGateway(context.req.raw, ALL_APIS_SCOPE);
      const vaultId = sync.parseId(context.req.param("vaultId"));
      const meetingId = sync.parseId(context.req.param("meetingId"));
      const patchId = sync.parseId(context.req.param("patchId"));
      if (!/^\d+$/.test(context.req.param("chunkIndex"))) {
        throw new ArtifactRequestError(400, "invalid_transcript_chunk_index");
      }
      const contentHash = context.req.header("x-dahlia-content-sha256")?.toLowerCase();
      if (!contentHash || !/^[0-9a-f]{64}$/.test(contentHash)) {
        throw new ArtifactRequestError(400, "invalid_transcript_chunk_hash");
      }
      const bytes = await context.req.raw.arrayBuffer();
      const actualHash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
        .map((byte) => byte.toString(16).padStart(2, "0")).join("");
      if (actualHash !== contentHash) throw new ArtifactRequestError(409, "transcript_chunk_hash_mismatch");
      let body: unknown;
      try {
        body = JSON.parse(new TextDecoder().decode(bytes));
      } catch {
        throw new ArtifactRequestError(400, "invalid_transcript_chunk");
      }
      await sync.putTranscriptChunk(
        identity,
        vaultId,
        meetingId,
        patchId,
        Number(context.req.param("chunkIndex")),
        contentHash,
        body,
      );
      return context.body(null, 204);
    },
  );
  app.put(
    "/api/v1/vaults/:vaultId/meetings/:meetingId/screenshots/:screenshotId/content",
    async (context) => {
      const identity = await identities.fromGateway(context.req.raw, ALL_APIS_SCOPE);
      const vaultId = sync.parseId(context.req.param("vaultId"));
      const meetingId = sync.parseId(context.req.param("meetingId"));
      const screenshotId = sync.parseId(context.req.param("screenshotId"));
      const screenshot = await sync.putScreenshot(identity, vaultId, meetingId, screenshotId, context.req.raw);
      return context.json({
        screenshotId: screenshot.screenshotId,
        contentType: screenshot.contentType,
        contentLength: screenshot.contentLength,
      });
    },
  );
  app.get("/api/v1/vaults", async (context) => {
    const identity = await identities.fromBrowserOrGateway(context.req.raw, ALL_APIS_SCOPE);
    return context.json({ items: await sync.listVaults(identity) });
  });
  app.get("/api/v1/vaults/:vaultId", async (context) => {
    const identity = await identities.fromBrowserOrGateway(context.req.raw, ALL_APIS_SCOPE);
    const vault = await sync.getVault(identity, sync.parseId(context.req.param("vaultId")));
    return vault ? context.json(vault) : context.json({ error: "vault_not_found" }, 404);
  });
  app.get("/api/v1/vaults/:vaultId/projects", async (context) => {
    const identity = await identities.fromBrowserOrGateway(context.req.raw, ALL_APIS_SCOPE);
    return context.json({ items: await sync.listProjects(identity, sync.parseId(context.req.param("vaultId"))) });
  });
  app.get("/api/v1/vaults/:vaultId/projects/:projectId", async (context) => {
    const identity = await identities.fromBrowserOrGateway(context.req.raw, ALL_APIS_SCOPE);
    const project = await sync.getProject(
      identity,
      sync.parseId(context.req.param("vaultId")),
      sync.parseId(context.req.param("projectId")),
    );
    return project ? context.json(project) : context.json({ error: "project_not_found" }, 404);
  });
  app.get("/api/v1/vaults/:vaultId/meetings", async (context) => {
    const identity = await identities.fromBrowserOrGateway(context.req.raw, ALL_APIS_SCOPE);
    const vaultId = sync.parseId(context.req.param("vaultId"));
    return context.json(await sync.listMeetings(
      identity,
      vaultId,
      context.req.query("q"),
      context.req.raw.signal,
      context.req.query("projectId") ? sync.parseId(context.req.query("projectId")!) : undefined,
      context.req.query("cursor"),
    ));
  });
  app.get("/api/v1/vaults/:vaultId/meetings/:meetingId", async (context) => {
    const identity = await identities.fromBrowserOrGateway(context.req.raw, ALL_APIS_SCOPE);
    const meeting = await sync.getMeeting(
      identity,
      sync.parseId(context.req.param("vaultId")),
      sync.parseId(context.req.param("meetingId")),
    );
    return meeting ? context.json(meeting) : context.json({ error: "meeting_not_found" }, 404);
  });
  app.get("/api/v1/vaults/:vaultId/meetings/:meetingId/transcript", async (context) => {
    const identity = await identities.fromBrowserOrGateway(context.req.raw, ALL_APIS_SCOPE);
    const vaultId = sync.parseId(context.req.param("vaultId"));
    const meetingId = sync.parseId(context.req.param("meetingId"));
    return context.json(await sync.listTranscript(identity, vaultId, meetingId, context.req.query("cursor")));
  });
  app.get("/api/v1/vaults/:vaultId/meetings/:meetingId/screenshots", async (context) => {
    const identity = await identities.fromBrowserOrGateway(context.req.raw, ALL_APIS_SCOPE);
    const vaultId = sync.parseId(context.req.param("vaultId"));
    const meetingId = sync.parseId(context.req.param("meetingId"));
    return context.json(await sync.listScreenshots(
      identity,
      vaultId,
      meetingId,
      context.req.query("q"),
      context.req.raw.signal,
      context.req.query("cursor"),
    ));
  });
  app.get("/api/v1/vaults/:vaultId/permissions", async (context) => {
    const identity = await identities.fromBrowser(context.req.raw);
    return context.json({ items: await sync.listPermissions(identity, sync.parseId(context.req.param("vaultId"))) });
  });
  app.put("/api/v1/vaults/:vaultId/permissions/organizations/:organizationId", async (context) => {
    if (!config.syncSharingEnabled) return context.json({ error: "not_found" }, 404);
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const identity = await identities.fromBrowser(context.req.raw);
    await sync.putMemberPermission(
      identity,
      sync.parseId(context.req.param("vaultId")),
      "organization",
      sync.parsePermissionPrincipal(context.req.param("organizationId")),
    );
    return context.body(null, 204);
  });
  app.delete("/api/v1/vaults/:vaultId/permissions/organizations/:organizationId", async (context) => {
    if (!config.syncSharingEnabled) return context.json({ error: "not_found" }, 404);
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const identity = await identities.fromBrowser(context.req.raw);
    await sync.deleteMemberPermission(
      identity,
      sync.parseId(context.req.param("vaultId")),
      "organization",
      sync.parsePermissionPrincipal(context.req.param("organizationId")),
    );
    return context.body(null, 204);
  });
  app.put("/api/v1/vaults/:vaultId/permissions/teams/:teamId", async (context) => {
    if (!config.syncSharingEnabled) return context.json({ error: "not_found" }, 404);
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const identity = await identities.fromBrowser(context.req.raw);
    await sync.putMemberPermission(
      identity,
      sync.parseId(context.req.param("vaultId")),
      "team",
      sync.parsePermissionPrincipal(context.req.param("teamId")),
    );
    return context.body(null, 204);
  });
  app.delete("/api/v1/vaults/:vaultId/permissions/teams/:teamId", async (context) => {
    if (!config.syncSharingEnabled) return context.json({ error: "not_found" }, 404);
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const identity = await identities.fromBrowser(context.req.raw);
    await sync.deleteMemberPermission(
      identity,
      sync.parseId(context.req.param("vaultId")),
      "team",
      sync.parsePermissionPrincipal(context.req.param("teamId")),
    );
    return context.body(null, 204);
  });

  app.get("/api/v1/organizations", async (context) => {
    if (!config.syncSharingEnabled || config.authProvider !== "header") {
      return context.json({ error: "not_found" }, 404);
    }
    const identity = await identities.fromBrowser(context.req.raw);
    const organization = await store.getExternalOrganization(identity.userId);
    return context.json(organization ? [organization] : []);
  });
  app.get("/api/v1/organizations/:organizationId", async (context) => {
    if (!config.syncSharingEnabled || config.authProvider !== "header" || context.req.param("organizationId") !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    const identity = await identities.fromBrowser(context.req.raw);
    const organization = await store.getExternalOrganization(identity.userId);
    return organization ? context.json(organization) : context.json({ error: "not_found" }, 404);
  });
  app.get("/api/v1/organizations/:organizationId/members", async (context) => {
    if (!config.syncSharingEnabled || config.authProvider !== "header" || context.req.param("organizationId") !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    const identity = await identities.fromBrowser(context.req.raw);
    const members = await store.listExternalOrganizationMembers(identity.userId);
    return members
      ? context.json({ members: members.map((member) => ({
          id: member.id,
          userId: member.userId,
          role: member.role,
          user: { name: member.name, email: member.email },
        })) })
      : context.json({ error: "not_found" }, 404);
  });
  app.get("/api/v1/organizations/:organizationId/teams", async (context) => {
    if (!config.syncSharingEnabled || config.authProvider !== "header" || context.req.param("organizationId") !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    const identity = await identities.fromBrowser(context.req.raw);
    const teams = await store.listExternalTeams(identity.userId);
    return teams ? context.json(teams) : context.json({ error: "not_found" }, 404);
  });
  app.post("/api/v1/organizations/:organizationId/teams", authBodyLimit, async (context) => {
    if (!config.syncSharingEnabled || config.authProvider !== "header" || context.req.param("organizationId") !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const input = teamInputSchema.safeParse(await context.req.json().catch(() => null));
    if (!input.success) return context.json({ error: "invalid_team" }, 400);
    const identity = await identities.fromBrowser(context.req.raw);
    const team = await store.createExternalTeam(identity.userId, input.data.name);
    return team ? context.json(team, 201) : context.json({ error: "not_found" }, 404);
  });
  app.patch("/api/v1/organizations/:organizationId/teams/:teamId", authBodyLimit, async (context) => {
    if (!config.syncSharingEnabled || config.authProvider !== "header" || context.req.param("organizationId") !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const input = teamInputSchema.safeParse(await context.req.json().catch(() => null));
    if (!input.success) return context.json({ error: "invalid_team" }, 400);
    const identity = await identities.fromBrowser(context.req.raw);
    const team = await store.updateExternalTeam(
      identity.userId,
      sync.parsePermissionPrincipal(context.req.param("teamId")),
      input.data.name,
    );
    return team ? context.json(team) : context.json({ error: "not_found" }, 404);
  });
  app.delete("/api/v1/organizations/:organizationId/teams/:teamId", async (context) => {
    if (!config.syncSharingEnabled || config.authProvider !== "header" || context.req.param("organizationId") !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const identity = await identities.fromBrowser(context.req.raw);
    return await store.deleteExternalTeam(
      identity.userId,
      sync.parsePermissionPrincipal(context.req.param("teamId")),
    ) ? context.body(null, 204) : context.json({ error: "not_found" }, 404);
  });
  app.get("/api/v1/organizations/:organizationId/teams/:teamId/members", async (context) => {
    if (!config.syncSharingEnabled || config.authProvider !== "header" || context.req.param("organizationId") !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    const identity = await identities.fromBrowser(context.req.raw);
    const members = await store.listExternalTeamMembers(
      identity.userId,
      sync.parsePermissionPrincipal(context.req.param("teamId")),
    );
    return members
      ? context.json(members.map((member) => ({ ...member, teamId: context.req.param("teamId") })))
      : context.json({ error: "not_found" }, 404);
  });
  app.put("/api/v1/organizations/:organizationId/teams/:teamId/members/:userId", async (context) => {
    if (!config.syncSharingEnabled || config.authProvider !== "header" || context.req.param("organizationId") !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const identity = await identities.fromBrowser(context.req.raw);
    return await store.addExternalTeamMember(
      identity.userId,
      sync.parsePermissionPrincipal(context.req.param("teamId")),
      sync.parsePermissionPrincipal(context.req.param("userId")),
    ) ? context.body(null, 204) : context.json({ error: "not_found" }, 404);
  });
  app.delete("/api/v1/organizations/:organizationId/teams/:teamId/members/:userId", async (context) => {
    if (!config.syncSharingEnabled || config.authProvider !== "header" || context.req.param("organizationId") !== EXTERNAL_ORGANIZATION_ID) {
      return context.json({ error: "not_found" }, 404);
    }
    if (!mutationOriginAllowed(context.req.raw, config.baseUrl)) return context.json({ error: "invalid_origin" }, 403);
    const identity = await identities.fromBrowser(context.req.raw);
    return await store.removeExternalTeamMember(
      identity.userId,
      sync.parsePermissionPrincipal(context.req.param("teamId")),
      sync.parsePermissionPrincipal(context.req.param("userId")),
    ) ? context.body(null, 204) : context.json({ error: "not_found" }, 404);
  });
  app.on(
    ["GET", "HEAD"],
    "/api/v1/vaults/:vaultId/meetings/:meetingId/screenshots/:screenshotId/content",
    async (context) => {
      const identity = await identities.fromBrowserOrGateway(context.req.raw, ALL_APIS_SCOPE);
      return sync.readScreenshot(
        identity,
        sync.parseId(context.req.param("vaultId")),
        sync.parseId(context.req.param("meetingId")),
        sync.parseId(context.req.param("screenshotId")),
        context.req.method as "GET" | "HEAD",
        context.req.raw,
      );
    },
  );
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
  app.all("/mcp", (context) => context.json({ error: "method_not_allowed" }, 405));

  app.use("/api/v1/*", async (context, next) => {
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
  app.post("/api/v1/responses", async (context) => gateway.responses(context.req.raw));

  for (const extension of extensions) extension.registerRoutes?.(app, services);

  app.all("/api/*", (context) => context.json({ error: "not_found" }, 404));

  app.onError((error, context) => {
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
    if (error instanceof ArtifactRequestError) {
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

  async function getReadableArtifact(request: Request, value: string) {
    const artifact = await artifacts.get(artifacts.parseId(value));
    if (!artifact) return null;
    if (artifact.visibility === "public" && !request.headers.has("authorization")) return artifact;
    const identity = await identities.fromBrowserOrGateway(request, ALL_APIS_SCOPE);
    if (artifact.visibility !== "public" && identity.workspaceId !== artifact.ownerWorkspaceId) {
      throw new ArtifactRequestError(404, "artifact_not_found");
    }
    return artifact;
  }

  return app;
}

function requestRoute(path: string): string {
  if (path === "/mcp") return path;
  if (path === "/api/v1/artifacts") return path;
  if (path.startsWith("/api/v1/artifacts/")) return "/api/v1/artifacts/:artifactId";
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
