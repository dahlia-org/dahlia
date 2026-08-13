import { describe, expect, it, vi } from "vitest";

import { denyOAuthManagement } from "../src/auth/better-auth";
import {
  GATEWAY_SCOPES,
  MODEL_READ_SCOPE,
  MODEL_REQUEST_SCOPE,
  OAUTH_SCOPES,
} from "../src/auth/scopes";
import { createPostgresAuthStore } from "../src/auth/store";
import { requiredGatewayScope } from "../src/app";
import type { AppConfig } from "../src/config";
import type { Database } from "../src/db/client";

const config: AppConfig = {
  runtime: "custom",
  authProvider: "accounts",
  authHeader: "X-Forwarded-Email",
  authDatabase: "postgres",
  authDatabaseUrl: "postgresql://unused",
  baseUrl: "https://new.dahlia.example",
  googleClientId: "google-client",
  googleClientSecret: "google-secret",
  betterAuthSecret: "unused-but-long-enough-for-this-test",
  oauthRedirectUris: ["http://127.0.0.1:1455/oauth/callback"],
  trustedProxyCidrs: [],
  maxRequestBytes: 1024,
};

describe("fixed OAuth client policy", () => {
  it("denies user-managed OAuth clients and resources", () => {
    expect(denyOAuthManagement()).toBe(false);
  });

  it("uses separate model read and request scopes", () => {
    expect(GATEWAY_SCOPES).toEqual(["api.model.read", "api.model.request"]);
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
      query: {
        oauthResource: {
          findFirst: vi.fn(async () => ({ id: "resource-id" })),
        },
      },
    } as unknown as Database;

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
