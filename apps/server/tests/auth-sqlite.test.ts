import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

import { afterEach, describe, expect, it } from "vitest";

import { initializeDahliaAuth } from "../src/auth/better-auth";
import { createNodeAuthStore } from "../src/auth/node-store";
import type { AppConfig } from "../src/config";
import type { MigrationManifest } from "../src/migrations";

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
      { name: "server/0001_better_auth.sql" },
      { name: "server/0002_server.sql" },
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
    database.close();
    await store.close?.();
  });

  it("names extension migrations by stable directory ID", async () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-auth-"));
    directories.push(directory);
    const first = join(directory, "first");
    const second = join(directory, "second");
    mkdirSync(first);
    mkdirSync(second);
    writeFileSync(join(first, "0001_init.sql"), 'CREATE TABLE "firstExtension" ("id" TEXT PRIMARY KEY);');
    writeFileSync(join(second, "0001_init.sql"), 'CREATE TABLE "secondExtension" ("id" TEXT PRIMARY KEY);');
    const migrations: MigrationManifest = {
      postgres: { directories: [], files: [] },
      sqlite: {
        directories: [{ id: "first", path: first }, { id: "second", path: second }],
        files: ["first/0001_init.sql", "second/0001_init.sql"],
      },
    };
    const path = join(directory, "auth.sqlite");
    const store = createNodeAuthStore(testConfig(path), migrations);

    await store.migrate();
    await store.migrate();

    const database = new DatabaseSync(path);
    expect(database.prepare('SELECT "name" FROM "_dahlia_auth_migrations" ORDER BY "name"').all()).toEqual([
      { name: "first/0001_init.sql" },
      { name: "second/0001_init.sql" },
    ]);
    expect(database.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '%Extension' ORDER BY name").all())
      .toEqual([{ name: "firstExtension" }, { name: "secondExtension" }]);
    database.close();
    await store.close?.();
  });
});
