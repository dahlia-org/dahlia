import { resolveAuthSecret } from "./secret";
import { readDatabricksAuthSecret } from "../databricks/secret";
import { headerEmail } from "./header";
import { uuidV7 } from "../id";
import { oauthProvider } from "@better-auth/oauth-provider";
import { oauthProviderResourceClient } from "@better-auth/oauth-provider/resource-client";
import { betterAuth, type BetterAuthOptions } from "better-auth";
import { APIError, createAuthEndpoint, formCsrfMiddleware, getSessionFromCtx } from "better-auth/api";
import { setSessionCookie } from "better-auth/cookies";
import { admin, jwt, organization } from "better-auth/plugins";
import { authorizationConflict } from "./authorization";

import { gatewayResource, mcpResource, type AppConfig } from "../config";
import type { AuthStore } from "./store";
import { personalWorkspaceId } from "./workspace";
import {
  AUTHORIZATION_SERVER_SCOPES,
  MCP_SCOPE,
  MCP_OAUTH_SCOPES,
  OAUTH_SCOPES,
} from "./scopes";

export function denyOAuthManagement(): false {
  return false;
}

export type DahliaAuthPlugin = NonNullable<BetterAuthOptions["plugins"]>[number];

export interface DahliaAuthExtension {
  plugins: readonly DahliaAuthPlugin[];
}

