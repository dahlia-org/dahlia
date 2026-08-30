import { oauthProvider } from "@better-auth/oauth-provider";
import { drizzleAdapter } from "@better-auth/drizzle-adapter/relations-v2";
import { betterAuth } from "better-auth";
import { jwt } from "better-auth/plugins";

import { OAUTH_SCOPES } from "../src/auth/scopes";

const provider = process.env.DAHLIA_AUTH_SCHEMA_PROVIDER;
if (provider !== "pg" && provider !== "sqlite") {
  throw new Error("DAHLIA_AUTH_SCHEMA_PROVIDER must be pg or sqlite");
}

export const auth = betterAuth({
  advanced: { database: { joins: false } },
  baseURL: "https://dahlia.invalid",
  // Resource seeding is runtime-only, so schema generation needs no database connection.
  database: drizzleAdapter({}, { provider }),
  plugins: [
    jwt(),
    oauthProvider({
      consentPage: "/oauth/consent",
      loginPage: "/sign-in",
      scopes: OAUTH_SCOPES,
    }),
  ],
});
