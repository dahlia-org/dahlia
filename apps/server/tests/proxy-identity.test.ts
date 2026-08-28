import { describe, expect, it } from "vitest";

import { IdentityService } from "../src/auth/identity";
import type { AppConfig } from "../src/config";

function headerConfig(authHeader: string): AppConfig {
  return {
    authProvider: "header",
    authHeader,
    databaseType: "sqlite",
    baseUrl: "https://dahlia.example",
    oauthRedirectUris: [],
    maxRequestBytes: 1024,
  };
}

describe("proxy identity boundary", () => {
  it("uses forwarded user ID and preferred username headers", async () => {
    const config = headerConfig("X-Forwarded-Email");
    const identity = await new IdentityService(config).fromBrowser(new Request("https://dahlia.example/api/session", {
      headers: {
        "X-Forwarded-Email": " User@Example.com ",
        "X-Forwarded-Preferred-Username": " Dahlia User ",
        "X-Forwarded-User": "123456789",
      },
    }));

    expect(identity).toEqual({
      userId: "123456789",
      email: "user@example.com",
      name: "Dahlia User",
      workspaceId: "personal:123456789",
      source: "header",
    });
  });

  it("uses the configured email header as the full identity", async () => {
    const config = headerConfig("Cf-Access-Authenticated-User-Email");
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
    const config = headerConfig("X-Forwarded-Email");

    await expect(new IdentityService(config).fromBrowser(new Request("https://dahlia.example/api/session")))
      .rejects.toThrow("X-Forwarded-Email is missing");
  });
});
