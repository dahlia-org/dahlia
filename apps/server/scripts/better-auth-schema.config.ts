import { oauthProvider } from "@better-auth/oauth-provider";
import { drizzleAdapter } from "@better-auth/drizzle-adapter/relations-v2";
import { betterAuth } from "better-auth";
import { admin, jwt, organization } from "better-auth/plugins";

import { OAUTH_SCOPES } from "../src/auth/scopes";

const provider = process.env.DAHLIA_AUTH_SCHEMA_PROVIDER;
if (provider !== "pg" && provider !== "sqlite") {
  throw new Error("DAHLIA_AUTH_SCHEMA_PROVIDER must be pg or sqlite");
}

export const auth = betterAuth({
  advanced: { database: { joins: false } },
  baseURL: "https://dahlia.invalid",
  // Resource seeding is runtime-only, so schema generation needs no database connection.
  database: drizzleAdapter({}, {
    provider,
    ...(provider === "pg" ? { schemaName: "auth" } : {}),
  }),
  plugins: [
    admin(),
    jwt(),
    oauthProvider({
      consentPage: "/oauth/consent",
      loginPage: "/sign-in",
      scopes: OAUTH_SCOPES,
    }),
    organization({
      cancelPendingInvitationsOnReInvite: true,
      requireEmailVerificationOnInvitation: true,
      sendInvitationEmail: async () => {},
      teams: {
        enabled: true,
        defaultTeam: { enabled: true },
      },
    }),
  ],
});
