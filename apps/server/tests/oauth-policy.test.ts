import { describe, expect, it, vi } from "vitest";

import { denyOAuthManagement } from "../src/auth/better-auth";
import { IdentityService } from "../src/auth/identity";
import {
  ALL_APIS_SCOPE,
  AUTHORIZATION_SERVER_SCOPES,
  GATEWAY_SCOPES,
  hasApiScope,
  MCP_OAUTH_SCOPES,
  MCP_READ_SCOPE,
  MCP_SCOPE,
  OAUTH_SCOPES,
} from "../src/auth/scopes";
import { createPostgresAuthStore } from "../src/auth/store";
import { authenticateMcpRequest } from "../src/app";
import type { AppConfig } from "../src/config";
import type { PostgresDatabase } from "../src/db/client";

const config: AppConfig = {
  authProvider: "accounts",
  authHeader: "X-Forwarded-Email",
  databaseType: "postgres",
  databaseUrl: "postgresql://unused",
  baseUrl: "https://new.dahlia.example",
  googleClientId: "google-client",
  googleClientSecret: "google-secret",
  betterAuthSecret: "unused-but-long-enough-for-this-test",
  oauthRedirectUris: ["http://127.0.0.1:1455/oauth/callback"],
  maxRequestBytes: 1024,
};

