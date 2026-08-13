import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { secureHeaders } from "hono/secure-headers";
import { z } from "zod";

import { AuthenticationError, IdentityService, type Identity } from "./auth/identity";
import { createProtectedResourceMetadata, type DahliaAuth } from "./auth/better-auth";
import {
  GATEWAY_SCOPES,
  MODEL_READ_SCOPE,
  MODEL_REQUEST_SCOPE,
  type GatewayScope,
} from "./auth/scopes";
import type { AuthStore } from "./auth/store";
import type { AppConfig } from "./config";
import { gatewayError, GatewayRequestError, GatewayService } from "./gateway/service";

export const AUTH_MAX_REQUEST_BYTES = 64 * 1024;

export function requiredGatewayScope(path: string): GatewayScope {
  return path === "/api/v1/models" ? MODEL_READ_SCOPE : MODEL_REQUEST_SCOPE;
}

export const authBodyLimit = bodyLimit({
  maxSize: AUTH_MAX_REQUEST_BYTES,
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
  request: Request;
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
  remoteAddress?: (context: unknown) => string | undefined;
  auth?: DahliaAuth;
  authStore?: AuthStore;
  extensions?: readonly DahliaServerExtension[];
}

const aliasSchema = z.string().regex(/^[a-z0-9][a-z0-9._-]{0,63}$/);
const modelFieldsSchema = z.object({
  upstreamModel: z.string().trim().min(1).max(255),
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
  const remoteAddress = (context: unknown) => dependencies.remoteAddress?.(context);
  const services: ServerExtensionServices = {
    auth,
    browserIdentity: (request, context) => identities.fromBrowser(request, remoteAddress(context)),
  };

  app.use("*", secureHeaders());
  app.use("/api/*", async (context, next) => {
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
  app.all("/.well-known/*", (context) => context.json({ error: "not_found" }, 404));

  app.use("/api/auth/*", authBodyLimit);
  for (const extension of extensions) extension.registerAuthRoutes?.(app, services);
  app.on(["GET", "POST"], "/api/auth/*", (context) => {
    if (!auth) return context.json({ error: "not_found" }, 404);
    return auth.handler(context.req.raw);
  });

  app.use("/api/session", async (context, next) => {
    context.set("identity", await identities.fromBrowser(context.req.raw, remoteAddress(context)));
    await next();
  });
  app.get("/api/session", async (context) => {
    const identity = context.get("identity");
    const capabilities: Record<string, boolean> = {
      admin: await isAdministrator(config, store, identity),
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
    const identity = await identities.fromBrowser(context.req.raw, remoteAddress(context));
    if (!await isAdministrator(config, store, identity)) {
      return context.json({ error: "forbidden" }, 403);
    }
    context.set("identity", identity);
    await next();
  });
  app.get("/api/admin/models", async (context) => context.json(await store.listModelAliases()));
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
    context.set("identity", await identities.fromBrowser(context.req.raw, remoteAddress(context)));
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

  app.use("/api/v1/*", async (context, next) => {
    context.set("identity", await identities.fromGateway(
      context.req.raw,
      requiredGatewayScope(context.req.path),
      remoteAddress(context),
    ));
    for (const extension of extensions) {
      const response = await extension.beforeGateway?.({
        identity: context.get("identity"),
        request: context.req.raw,
      });
      if (response) return response;
    }
    await next();
  });
  app.get("/api/v1/models", async (context) => context.json(await gateway.models()));
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
    console.error(JSON.stringify({ level: "error", event: "request_failed", path: context.req.path }));
    return context.json({ error: "internal_server_error" }, 500);
  });

  return app;
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
