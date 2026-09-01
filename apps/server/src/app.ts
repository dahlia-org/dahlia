import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { secureHeaders } from "hono/secure-headers";
import {
  bearerAuthChallengeResponse,
  OAuthError,
  OAuthErrorCode,
  type AuthInfo,
} from "@modelcontextprotocol/server";
import { z } from "zod";

import { AuthenticationError, IdentityService, type Identity } from "./auth/identity";
import { createProtectedResourceMetadata, type DahliaAuth } from "./auth/better-auth";
import {
  ARTIFACT_READ_SCOPE,
  ARTIFACT_WRITE_SCOPE,
  GATEWAY_SCOPES,
  MODEL_READ_SCOPE,
  MODEL_REQUEST_SCOPE,
  type GatewayScope,
} from "./auth/scopes";
import type { AuthStore } from "./auth/store";
import { mcpResource, type AppConfig } from "./config";
import { ArtifactRequestError, ArtifactService, artifactResponse } from "./artifacts/service";
import type { ObjectStorage } from "./artifacts/storage";
import { createArtifactMcpHandler, MCP_MAX_REQUEST_BYTES } from "./mcp";
import { MODEL_ALIAS_PATTERN, UPSTREAM_MODEL_MAX_LENGTH } from "./ai-gateway/model-alias";
import { gatewayError, GatewayRequestError, GatewayService } from "./ai-gateway/service";

export const AUTH_MAX_REQUEST_BYTES = 64 * 1024;
const ARTIFACT_PATCH_MAX_REQUEST_BYTES = 1024;

export function requiredGatewayScope(path: string): GatewayScope {
  return path === "/api/v1/models" ? MODEL_READ_SCOPE : MODEL_REQUEST_SCOPE;
}

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
}

export async function authenticateMcpRequest(
  request: Request,
  verifyAccessToken: (request: Request) => Promise<AuthInfo>,
  resourceMetadataUrl: string,
): Promise<AuthInfo | Response> {
  const options = {
    requiredScopes: [ARTIFACT_WRITE_SCOPE],
    resourceMetadataUrl,
  };
  let authInfo: AuthInfo;
  try {
    authInfo = await verifyAccessToken(request);
  } catch {
    return bearerAuthChallengeResponse(
      new OAuthError(OAuthErrorCode.InvalidToken, "Invalid or expired Dahlia access token"),
      options,
    );
  }
  if (!authInfo.scopes.includes(ARTIFACT_WRITE_SCOPE)) {
    return bearerAuthChallengeResponse(
      new OAuthError(OAuthErrorCode.InsufficientScope, "Insufficient scope"),
      options,
    );
  }
  return authInfo;
}

