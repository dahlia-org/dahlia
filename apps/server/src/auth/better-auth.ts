import { oauthProvider } from "@better-auth/oauth-provider";
import { oauthProviderResourceClient } from "@better-auth/oauth-provider/resource-client";
import { betterAuth, type BetterAuthOptions } from "better-auth";
import { admin, jwt, organization } from "better-auth/plugins";

import { gatewayResource, mcpResource, type AppConfig } from "../config";
import type { AuthStore } from "./store";
import { personalWorkspaceId } from "./workspace";
import { ARTIFACT_WRITE_SCOPE, MCP_OAUTH_SCOPES, OAUTH_SCOPES } from "./scopes";

export function denyOAuthManagement(): false {
  return false;
}

export type DahliaAuthPlugin = NonNullable<BetterAuthOptions["plugins"]>[number];

export interface DahliaAuthExtension {
  plugins: readonly DahliaAuthPlugin[];
}

export function createDahliaAuth(
  config: AppConfig,
  authStore: AuthStore,
  extensions: readonly DahliaAuthExtension[] = [],
) {
  if (!config.betterAuthSecret || !config.googleClientId || !config.googleClientSecret) {
    throw new Error("Better Auth configuration is incomplete");
  }
  const resource = gatewayResource(config);
  const mcp = mcpResource(config);
  return betterAuth({
    advanced: { database: { joins: false } },
    appName: "Dahlia Server",
    basePath: "/api/auth",
    baseURL: config.baseUrl,
    database: authStore.database,
    secret: config.betterAuthSecret,
    socialProviders: {
      google: {
        clientId: config.googleClientId,
        clientSecret: config.googleClientSecret,
      },
    },
    trustedOrigins: [config.baseUrl, ...config.oauthRedirectUris],
    plugins: [
      admin(),
      jwt({
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
        clientRegistrationDefaultScopes: [ARTIFACT_WRITE_SCOPE],
        clientPrivileges: denyOAuthManagement,
        consentPage: "/oauth/consent",
        customAccessTokenClaims: ({ user }) => {
          if (!user) return {};
          return { workspace_id: personalWorkspaceId(user.id) };
        },
        enforcePerClientResources: true,
        loginPage: "/sign-in",
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
        scopes: OAUTH_SCOPES,
        silenceWarnings: {
          oauthAuthServerConfig: true,
          openidConfig: true,
        },
      }),
      ...(config.syncSharingEnabled ? [organization({
        cancelPendingInvitationsOnReInvite: true,
        requireEmailVerificationOnInvitation: true,
        sendInvitationEmail: async () => {},
        teams: {
          enabled: true,
          defaultTeam: { enabled: true },
        },
        organizationHooks: {
          beforeDeleteOrganization: async ({ organization: deleted }) => {
            await authStore.deleteVaultPermissionsForOrganization(deleted.id).catch(() => undefined);
          },
          afterDeleteTeam: async ({ team: deleted }) => {
            await authStore.deleteVaultPermissionsForPrincipal("team", deleted.id).catch(() => undefined);
          },
        },
      })] : []),
      ...extensions.flatMap((extension) => extension.plugins),
    ],
  });
}

export type DahliaAuth = ReturnType<typeof createDahliaAuth>;

export async function initializeDahliaAuth(
  config: AppConfig,
  authStore: AuthStore,
  extensions: readonly DahliaAuthExtension[] = [],
): Promise<DahliaAuth> {
  const auth = createDahliaAuth(config, authStore, extensions);
  await auth.$context;
  await authStore.seedDahliaClient(config);
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
