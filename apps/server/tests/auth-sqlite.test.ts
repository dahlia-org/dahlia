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

    await Promise.all([store.migrate(), store.migrate()]);
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
    expect(database.prepare('SELECT "name" FROM "__drizzle_migrations"').get()).toEqual({
      name: "20260830001528_stiff_alex_power",
    });
    expect(database.prepare('SELECT "client_id" FROM "oauth_client"').get()).toEqual({ client_id: "dahlia-macos" });
    expect(database.prepare('SELECT "client_id" FROM "oauth_client_resource"').get()).toEqual({ client_id: "dahlia-macos" });
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
    const expiresAt = now.getTime() + 60_000;
    database.prepare(
      'INSERT INTO "user" ("id", "name", "email", "email_verified", "created_at", "updated_at") VALUES (?, ?, ?, ?, ?, ?)',
    ).run("user-1", "User", "user@example.com", 1, now.getTime(), now.getTime());
    database.prepare(
      'INSERT INTO "session" ("id", "expires_at", "token", "created_at", "updated_at", "user_agent", "user_id") VALUES (?, ?, ?, ?, ?, ?, ?)',
    ).run("session-1", expiresAt, "browser-token", now.getTime(), now.getTime(), "Dahlia", "user-1");
    database.prepare(
      'INSERT INTO "oauth_refresh_token" ("id", "token", "client_id", "session_id", "user_id", "expires_at", "created_at", "scopes") VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    ).run("refresh-1", "refresh-token", "dahlia-macos", "session-1", "user-1", expiresAt, now.getTime(), "[\"api.model.read\",\"api.model.request\"]");
    database.prepare(
      'INSERT INTO "oauth_access_token" ("id", "token", "client_id", "session_id", "user_id", "refresh_id", "expires_at", "created_at", "scopes") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    ).run("access-1", "access-token", "dahlia-macos", "session-1", "user-1", "refresh-1", expiresAt, now.getTime(), "[\"api.model.read\",\"api.model.request\"]");

    expect(await store.listDahliaSessions("user-1")).toMatchObject([
      { id: "refresh-1", sessionId: "session-1", userAgent: "Dahlia" },
    ]);
    expect(await store.revokeDahliaSession("user-1", "refresh-1")).toBe(true);
    expect(database.prepare('SELECT 1 FROM "oauth_access_token" WHERE "id" = ?').get("access-1")).toBeUndefined();
    expect(await store.listDahliaSessions("user-1")).toEqual([]);
    database.close();
    await store.close?.();
  });

  it("names extension migrations by stable directory ID", async () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-auth-"));
    directories.push(directory);
    const first = join(directory, "first");
    const second = join(directory, "second");
    mkdirSync(join(first, "20260830010000_init"), { recursive: true });
    mkdirSync(join(second, "20260830010000_init"), { recursive: true });
    writeFileSync(join(first, "20260830010000_init", "migration.sql"), 'CREATE TABLE "firstExtension" ("id" TEXT PRIMARY KEY);');
    writeFileSync(join(second, "20260830010000_init", "migration.sql"), 'CREATE TABLE "secondExtension" ("id" TEXT PRIMARY KEY);');
    const migrations: MigrationManifest = {
      postgres: { directories: [], files: [] },
      sqlite: {
        directories: [
          { id: "first", path: first, files: ["20260830010000_init/migration.sql"] },
          { id: "second", path: second, files: ["20260830010000_init/migration.sql"] },
        ],
        files: [
          "first/20260830010000_init/migration.sql",
          "second/20260830010000_init/migration.sql",
        ],
      },
    };
    const path = join(directory, "auth.sqlite");
    const store = createNodeAuthStore(testConfig(path), migrations);

    await store.migrate();
    await store.migrate();

    const database = new DatabaseSync(path);
    expect(database.prepare('SELECT "name" FROM "__dahlia_first_migrations"').get())
      .toEqual({ name: "20260830010000_init" });
    expect(database.prepare('SELECT "name" FROM "__dahlia_second_migrations"').get())
      .toEqual({ name: "20260830010000_init" });
    expect(database.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '%Extension' ORDER BY name").all())
      .toEqual([{ name: "firstExtension" }, { name: "secondExtension" }]);
    database.close();
    await store.close?.();
  });

  it("rejects SQLite migration directories that differ from the manifest", async () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-auth-"));
    directories.push(directory);
    const migrationsPath = join(directory, "extension");
    mkdirSync(join(migrationsPath, "20260830010000_listed"), { recursive: true });
    mkdirSync(join(migrationsPath, "20260830020000_unlisted"), { recursive: true });
    writeFileSync(join(migrationsPath, "20260830010000_listed", "migration.sql"),
      'CREATE TABLE "listedExtension" ("id" TEXT PRIMARY KEY);');
    writeFileSync(join(migrationsPath, "20260830020000_unlisted", "migration.sql"),
      'CREATE TABLE "unlistedExtension" ("id" TEXT PRIMARY KEY);');
    const path = join(directory, "auth.sqlite");
    const store = createNodeAuthStore(testConfig(path), {
      postgres: { directories: [], files: [] },
      sqlite: {
        directories: [{
          id: "extension",
          path: migrationsPath,
          files: [
            "20260830010000_listed/migration.sql",
            "20260830030000_missing/migration.sql",
          ],
        }],
        files: [
          "extension/20260830010000_listed/migration.sql",
          "extension/20260830030000_missing/migration.sql",
        ],
      },
    });

    await expect(store.migrate()).rejects.toThrow("SQLite migration files do not match the manifest");
    const database = new DatabaseSync(path);
    expect(database.prepare("SELECT name FROM sqlite_master WHERE name LIKE '%Extension'").all()).toEqual([]);
    database.close();
    await store.close?.();
  });
});