function buildDahliaAuth(
  config: AppConfig,
  authStore: AuthStore,
  extensions: readonly DahliaAuthExtension[] = [],
) {
  if (!config.betterAuthSecret || (config.authProvider === "accounts" && (!config.googleClientId || !config.googleClientSecret))) {
    throw new Error("Better Auth configuration is incomplete");
  }
  const resource = gatewayResource(config);
  const mcp = mcpResource(config);
  const organizationPlugin = organization({
        schema: { organization: { additionalFields: { kind: { type: "string", required: true, defaultValue: "team", input: false }, domain: { type: "string", required: false, unique: true, input: false } } } },
        organizationHooks: {
          beforeCreateOrganization: ({ organization }) => {
            if (organization.slug?.toLowerCase().startsWith("personal-")) authorizationConflict("reserved_organization_slug");
            return Promise.resolve();
          },
          beforeCreateTeam: async ({ organization }) => { await authStore.organizations.assertTeamOrganization(organization.id); },
          afterCreateTeam: async ({ team, user }) => { if (user) await authStore.organizations.addTeamCreator(team.id, user.id); },
          beforeCreateInvitation: async ({ organization }) => { await authStore.organizations.assertTeamOrganization(organization.id); },
        },
        cancelPendingInvitationsOnReInvite: true,
        requireEmailVerificationOnInvitation: true,
        sendInvitationEmail: async () => {},
        teams: {
          enabled: true,
          defaultTeam: { enabled: false },
          allowRemovingAllTeams: true,
        },
      });
  return betterAuth({
    advanced: { disableOriginCheck: false, disableCSRFCheck: false, database: { joins: false, generateId: () => uuidV7() } },
    appName: "Dahlia Server",
    user: { additionalFields: { registrationState: { type: "string", required: true, defaultValue: "personal", input: false, returned: false } } },
    basePath: "/api/auth",
    baseURL: config.baseUrl,
    database: authStore.database,
    secret: config.betterAuthSecret,
    socialProviders: config.authProvider === "accounts" ? {
      google: {
        clientId: config.googleClientId!,
        clientSecret: config.googleClientSecret!,
      },
    } : {},
    databaseHooks: { user: {
      create: {
        before: (user) => Promise.resolve({ data: { ...user, registrationState: config.authProvider === "header" ? "domain" : "personal" } }),
        after: async (user) => { await authStore.organizations.initializeUser(user.id, config.authProvider === "header" ? config.authProviderId ?? "external" : undefined); },
      },
      update: { before: (user) => {
        if (config.authProvider === "header" && user.email !== undefined) throw new APIError("FORBIDDEN", { message: "header_email_change_disabled" });
        return Promise.resolve();
      } },
      delete: { before: () => { throw new APIError("FORBIDDEN", { message: "account_delete_disabled" }); } } } },
    trustedOrigins: [config.baseUrl, ...config.oauthRedirectUris],
    plugins: [
      admin(),
      ...(config.authProvider === "accounts" ? [jwt({
        jwks: {
          keyPairConfig: { alg: "EdDSA", crv: "Ed25519" },
        },
        jwt: { issuer: config.baseUrl },
      }),
      oauthProvider({
        accessTokenExpiresIn: 15 * 60,
        allowDynamicClientRegistration: false,
        allowUnauthenticatedClientRegistration: false,
        cachedTrustedClients: new Set(["databricks-cli"]),
        clientRegistrationDefaultResources: [mcp],
        clientRegistrationDefaultScopes: [MCP_SCOPE],
        clientPrivileges: denyOAuthManagement,
        consentPage: "/oauth/consent",
        customAccessTokenClaims: ({ user, referenceId }) => {
          if (!user) return {};
          return {
            workspace_id: personalWorkspaceId(user.id),
            impersonated: referenceId?.startsWith("impersonated:") ?? false,
          };
        },
        enforcePerClientResources: true,
        loginPage: "/sign-in",
        postLogin: {
          page: "/oauth/consent",
          shouldRedirect: () => false,
          consentReferenceId: ({ session }) => session.impersonatedBy
            ? `impersonated:${session.id}`
            : undefined,
        },
        refreshTokenExpiresIn: 30 * 24 * 60 * 60,
        refreshTokenReuseInterval: 0,
        resources: [
          {
            identifier: resource,
            name: "Dahlia AI Gateway",
            accessTokenTtl: 15 * 60,
            refreshTokenTtl: 30 * 24 * 60 * 60,
            allowedScopes: [...OAUTH_SCOPES],
          },
          {
            identifier: mcp,
            name: "Dahlia MCP",
            accessTokenTtl: 15 * 60,
            refreshTokenTtl: 30 * 24 * 60 * 60,
            allowedScopes: [...MCP_OAUTH_SCOPES],
            dpopBoundAccessTokensRequired: true,
          },
        ],
        resourcePrivileges: denyOAuthManagement,
        scopes: AUTHORIZATION_SERVER_SCOPES,
        silenceWarnings: {
          oauthAuthServerConfig: true,
          openidConfig: true,
        },
      })] : []),
      organizationPlugin,
      {
        id: "dahlia-header-session",
        endpoints: {
          signInHeader: createAuthEndpoint("/header/sign-in", { method: "POST", use: [formCsrfMiddleware] }, async (ctx) => {
            if (config.authProvider !== "header") throw new APIError("NOT_FOUND");
            const email = headerEmail(ctx.headers?.get(config.authHeader));
            if (!email) throw new APIError("UNAUTHORIZED", { message: "proxy_header_required" });
            const externalId = email;
            const userId = await authStore.resolveHeaderUser({ userId: externalId, email,
              name: ctx.headers?.get("X-Forwarded-Preferred-Username")?.trim(), source: "header", workspaceId: personalWorkspaceId(externalId) });
            if (!userId) throw new APIError("UNAUTHORIZED");
            await authStore.organizations.initializeUser(userId);
            const current = await getSessionFromCtx(ctx);
            if (current && current.user.id !== userId) throw new APIError("FORBIDDEN", { message: "proxy_session_mismatch" });
            if (current) return ctx.json(current);
            const user = await ctx.context.internalAdapter.findUserById(userId);
            if (!user) throw new APIError("UNAUTHORIZED");
            const session = await ctx.context.internalAdapter.createSession(userId);
            if (!session) throw new APIError("INTERNAL_SERVER_ERROR");
            await setSessionCookie(ctx, { session, user });
            return ctx.json({ session, user });
          }),
        },
      },
      ...extensions.flatMap((extension) => extension.plugins),
    ],
  });
}

