import { describe, expect, it } from "vitest";

import { IdentityService, trustedRemoteAddress } from "../src/auth/identity";
import type { AppConfig } from "../src/config";

describe("trusted proxy network boundary", () => {
  it("accepts IPv4 and mapped IPv6 addresses inside the allowlist", () => {
    expect(trustedRemoteAddress("10.20.30.40", ["10.0.0.0/8"])).toBe(true);
    expect(trustedRemoteAddress("::ffff:10.20.30.40", ["10.0.0.0/8"])).toBe(true);
  });

  it("rejects direct, missing, and malformed source addresses", () => {
    expect(trustedRemoteAddress("203.0.113.5", ["10.0.0.0/8"])).toBe(false);
    expect(trustedRemoteAddress(undefined, ["10.0.0.0/8"])).toBe(false);
    expect(trustedRemoteAddress("not-an-ip", ["10.0.0.0/8"])).toBe(false);
  });

  it("fails closed for malformed CIDRs", () => {
    expect(trustedRemoteAddress("10.20.30.40", ["not-a-cidr"])).toBe(false);
  });

  it("uses the configured email header as the full identity", async () => {
    const config: AppConfig = {
      runtime: "custom",
      authProvider: "header",
      authHeader: "Cf-Access-Authenticated-User-Email",
      authDatabase: "sqlite",
      baseUrl: "https://dahlia.example",
      oauthRedirectUris: [],
      trustedProxyCidrs: [],
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
      runtime: "custom",
      authProvider: "header",
      authHeader: "X-Forwarded-Email",
      authDatabase: "sqlite",
      baseUrl: "https://dahlia.example",
      oauthRedirectUris: [],
      trustedProxyCidrs: [],
      maxRequestBytes: 1024,
    };

    await expect(new IdentityService(config).fromBrowser(new Request("https://dahlia.example/api/session")))
      .rejects.toThrow("X-Forwarded-Email is missing");
  });
});