const aliasSchema = z.string().regex(MODEL_ALIAS_PATTERN);
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
  const identities = new IdentityService(config, auth);
  const gateway = new GatewayService(config, store, dependencies.fetch);
  const artifacts = new ArtifactService(config, store, dependencies.artifactStorage);
  const mcp = createArtifactMcpHandler(config, artifacts);
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
        scopes_supported: [ARTIFACT_WRITE_SCOPE],
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
      admin: await isAdministrator(config, store, identity),
      databricksModels: config.provider?.backend === "databricks",
      sessions: auth !== undefined,
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
    if (!await isAdministrator(config, store, identity)) {
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
    const database = (await store.listPlatformAdmins())
      .filter((admin) => admin.email !== config.adminEmail)
      .map((admin) => ({ ...admin, role: "admin", source: "database", removable: true }));
    const environment = config.adminEmail
      ? [{ email: config.adminEmail, role: "admin", source: "environment", removable: false }]
      : [];
    return context.json([...environment, ...database]);
  });
  app.post("/api/admin/members", async (context) => {
    const parsed = memberSchema.safeParse(await context.req.json().catch(() => null));
    if (!parsed.success) return context.json({ error: "invalid_email" }, 400);
    if (parsed.data.email === config.adminEmail) return context.json({ error: "administrator_exists" }, 409);
    const created = await store.addPlatformAdmin(parsed.data.email);
    return created
      ? context.json({ email: parsed.data.email, role: "admin", source: "database", removable: true }, 201)
      : context.json({ error: "administrator_exists" }, 409);
  });
  app.delete("/api/admin/members/:email", async (context) => {
    const email = z.email().safeParse(context.req.param("email").trim().toLowerCase());
    if (!email.success) return context.json({ error: "invalid_email" }, 400);
    if (email.data === config.adminEmail) return context.json({ error: "environment_administrator_immutable" }, 409);
    return await store.deletePlatformAdmin(email.data)
      ? context.body(null, 204)
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

  app.post("/api/v1/artifacts", async (context) => {
    const identity = await identities.fromGateway(context.req.raw, ARTIFACT_WRITE_SCOPE);
    const artifact = await artifacts.create(identity, context.req.raw);
    return context.json(artifactResponse(artifact), 201, {
      Location: `${config.baseUrl}/api/v1/artifacts/${artifact.id}`,
    });
  });
  app.on(["GET", "HEAD"], "/api/v1/artifacts/:artifactId", async (context) => {
    const id = artifacts.parseId(context.req.param("artifactId"));
    const artifact = await artifacts.get(id);
    if (!artifact) return context.json({ error: "artifact_not_found" }, 404);
    if (artifact.visibility !== "public") {
      const identity = await identities.fromGateway(context.req.raw, ARTIFACT_READ_SCOPE);
      if (identity.workspaceId !== artifact.ownerWorkspaceId) {
        return context.json({ error: "artifact_not_found" }, 404);
      }
    }
    return artifacts.read(artifact, context.req.method as "GET" | "HEAD", context.req.raw);
  });
  app.put("/api/v1/artifacts/:artifactId", async (context) => {
    const id = artifacts.parseId(context.req.param("artifactId"));
    const identity = await identities.fromGateway(context.req.raw, ARTIFACT_WRITE_SCOPE);
    return context.json(artifactResponse(await artifacts.put(id, identity, context.req.raw)));
  });
  app.patch("/api/v1/artifacts/:artifactId", artifactPatchBodyLimit, async (context) => {
    const id = artifacts.parseId(context.req.param("artifactId"));
    const identity = await identities.fromGateway(context.req.raw, ARTIFACT_WRITE_SCOPE);
    const body = await context.req.json<unknown>().catch((): unknown => undefined);
    return context.json(artifactResponse(await artifacts.setVisibility(id, identity, body, context.req.raw.signal)));
  });
  app.delete("/api/v1/artifacts/:artifactId", async (context) => {
    const id = artifacts.parseId(context.req.param("artifactId"));
    const identity = await identities.fromGateway(context.req.raw, ARTIFACT_WRITE_SCOPE);
    await artifacts.delete(id, identity, context.req.raw.signal);
    return context.body(null, 204);
  });

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
      const identity = identities.fromMcpHeader(context.req.raw);
      authInfo = {
        token: "",
        clientId: "trusted-proxy",
        scopes: [ARTIFACT_WRITE_SCOPE],
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
      requiredGatewayScope(context.req.path),
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
        ? `Bearer resource_metadata="${config.baseUrl}/.well-known/oauth-protected-resource"`
        : "Bearer";
      return context.json({ error: "unauthorized", message: error.message }, 401, { "WWW-Authenticate": challenge });
    }
    if (error instanceof GatewayRequestError) return gatewayError(error);
    if (error instanceof ArtifactRequestError) {
      return Response.json({ error: error.code }, { status: error.status });
    }
    console.error(JSON.stringify({ level: "error", event: "request_failed", route: requestRoute(context.req.path) }));
    return context.json({ error: "internal_server_error" }, 500);
  });

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

async function isAdministrator(config: AppConfig, store: AuthStore, identity: Identity): Promise<boolean> {
  const email = identity.email?.trim().toLowerCase();
  if (!email) return false;
  if (email === config.adminEmail) return true;
  try {
    return await store.isPlatformAdmin(email);
  } catch {
    return false;
  }
}
