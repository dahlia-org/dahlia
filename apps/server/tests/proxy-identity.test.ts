import { describe, expect, it } from "vitest";

import { IdentityService } from "../src/auth/identity";
import type { AppConfig } from "../src/config";

function headerConfig(authHeader: string, localSingleUser = false): AppConfig {
  return {
    authProvider: "header",
    authHeader,
    localSingleUser,
    databaseType: "sqlite",
    baseUrl: "https://dahlia.example",
    oauthRedirectUris: [],
    maxRequestBytes: 1024,
  };
}

describe("proxy identity boundary", () => {
  it("uses email identity and the preferred username, ignoring forwarded user ID", async () => {
    const config = headerConfig("X-Forwarded-Email");
    const identity = await new IdentityService(config).fromBrowser(new Request("https://dahlia.example/api/v1/session", {
      headers: {
        "X-Forwarded-Email": " User@Example.com ",
        "X-Forwarded-Preferred-Username": " Dahlia User ",
        "X-Forwarded-User": "123456789",
      },
    }));

    expect(identity).toEqual({
      userId: "user@example.com",
      email: "user@example.com",
      name: "Dahlia User",
      workspaceId: "personal:user@example.com",
      source: "header",
    });
  });

  it("uses the configured email header as the full identity", async () => {
    const config = headerConfig("Cf-Access-Authenticated-User-Email");
    const identity = await new IdentityService(config).fromBrowser(new Request("https://dahlia.example/api/v1/session", {
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

    await expect(new IdentityService(config).fromBrowser(new Request("https://dahlia.example/api/v1/session")))
      .rejects.toThrow("X-Forwarded-Email must contain a valid email");
  });

  it("projects the verified header identity before returning it", async () => {
    const projected: string[] = [];
    const identities = new IdentityService(headerConfig("X-Forwarded-Email"), undefined, async (identity) => {
      projected.push(identity.userId);
      return identity;
    });

    await identities.fromBrowser(new Request("https://dahlia.example/api/v1/session", {
      headers: {
        "X-Forwarded-Email": "user@example.com",
        "X-Forwarded-User": "stable-user-id",
      },
    }));

    expect(projected).toEqual(["user@example.com"]);
  });

  it("fails closed when the header identity conflicts with the user directory", async () => {
    const identities = new IdentityService(
      headerConfig("X-Forwarded-Email"),
      undefined,
      () => Promise.resolve(null),
    );

    await expect(identities.fromBrowser(new Request("https://dahlia.example/api/v1/session", {
      headers: { "X-Forwarded-Email": "user@example.com" },
    }))).rejects.toThrow("identity_projection_failed");
  });
});

describe("local single-user identity", () => {
  it("uses the fixed local identity without any request header", async () => {
    const config = headerConfig("X-Forwarded-Email", true);
    const identity = await new IdentityService(config).fromBrowser(new Request("https://dahlia.example/api/v1/session"));

    expect(identity).toEqual({
      userId: "local@example.com",
      email: "local@example.com",
      name: undefined,
      workspaceId: "personal:local@example.com",
      source: "header",
    });
  });

  it("ignores client-supplied identity and display-name headers", async () => {
    const config = headerConfig("X-Forwarded-Email", true);
    const identity = await new IdentityService(config).fromBrowser(new Request("https://dahlia.example/api/v1/session", {
      headers: {
        "X-Forwarded-Email": "attacker@example.com",
        "X-Forwarded-Preferred-Username": "Attacker",
      },
    }));

    expect(identity).toMatchObject({ userId: "local@example.com", email: "local@example.com", name: undefined });
  });

  it("still projects the local identity and fails closed when projection is refused", async () => {
    const projected: string[] = [];
    const identities = new IdentityService(headerConfig("X-Forwarded-Email", true), undefined, async (identity) => {
      projected.push(identity.userId);
      return identity;
    });
    await identities.fromBrowser(new Request("https://dahlia.example/api/v1/session"));
    expect(projected).toEqual(["local@example.com"]);

    const refused = new IdentityService(headerConfig("X-Forwarded-Email", true), undefined, () => Promise.resolve(null));
    await expect(refused.fromBrowser(new Request("https://dahlia.example/api/v1/session")))
      .rejects.toThrow("identity_projection_failed");
  });

  it("keeps rejecting a missing header while it is disabled", async () => {
    await expect(new IdentityService(headerConfig("X-Forwarded-Email")).fromBrowser(new Request("https://dahlia.example/api/v1/session")))
      .rejects.toThrow("X-Forwarded-Email must contain a valid email");
  });
});
