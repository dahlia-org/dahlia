import { describe, expect, it } from "vitest";

import { IdentityService } from "../src/auth/identity";
import type { AppConfig } from "../src/config";

describe("proxy identity boundary", () => {
  it("uses the configured email header as the full identity", async () => {
    const config: AppConfig = {
      authProvider: "header",
      authHeader: "Cf-Access-Authenticated-User-Email",
      databaseType: "sqlite",
      baseUrl: "https://dahlia.example",
      oauthRedirectUris: [],
      maxRequestBytes: 1024,
    };
    const identity = await new IdentityService(config).fromBrowser(new Request("https://dahlia.example/api/session", {
      headers: { "Cf-Access-Authenticated-User-Email": " User@Example.com " },
    }));

    expect(identity).toEqual({
      userId: "user@example.com",
      email: "user@example.com",
      workspaceId: "personal:user@example.com",
      source: "header",
    });
  });

  it("rejects a missing configured identity header", async () => {
    const config: AppConfig = {
      authProvider: "header",
      authHeader: "X-Forwarded-Email",
      databaseType: "sqlite",
      baseUrl: "https://dahlia.example",
      oauthRedirectUris: [],
      maxRequestBytes: 1024,
    };

    await expect(new IdentityService(config).fromBrowser(new Request("https://dahlia.example/api/session")))
      .rejects.toThrow("X-Forwarded-Email is missing");
  });
});
