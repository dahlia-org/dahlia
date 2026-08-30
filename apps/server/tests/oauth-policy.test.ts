import { describe, expect, it, vi } from "vitest";

import { denyOAuthManagement } from "../src/auth/better-auth";
import { IdentityService } from "../src/auth/identity";
import {
  ARTIFACT_READ_SCOPE,
  ARTIFACT_WRITE_SCOPE,
  GATEWAY_SCOPES,
  MODEL_READ_SCOPE,
  MODEL_REQUEST_SCOPE,
  OAUTH_SCOPES,
} from "../src/auth/scopes";
import { createPostgresAuthStore } from "../src/auth/store";
import { authenticateMcpRequest, requiredGatewayScope } from "../src/app";
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
        scope: ARTIFACT_WRITE_SCOPE,
      };
    });
    Object.assign(identities, { verifyAccessToken: verifier });
    const internalRequest = new Request("http://internal-proxy:3000/mcp", {
      method: "POST",
      headers: { Authorization: "DPoP access-token", DPoP: "proof" },
    });

    await expect(identities.verifyMcpAccessToken(internalRequest)).resolves.toMatchObject({
      token: "access-token",
      scopes: [ARTIFACT_WRITE_SCOPE],
    });
    const verificationRequest = verifier.mock.calls[0]?.[0] as Request;
    expect(verificationRequest.url).toBe("https://new.dahlia.example/mcp");
    expect(verificationRequest.method).toBe("POST");
    expect(verificationRequest.headers.get("authorization")).toBe("DPoP access-token");
    expect(verificationRequest.headers.get("dpop")).toBe("proof");
  });

  it("preserves DPoP requests and distinguishes insufficient scope", async () => {
    const request = new Request("https://new.dahlia.example/mcp", {
      method: "POST",
      headers: { Authorization: "DPoP access-token", DPoP: "proof" },
    });
    const authInfo = {
      token: "access-token",
      clientId: "https://client.example/metadata.json",
      scopes: [ARTIFACT_WRITE_SCOPE],
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

  it("uses separate model read and request scopes", () => {
    expect(GATEWAY_SCOPES).toEqual([
      "api.model.read",
      "api.model.request",
      "api.artifact.read",
      "api.artifact.write",
    ]);
    expect(OAUTH_SCOPES).toContain(ARTIFACT_READ_SCOPE);
    expect(OAUTH_SCOPES).toContain(ARTIFACT_WRITE_SCOPE);
    expect(requiredGatewayScope("/api/v1/models")).toBe(MODEL_READ_SCOPE);
    expect(requiredGatewayScope("/api/v1/responses")).toBe(MODEL_REQUEST_SCOPE);
    expect(requiredGatewayScope("/api/v1/unknown")).toBe(MODEL_REQUEST_SCOPE);
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
      select: vi.fn(() => ({
        from: vi.fn(() => ({
          where: vi.fn(() => ({ limit: vi.fn(async () => [{ id: "resource-id" }]) })),
        })),
      })),
    } as unknown as PostgresDatabase;

    await createPostgresAuthStore(db).seedDahliaClient(config);

    expect(upserts[1]).toMatchObject({
      set: {
        clientId: "dahlia-macos",
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
