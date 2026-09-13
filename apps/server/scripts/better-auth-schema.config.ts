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
  // The generator recognizes UUID column types only with this literal; runtime supplies UUIDv7.
  advanced: { database: { joins: false, generateId: "uuid" } },
  user: { additionalFields: { registrationState: { type: "string", required: true, defaultValue: "personal", input: false, returned: false } } },
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
      schema: { organization: { additionalFields: { kind: { type: "string", required: true, defaultValue: "team", input: false }, domain: { type: "string", required: false, unique: true, input: false } } } },
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
