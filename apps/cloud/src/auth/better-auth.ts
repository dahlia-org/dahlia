import { oauthProvider } from "@better-auth/oauth-provider";
import { oauthProviderResourceClient } from "@better-auth/oauth-provider/resource-client";
import { stripe } from "@better-auth/stripe";
import { betterAuth } from "better-auth";
import { jwt } from "better-auth/plugins";
import Stripe from "stripe";

import { gatewayResource, type AppConfig } from "../config";
import { synchronizeStripeSubscription } from "../billing/service";
import type { AuthStore } from "./store";
import { personalWorkspaceId } from "./workspace";
import { OAUTH_SCOPES } from "./scopes";

export function denyOAuthManagement(): false {
  return false;
}

export function authorizePersonalBillingReference(data: {
  user: { id: string };
  referenceId: string;
}): Promise<boolean> {
  return Promise.resolve(data.referenceId === data.user.id);
}

export function createDahliaAuth(
  config: AppConfig,
  authStore: AuthStore,
  providedStripeClient?: Stripe,
) {
  if (!config.betterAuthSecret || !config.googleClientId || !config.googleClientSecret) {
    throw new Error("Better Auth configuration is incomplete");
  }
  const resource = gatewayResource(config);
  const stripeConfig = config.stripe;
  const stripeClient = stripeConfig
    ? providedStripeClient ?? new Stripe(stripeConfig.secretKey, { apiVersion: "2026-07-29.dahlia" })
    : undefined;
  const billingPlugin = stripeConfig && stripeClient
    ? stripe({
        stripeClient,
        stripeWebhookSecret: stripeConfig.webhookSecret,
        createCustomerOnSignUp: true,
        onEvent: (event) => synchronizeStripeSubscription(
          event,
          authStore,
          stripeConfig.proMonthlyPriceId,
        ),
        subscription: {
          enabled: true,
          plans: [{ name: "pro", priceId: stripeConfig.proMonthlyPriceId }],
          authorizeReference: authorizePersonalBillingReference,
        },
      })
    : undefined;

  return betterAuth({
    appName: "Dahlia Cloud",
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
        cachedTrustedClients: new Set(["dahlia-macos"]),
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
        ],
        resourcePrivileges: denyOAuthManagement,
        scopes: OAUTH_SCOPES,
        silenceWarnings: {
          oauthAuthServerConfig: true,
          openidConfig: true,
        },
      }),
      ...(billingPlugin ? [billingPlugin] : []),
    ],
  });
}

export type DahliaAuth = ReturnType<typeof createDahliaAuth>;

export async function initializeDahliaAuth(
  config: AppConfig,
  authStore: AuthStore,
  stripeClient?: Stripe,
): Promise<DahliaAuth> {
  const auth = createDahliaAuth(config, authStore, stripeClient);
  await auth.$context;
  await authStore.seedDahliaClient(config);
  return auth;
}

export function createAccessTokenVerifier(auth: DahliaAuth) {
  return oauthProviderResourceClient(auth).getActions().verifyAccessTokenRequest;
}

export function createProtectedResourceMetadata(auth: DahliaAuth) {
  return oauthProviderResourceClient(auth).getActions().getProtectedResourceMetadata;
}
