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
    authProvider: "accounts",
    authHeader: "X-Forwarded-Email",
    databaseType: "sqlite",
    databaseUrl: `file:${path}`,
    baseUrl: "http://localhost:5173",
    googleClientId: "google-client",
    googleClientSecret: "google-secret",
    betterAuthSecret: "test-only-better-auth-secret-value",
    oauthRedirectUris: ["http://127.0.0.1:1455/oauth/callback"],
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
    const auth = await initializeDahliaAuth(config, store);

    await expect((await auth.$context).adapter.transaction(async (transaction) => {
      await transaction.create({
        model: "user",
        forceAllowId: true,
        data: {
          id: "rolled-back-user",
          name: "Rollback",
          email: "rollback@example.com",
          emailVerified: false,
          createdAt: new Date(),
          updatedAt: new Date(),
        },
      });
      throw new Error("rollback");
    })).rejects.toThrow("rollback");

    const database = new DatabaseSync(path);
    expect(database.prepare('SELECT "name" FROM "_dahlia_auth_migrations" ORDER BY "name"').all()).toEqual([
      { name: "server/0001_better_auth.sql" },
      { name: "server/0002_server.sql" },
      { name: "server/0003_artifact.sql" },
      { name: "server/0004_artifact_reservation.sql" },
      { name: "server/0005_artifact_storage_key.sql" },
    ]);
    expect(database.prepare('SELECT "clientId" FROM "oauthClient"').get()).toEqual({ clientId: "dahlia-macos" });
    expect(database.prepare('SELECT "clientId" FROM "oauthClientResource"').get()).toEqual({ clientId: "dahlia-macos" });
    expect(database.prepare('SELECT 1 FROM "user" WHERE "id" = ?').get("rolled-back-user")).toBeUndefined();
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
    expect(await store.createArtifact({
      id: "019cc4dd-e5c5-7bd4-94e0-98df9cc40db9",
      ownerWorkspaceId: "personal:user-1",
      contentType: "text/html",
    })).toBe(true);
    expect(await store.getArtifact("019cc4dd-e5c5-7bd4-94e0-98df9cc40db9")).toMatchObject({
      visibility: "private",
      contentType: "text/html",
    });
    expect(await store.updateArtifactVisibility(
      "019cc4dd-e5c5-7bd4-94e0-98df9cc40db9",
      "personal:user-1",
      "public",
    )).toMatchObject({ visibility: "public" });
    expect(await store.commitArtifactStorage(
      "019cc4dd-e5c5-7bd4-94e0-98df9cc40db9",
      "personal:user-1",
      null,
      "artifacts/version-1",
    )).toMatchObject({ storageKey: "artifacts/version-1", visibility: "public" });
    expect(await store.deleteArtifact(
      "019cc4dd-e5c5-7bd4-94e0-98df9cc40db9",
      "personal:other",
      "artifacts/version-1",
    )).toBe(false);
    expect(await store.deleteArtifact(
      "019cc4dd-e5c5-7bd4-94e0-98df9cc40db9",
      "personal:user-1",
      "artifacts/version-1",
    )).toBe(true);
    expect(await store.createArtifact({
      id: "019cc4dd-e5c5-7bd4-94e0-98df9cc40db9",
      ownerWorkspaceId: "personal:other",
      contentType: "text/html",
    })).toBe(false);
    expect(database.prepare('PRAGMA foreign_key_list("artifact")').all()).toEqual([]);

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
    writeFileSync(join(first, "draft.sql"), 'CREATE TABLE "unlistedDraft" ("id" TEXT PRIMARY KEY);');
    writeFileSync(join(second, "0001_init.sql"), 'CREATE TABLE "secondExtension" ("id" TEXT PRIMARY KEY);');
    const migrations: MigrationManifest = {
      postgres: { directories: [], files: [] },
      sqlite: {
        directories: [
          { id: "first", path: first, files: ["0001_init.sql"] },
          { id: "second", path: second, files: ["0001_init.sql"] },
        ],
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
    expect(database.prepare("SELECT name FROM sqlite_master WHERE name = 'unlistedDraft'").get()).toBeUndefined();
    database.close();
    await store.close?.();
  });
});
