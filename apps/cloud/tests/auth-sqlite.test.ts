import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

import { afterEach, describe, expect, it } from "vitest";

import { initializeDahliaAuth } from "../src/auth/better-auth";
import { createNodeAuthStore } from "../src/auth/node-store";
import type { AppConfig } from "../src/config";

const directories: string[] = [];

function testConfig(path: string): AppConfig {
  return {
    runtime: "custom",
    authProvider: "accounts",
    authHeader: "X-Forwarded-Email",
    authDatabase: "sqlite",
    authSqlitePath: path,
    baseUrl: "http://localhost:5173",
    googleClientId: "google-client",
    googleClientSecret: "google-secret",
    betterAuthSecret: "test-only-better-auth-secret-value",
    oauthRedirectUris: ["http://127.0.0.1:1455/oauth/callback"],
    trustedProxyCidrs: [],
    maxRequestBytes: 1024,
  };
}

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { force: true, recursive: true });
});

describe("SQLite Better Auth store", () => {
  it("migrates, seeds the fixed client, and revokes a Dahlia session", async () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-auth-"));
    directories.push(directory);
    const path = join(directory, "auth.sqlite");
    const config = testConfig(path);
    const store = createNodeAuthStore(config);

    await store.migrate();
    await store.migrate();
    await initializeDahliaAuth(config, store);

    const database = new DatabaseSync(path);
    expect(database.prepare('SELECT "name" FROM "_dahlia_auth_migrations" ORDER BY "name"').all()).toEqual([
      { name: "0001_better_auth.sql" },
      { name: "0002_billing_and_team.sql" },
      { name: "0003_gateway_entitlement.sql" },
    ]);
    expect(database.prepare('SELECT "clientId" FROM "oauthClient"').get()).toEqual({ clientId: "dahlia-macos" });
    expect(database.prepare('SELECT "clientId" FROM "oauthClientResource"').get()).toEqual({ clientId: "dahlia-macos" });
    expect(await store.createModelAlias({
      alias: "summary",
      upstreamModel: "provider/model",
      displayName: null,
      enabled: true,
    })).toBe(true);
    expect(await store.createModelAlias({
      alias: "summary",
      upstreamModel: "duplicate",
      displayName: null,
      enabled: true,
    })).toBe(false);
    expect(await store.getEnabledModelAlias("summary")).toMatchObject({ alias: "summary", upstreamModel: "provider/model" });
    expect(await store.updateModelAlias("summary", {
      upstreamModel: "provider/model-v2",
      displayName: "Summary",
      enabled: false,
    })).toBe(true);
    expect(await store.getEnabledModelAlias("summary")).toBeNull();
    expect(await store.listModelAliases()).toMatchObject([{ alias: "summary", displayName: "Summary", enabled: false }]);
    expect(await store.addPlatformAdmin("admin@example.com")).toBe(true);
    expect(await store.addPlatformAdmin("admin@example.com")).toBe(false);
    expect(await store.isPlatformAdmin("admin@example.com")).toBe(true);
    expect(await store.listPlatformAdmins()).toMatchObject([{ email: "admin@example.com" }]);
    expect(await store.deletePlatformAdmin("admin@example.com")).toBe(true);
    expect(await store.deleteModelAlias("summary")).toBe(true);

    const now = new Date();
    const expiresAt = new Date(now.getTime() + 60_000).toISOString();
    database.prepare(
      'INSERT INTO "user" ("id", "name", "email", "emailVerified", "createdAt", "updatedAt") VALUES (?, ?, ?, ?, ?, ?)',
    ).run("user-1", "User", "user@example.com", 1, now.toISOString(), now.toISOString());
    database.prepare('UPDATE "user" SET "stripeCustomerId" = ? WHERE "id" = ?').run("cus_user", "user-1");
    database.prepare(
      'INSERT INTO "organization" ("id", "name", "slug", "createdAt") VALUES (?, ?, ?, ?)',
    ).run("org-1", "First", "first", now.toISOString());
    database.prepare(
      'INSERT INTO "organization" ("id", "name", "slug", "createdAt") VALUES (?, ?, ?, ?)',
    ).run("org-2", "Second", "second", now.toISOString());
    database.prepare(
      'INSERT INTO "member" ("id", "organizationId", "userId", "role", "createdAt") VALUES (?, ?, ?, ?, ?)',
    ).run("member-1", "org-1", "user-1", "owner", now.toISOString());
    expect(() => database.prepare(
      'INSERT INTO "member" ("id", "organizationId", "userId", "role", "createdAt") VALUES (?, ?, ?, ?, ?)',
    ).run("member-2", "org-2", "user-1", "member", now.toISOString())).toThrow(/UNIQUE/);
    database.prepare(
      `INSERT INTO "subscription" (
        "id", "plan", "referenceId", "stripeCustomerId", "stripeSubscriptionId", "status",
        "periodStart", "periodEnd", "cancelAtPeriodEnd"
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run("subscription-1", "pro", "user-1", "cus_user", "sub-user-1", "active", now.toISOString(), expiresAt, 0);
    database.prepare(
      'INSERT INTO "session" ("id", "expiresAt", "token", "createdAt", "updatedAt", "userAgent", "userId") VALUES (?, ?, ?, ?, ?, ?, ?)',
    ).run("session-1", expiresAt, "browser-token", now.toISOString(), now.toISOString(), "Dahlia", "user-1");
    database.prepare(
      'INSERT INTO "oauthRefreshToken" ("id", "token", "clientId", "sessionId", "userId", "expiresAt", "createdAt", "scopes") VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    ).run("refresh-1", "refresh-token", "dahlia-macos", "session-1", "user-1", expiresAt, now.toISOString(), "[\"api.model.read\",\"api.model.request\"]");
    database.prepare(
      'INSERT INTO "oauthAccessToken" ("id", "token", "clientId", "sessionId", "userId", "refreshId", "expiresAt", "createdAt", "scopes") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    ).run("access-1", "access-token", "dahlia-macos", "session-1", "user-1", "refresh-1", expiresAt, now.toISOString(), "[\"api.model.read\",\"api.model.request\"]");

    expect(await store.listDahliaSessions("user-1")).toMatchObject([
      { id: "refresh-1", sessionId: "session-1", userAgent: "Dahlia" },
    ]);
    expect(await store.revokeDahliaSession("user-1", "refresh-1")).toBe(true);
    expect(database.prepare('SELECT 1 FROM "oauthAccessToken" WHERE "id" = ?').get("access-1")).toBeUndefined();
    expect(await store.listDahliaSessions("user-1")).toEqual([]);
    expect(await store.getStripeCustomerId("user-1")).toBe("cus_user");
    expect(await store.getBillingSubscription("user-1")).toMatchObject({
      plan: "pro",
      status: "active",
      stripeCustomerId: "cus_user",
      cancelAtPeriodEnd: false,
    });
    expect(await store.getBillingReferenceId("sub-user-1")).toBe("user-1");

    const entitlement = (status: string, eventCreated: number, eventId: string) => ({
      referenceId: "user-1",
      stripeSubscriptionId: "sub-user-1",
      plan: "pro",
      status,
      periodEnd: new Date(expiresAt),
      cancelAtPeriodEnd: false,
      cancelAt: null,
      canceledAt: status === "canceled" ? now : null,
      endedAt: status === "canceled" ? now : null,
      eventCreated,
      eventId,
    });
    await expect(store.syncGatewayEntitlement(entitlement("canceled", 2, "evt_canceled"))).resolves.toBe("updated");
    await expect(store.syncGatewayEntitlement(entitlement("canceled", 2, "evt_canceled"))).resolves.toBe("stale");
    await expect(store.syncGatewayEntitlement(entitlement("active", 1, "evt_active_old"))).resolves.toBe("stale");
    await expect(store.syncGatewayEntitlement(entitlement("active", 2, "evt_active_same_second"))).resolves.toBe("stale");
    expect(await store.getGatewayEntitlement("user-1")).toMatchObject({ status: "canceled" });

    database.close();
    await store.close?.();
  });
});