export type DahliaAuth = ReturnType<typeof buildDahliaAuth>;

class AuthResponseRollback extends Error {
  constructor(readonly response: Response) { super("Authentication operation rejected"); }
}
const authorizationMutations = Object.entries({ ...organization({ teams: { enabled: true } }).endpoints, ...admin().endpoints })
  .filter(([, endpoint]) => endpoint.options.method === "POST");
const authorizationMutationNames = new Set(authorizationMutations.map(([name]) => name));

export function createDahliaAuth(config: AppConfig, authStore: AuthStore, extensions: readonly DahliaAuthExtension[] = []): DahliaAuth {
  const auth = buildDahliaAuth(config, authStore, extensions);
  async function atomic<T>(run: (scoped: DahliaAuth) => Promise<T>): Promise<T> {
    return authStore.organizations.transaction(async (database, organizations) => {
      const scoped = buildDahliaAuth(config, { ...authStore, database, organizations }, extensions);
      const result = await run(scoped);
      if (result instanceof Response && !result.ok) throw new AuthResponseRollback(result);
      return result;
    });
  }
  function response(error: unknown): Response {
    if (error instanceof AuthResponseRollback) return error.response;
    if (error instanceof APIError) return Response.json(error.body, { status: error.statusCode });
    throw error;
  }
  return { ...auth,
    handler: async (request) => {
      const path = new URL(request.url).pathname;
      if (request.method !== "POST" || !["/api/auth/organization/", "/api/auth/admin/"].some((prefix) => path.startsWith(prefix))) return auth.handler(request);
      try { return await atomic((scoped) => scoped.handler(request)); } catch (error) { return response(error); }
    },
    api: new Proxy(auth.api, {
      get(target, property, receiver) {
        if (typeof property !== "string" || !authorizationMutationNames.has(property)) return Reflect.get(target, property, receiver) as unknown;
        const endpoint = Reflect.get(target, property, receiver) as { path: string; options: unknown };
        return Object.assign(async (...args: unknown[]) => {
          try {
            return await atomic((scoped) => (Reflect.get(scoped.api, property) as (...args: unknown[]) => Promise<unknown>)(...args));
          } catch (error) {
            if ((args[0] as { asResponse?: boolean } | undefined)?.asResponse) return response(error);
            if (error instanceof AuthResponseRollback) return error.response;
            throw error;
          }
        }, { path: endpoint.path, options: endpoint.options });
      },
    }),
  };
}

export async function initializeDahliaAuth(
  config: AppConfig,
  authStore: AuthStore,
  extensions: readonly DahliaAuthExtension[] = [],
): Promise<DahliaAuth> {
  const configuredSecret = config.betterAuthSecret ?? (config.databricksAuthSecret
    ? await readDatabricksAuthSecret(config.databricksWorkspace!, config.databricksAuthSecret)
    : undefined);
  const auth = createDahliaAuth({ ...config, betterAuthSecret: await resolveAuthSecret(configuredSecret) }, authStore, extensions);
  await auth.$context;
  if (config.authProvider === "accounts") await authStore.seedDahliaClient(config);
  return auth;
}

export type AccessTokenVerifier = (
  request: Request,
  options: {
    requiredScopes: string[];
    verifyOptions: { audience: string; issuer: string };
  },
) => Promise<Record<string, unknown>>;

export type ProtectedResourceMetadata = (options: {
  resource: string;
  authorization_servers: string[];
  scopes_supported: string[];
}) => Promise<Record<string, unknown>>;

export function createAccessTokenVerifier(auth: DahliaAuth): AccessTokenVerifier {
  return oauthProviderResourceClient(auth).getActions().verifyAccessTokenRequest;
}

export function createProtectedResourceMetadata(auth: DahliaAuth): ProtectedResourceMetadata {
  return oauthProviderResourceClient(auth).getActions()
    .getProtectedResourceMetadata as unknown as ProtectedResourceMetadata;
}