describe("fixed OAuth client policy", () => {
  it("verifies DPoP against the canonical public MCP URL", async () => {
    const identities = new IdentityService(config);
    const verifier = vi.fn(async (request: Request) => {
      expect(request).toBeInstanceOf(Request);
      return {
        sub: "user-1",
        workspace_id: "personal:user-1",
        client_id: "https://client.example/metadata.json",
        exp: Math.floor(Date.now() / 1000) + 60,
        scope: MCP_SCOPE,
      };
    });
    Object.assign(identities, { verifyAccessToken: verifier });
    const internalRequest = new Request("http://internal-proxy:3000/mcp", {
      method: "POST",
      headers: { Authorization: "DPoP access-token", DPoP: "proof" },
    });

    await expect(identities.verifyMcpAccessToken(internalRequest)).resolves.toMatchObject({
      token: "access-token",
      scopes: [MCP_SCOPE],
    });
    const verificationRequest = verifier.mock.calls[0]?.[0] as Request;
    expect(verificationRequest.url).toBe("https://new.dahlia.example/mcp");
    expect(verificationRequest.method).toBe("POST");
    expect(verificationRequest.headers.get("authorization")).toBe("DPoP access-token");
    expect(verificationRequest.headers.get("dpop")).toBe("proof");
  });

  it("verifies MCP resources at their canonical URL and requires sync read scope", async () => {
    const identities = new IdentityService(config);
    const verifier = vi.fn(async (request: Request) => {
      void request;
      return {
        sub: "user-1",
        workspace_id: "personal:user-1",
        client_id: "mcp-client",
        exp: Math.floor(Date.now() / 1000) + 60,
        scope: MCP_READ_SCOPE,
      };
    });
    Object.assign(identities, { verifyAccessToken: verifier });
    const request = new Request("http://internal/mcp/resources/vaults/vault/screenshots/image/content", {
      headers: { Authorization: "DPoP access-token", DPoP: "proof" },
    });

    await expect(identities.fromMcpResource(request, MCP_READ_SCOPE)).resolves.toMatchObject({
      userId: "user-1",
    });
    expect((verifier.mock.calls[0]?.[0] as Request).url)
      .toBe("https://new.dahlia.example/mcp/resources/vaults/vault/screenshots/image/content");
    await expect(identities.fromMcpResource(request, MCP_SCOPE))
      .rejects.toThrow("Insufficient scope");
  });

  it("keeps impersonated OAuth tokens read-only", async () => {
    const identities = new IdentityService(config);
    Object.assign(identities, { verifyAccessToken: vi.fn(async () => ({
      sub: "user-1",
      workspace_id: "personal:user-1",
      client_id: "mcp-client",
      exp: Math.floor(Date.now() / 1000) + 60,
      scope: `${ALL_APIS_SCOPE} ${MCP_SCOPE}`,
      impersonated: true,
    })) });
    const request = new Request("https://new.dahlia.example/mcp", {
      method: "POST",
      headers: { Authorization: "DPoP access-token", DPoP: "proof" },
    });

    await expect(identities.fromGateway(request, ALL_APIS_SCOPE))
      .rejects.toThrow("Impersonated sessions are read-only");
    await expect(identities.verifyMcpAccessToken(request))
      .rejects.toThrow("Impersonated sessions are read-only");
  });

  it("preserves DPoP requests and distinguishes insufficient scope", async () => {
    const request = new Request("https://new.dahlia.example/mcp", {
      method: "POST",
      headers: { Authorization: "DPoP access-token", DPoP: "proof" },
    });
    const authInfo = {
      token: "access-token",
      clientId: "https://client.example/metadata.json",
      scopes: [MCP_SCOPE],
      expiresAt: Math.floor(Date.now() / 1000) + 60,
      resource: new URL("https://new.dahlia.example/mcp"),
    };
    const verifier = vi.fn(async () => authInfo);

    expect(await authenticateMcpRequest(
      request,
      verifier,
      "https://new.dahlia.example/.well-known/oauth-protected-resource/mcp",
    )).toBe(authInfo);
    expect(verifier).toHaveBeenCalledWith(request);

    const insufficient = await authenticateMcpRequest(
      request,
      async () => ({ ...authInfo, scopes: [] }),
      "https://new.dahlia.example/.well-known/oauth-protected-resource/mcp",
    );
    expect(insufficient).toBeInstanceOf(Response);
    expect((insufficient as Response).status).toBe(403);
    expect((insufficient as Response).headers.get("www-authenticate"))
      .toContain('error="insufficient_scope"');
  });

  it("denies user-managed OAuth clients and resources", () => {
    expect(denyOAuthManagement()).toBe(false);
  });

  it("uses one Desktop API scope and hierarchical MCP scopes", () => {
    expect(GATEWAY_SCOPES).toEqual([ALL_APIS_SCOPE]);
    expect(OAUTH_SCOPES).toEqual(["openid", "profile", "email", "offline_access", ALL_APIS_SCOPE]);
    expect(MCP_OAUTH_SCOPES).toEqual(["openid", "profile", "email", "offline_access", MCP_SCOPE, MCP_READ_SCOPE]);
    expect(AUTHORIZATION_SERVER_SCOPES).toEqual([
      "openid", "profile", "email", "offline_access", ALL_APIS_SCOPE, MCP_SCOPE, MCP_READ_SCOPE,
    ]);
    expect(hasApiScope([MCP_SCOPE], MCP_READ_SCOPE)).toBe(true);
    expect(hasApiScope([MCP_READ_SCOPE], MCP_SCOPE)).toBe(false);
  });

  it("does not fall back to a browser session when an Authorization header is present", async () => {
    const identities = new IdentityService(config);
    const gateway = vi.spyOn(identities, "fromGateway").mockRejectedValue(new Error("invalid token"));
    const browser = vi.spyOn(identities, "fromBrowser").mockResolvedValue({
      userId: "browser-user",
      workspaceId: "personal:browser-user",
      source: "accounts",
    });

    await expect(identities.fromBrowserOrGateway(new Request("https://new.dahlia.example/api/v1/artifacts", {
      headers: { authorization: "Bearer invalid" },
    }), ALL_APIS_SCOPE)).rejects.toThrow("invalid token");
    expect(gateway).toHaveBeenCalledOnce();
    expect(browser).not.toHaveBeenCalled();

    await expect(identities.fromBrowserOrGateway(
      new Request("https://new.dahlia.example/api/v1/artifacts"),
      ALL_APIS_SCOPE,
    )).resolves.toMatchObject({ userId: "browser-user" });
    expect(browser).toHaveBeenCalledOnce();
  });

  it("relinks the fixed client when the deployment resource URL changes", async () => {
    const upserts: Array<Record<string, unknown>> = [];
    const db = {
      insert: vi.fn(() => ({
        values: vi.fn(() => ({
          onConflictDoUpdate: vi.fn(async (value: Record<string, unknown>) => {
            upserts.push(value);
          }),
        })),
      })),
      update: vi.fn(() => ({
        set: vi.fn(() => ({ where: vi.fn(async () => []) })),
      })),
      select: vi.fn(() => ({
        from: vi.fn(() => ({
          where: vi.fn(() => ({ limit: vi.fn(async () => [{ id: "resource-id" }]) })),
        })),
      })),
    } as unknown as PostgresDatabase;

    await createPostgresAuthStore(db).seedDahliaClient(config);

    expect(upserts[1]).toMatchObject({
      set: {
        clientId: "databricks-cli",
        resourceId: "https://new.dahlia.example/api/v1",
      },
    });
    expect(upserts[0]).toMatchObject({
      set: {
        scopes: OAUTH_SCOPES,
      },
    });
  });
});
