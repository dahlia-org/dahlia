import { oauthProvider } from "@better-auth/oauth-provider";
import { betterAuth } from "better-auth";
import { jwt } from "better-auth/plugins";

import { OAUTH_SCOPES } from "../src/auth/scopes";

export const auth = betterAuth({
  advanced: { database: { joins: false } },
  baseURL: "https://dahlia.invalid",
  plugins: [
    jwt(),
    oauthProvider({
      consentPage: "/oauth/consent",
      loginPage: "/sign-in",
      resources: ["https://dahlia.invalid/api/v1"],
      scopes: OAUTH_SCOPES,
    }),
  ],
});
