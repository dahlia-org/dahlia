import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

import { cimd } from "@better-auth/cimd";
import { afterEach, describe, expect, it } from "vitest";

import { createApp } from "../src/app";
import { LocalObjectStorage } from "../src/artifacts/local";
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
  it("creates one external organization owner under concurrent first header access", async () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-header-concurrent-"));
    directories.push(directory);
    const path = join(directory, "header.sqlite");
    const config = { ...testConfig(path), authProvider: "header" as const };
    const store = createNodeAuthStore(config);
    await store.migrate();
    const app = createApp({ config, authStore: store, artifactStorage: new LocalObjectStorage(join(directory, "storage")) });
    const responses = await Promise.all(["first", "second"].map((user) => Promise.resolve().then(() =>
      app.request("/api/session", { headers: {
        "X-Forwarded-Email": `${user}@example.com`,
        "X-Forwarded-User": user,
      } }))));
    expect(responses.map(({ status }) => status)).toEqual([200, 200]);
    const database = new DatabaseSync(path);
    expect(database.prepare("SELECT count(*) AS count FROM organization WHERE id = 'external'").get()).toEqual({ count: 1 });
    expect(database.prepare("SELECT count(*) AS count FROM member WHERE organization_id = 'external' AND role = 'owner'").get())
      .toEqual({ count: 1 });
    expect(database.prepare("SELECT count(*) AS count FROM team WHERE id = 'external-default'").get()).toEqual({ count: 1 });
    expect(database.prepare("SELECT count(*) AS count FROM team_member WHERE team_id = 'external-default'").get())
      .toEqual({ count: 1 });
    database.close();
    await store.close?.();
  });

  it("projects trusted header users into the generated auth user table", async () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-header-user-"));
    directories.push(directory);
    const path = join(directory, "header.sqlite");
    const config = { ...testConfig(path), authProvider: "header" as const };
    const store = createNodeAuthStore(config);
    await store.migrate();
    const app = createApp({
      config,
      authStore: store,
      artifactStorage: new LocalObjectStorage(join(directory, "storage")),
    });
    expect((await app.request("/api/auth/admin/list-users")).status).toBe(404);

    const first = await app.request("/api/session", { headers: {
      "X-Forwarded-Email": "User@Example.com",
      "X-Forwarded-Preferred-Username": "First Name",
      "X-Forwarded-User": "stable-user-id",
    } });
    expect(first.status).toBe(200);

    const database = new DatabaseSync(path);
    expect(database.prepare(
      'SELECT id, name, email, email_verified, role FROM "user" WHERE id = ?',
    ).get("stable-user-id")).toEqual({
      id: "stable-user-id",
      name: "First Name",
      email: "user@example.com",
      email_verified: 1,
      role: "admin",
    });
    expect(database.prepare('SELECT id, name, slug FROM organization WHERE id = ?').get("external"))
      .toEqual({ id: "external", name: "external", slug: "external" });
    expect(database.prepare('SELECT user_id, role FROM member WHERE organization_id = ?').get("external"))
      .toEqual({ user_id: "stable-user-id", role: "owner" });
    expect(database.prepare('SELECT id, name, organization_id FROM team WHERE id = ?').get("external-default"))
      .toEqual({ id: "external-default", name: "External", organization_id: "external" });
    expect(database.prepare('SELECT user_id FROM team_member WHERE team_id = ?').get("external-default"))
      .toEqual({ user_id: "stable-user-id" });

    const updated = await app.request("/api/session", { headers: {
      "X-Forwarded-Email": "renamed@example.com",
      "X-Forwarded-Preferred-Username": "Renamed User",
      "X-Forwarded-User": "stable-user-id",
    } });
    expect(updated.status).toBe(200);
    expect(database.prepare('SELECT name, email FROM "user" WHERE id = ?').get("stable-user-id"))
      .toEqual({ name: "Renamed User", email: "renamed@example.com" });

    const conflict = await app.request("/api/session", { headers: {
      "X-Forwarded-Email": "renamed@example.com",
      "X-Forwarded-User": "different-user-id",
    } });
    expect(conflict.status).toBe(409);
    expect(await conflict.json()).toEqual({ error: "identity_projection_failed" });
    expect(database.prepare('SELECT count(*) AS count FROM "user"').get()).toEqual({ count: 1 });

    expect((await app.request("/api/session", { headers: {
      "X-Forwarded-Email": "second@example.com",
      "X-Forwarded-User": "second-user-id",
    } })).status).toBe(200);
    expect(database.prepare('SELECT role FROM member WHERE organization_id = ? AND user_id = ?')
      .get("external", "second-user-id")).toEqual({ role: "member" });
    expect(database.prepare('SELECT 1 FROM team_member WHERE team_id = ? AND user_id = ?')
      .get("external-default", "second-user-id")).toBeUndefined();
    database.prepare('DELETE FROM team_member WHERE team_id = ? AND user_id = ?')
      .run("external-default", "stable-user-id");
    expect((await app.request("/api/session", { headers: {
      "X-Forwarded-Email": "renamed@example.com",
      "X-Forwarded-Preferred-Username": "Renamed User",
      "X-Forwarded-User": "stable-user-id",
    } })).status).toBe(200);
    expect(database.prepare('SELECT user_id FROM team_member WHERE team_id = ?').get("external-default"))
      .toEqual({ user_id: "stable-user-id" });

    database.prepare('INSERT INTO core_vaults (vault_id, name) VALUES (?, ?)').run("019d493d-f5f4-7b8b-a9da-8ef51975b171", "Vault");
    database.prepare(`
      INSERT INTO core_search_index_jobs
        (vault_id, document_id, owner_user_id, model, dimensions)
      VALUES (?, ?, ?, 'model', 32)
    `).run(
      "019d493d-f5f4-7b8b-a9da-8ef51975b171",
      "019d493e-0147-7cf6-b56c-b036960bba02",
      "stable-user-id",
    );
    database.prepare('DELETE FROM "user" WHERE id = ?').run("stable-user-id");
    expect(database.prepare("SELECT count(*) AS count FROM core_search_index_jobs").get()).toEqual({ count: 0 });

    const now = Date.now();
    database.prepare(`
      INSERT INTO "user" (id, name, email, email_verified, created_at, updated_at)
      VALUES ('grantor', 'Grantor', 'grantor@example.com', 1, ?, ?)
    `).run(now, now);
    database.prepare('INSERT INTO core_vaults (vault_id, name) VALUES (?, ?)').run("019d493e-063e-70ed-ab24-c86de735bca8", "Vault");
    database.prepare(`
      INSERT INTO core_vault_permissions
        (vault_id, principal_type, principal_id, role, granted_by_user_id)
      VALUES (?, 'user', 'grantor', 'owner', 'grantor')
    `).run("019d493e-063e-70ed-ab24-c86de735bca8");
    expect(() => database.prepare('DELETE FROM "user" WHERE id = ?').run("grantor")).toThrow();

    database.close();
    await store.close?.();
  });

  it("migrates, seeds the fixed client, and revokes a Dahlia session", async () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-auth-"));
    directories.push(directory);
    const path = join(directory, "auth.sqlite");
    const config = testConfig(path);
    const store = createNodeAuthStore(config);

    await Promise.all([store.migrate(), store.migrate()]);
    const database = new DatabaseSync(path);
    database.prepare(
      'INSERT INTO "oauth_client" ("id", "client_id", "redirect_uris", "disabled") VALUES (?, ?, ?, ?)',
    ).run("oauth-client-dahlia-macos", "dahlia-macos", "[]", 0);
    const auth = await initializeDahliaAuth(config, store, [{
      plugins: [cimd({
        fetchClientMetadataResource: async () => new Response(null, { status: 404 }),
        metadataProfile: "mcp-2026-07-28",
      })],
    }]);

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

    expect(database.prepare('SELECT "name" FROM "__drizzle_migrations" ORDER BY "created_at" DESC LIMIT 1').get())
      .toEqual({
      name: "20260903075857_flowery_thunderbolt",
    });
    expect(database.prepare('SELECT "client_id" FROM "oauth_client" WHERE "client_id" = ?').get("databricks-cli"))
      .toEqual({ client_id: "databricks-cli" });
    expect(database.prepare('SELECT "disabled" FROM "oauth_client" WHERE "client_id" = ?').get("dahlia-macos"))
      .toEqual({ disabled: 1 });
    expect(database.prepare('SELECT "client_id" FROM "oauth_client_resource"').get()).toEqual({ client_id: "databricks-cli" });
    expect(database.prepare(
      'SELECT "identifier", "dpop_bound_access_tokens_required" FROM "oauth_resource" ORDER BY "identifier"',
    ).all()).toEqual([
      { identifier: "http://localhost:5173/api/v1", dpop_bound_access_tokens_required: 0 },
      { identifier: "http://localhost:5173/mcp", dpop_bound_access_tokens_required: 1 },
    ]);
    expect(await auth.api.getOAuthServerConfig()).toMatchObject({ client_id_metadata_document_supported: true });
    const app = createApp({
      config,
      auth,
      authStore: store,
      artifactStorage: new LocalObjectStorage(join(directory, "storage")),
    });
    const apiMetadata = await app.request("/.well-known/oauth-protected-resource");
    expect(await apiMetadata.json()).toMatchObject({
      resource: "http://localhost:5173/api/v1",
      authorization_servers: ["http://localhost:5173"],
      scopes_supported: ["all-apis"],
    });
    const metadata = await app.request("/.well-known/oauth-protected-resource/mcp");
    expect(await metadata.json()).toMatchObject({
      resource: "http://localhost:5173/mcp",
      authorization_servers: ["http://localhost:5173"],
      scopes_supported: ["mcp", "mcp:read"],
    });
    const unauthorizedMcp = await app.request("/mcp", {
      method: "POST",
      headers: { "content-length": "2", "content-type": "application/json" },
      body: "{}",
    });
    expect(unauthorizedMcp.status).toBe(401);
    expect(unauthorizedMcp.headers.get("www-authenticate"))
      .toContain('resource_metadata="http://localhost:5173/.well-known/oauth-protected-resource/mcp"');
    expect((await app.request("/api/auth/organization/list")).status).toBe(404);
    expect((await app.request("/api/auth/admin/list-users")).status).toBe(401);
    expect(database.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('organization', 'member', 'invitation', 'team', 'team_member') ORDER BY name").all())
      .toEqual([{ name: "invitation" }, { name: "member" }, { name: "organization" }, { name: "team" }, { name: "team_member" }]);
    expect(database.prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'member_user_organization_idx'").get())
      .toEqual({ name: "member_user_organization_idx" });
    expect(database.prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'team_member_user_team_idx'").get())
      .toEqual({ name: "team_member_user_team_idx" });
    expect(database.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'content_search_documents_fts'",
    ).all()).toEqual([{ name: "content_search_documents_fts" }]);

    const now = new Date();
    const expiresAt = now.getTime() + 60_000;
    const clientSecret = "mcp-client-secret";
    database.prepare(
      'INSERT INTO "oauth_client" ("id", "client_id", "client_secret", "token_endpoint_auth_method", "redirect_uris", "grant_types", "scopes", "client_credentials_scopes", "created_at", "updated_at") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    ).run(
      "oauth-client-mcp-test",
      "mcp-test-client",
      createHash("sha256").update(clientSecret).digest("base64url"),
      "client_secret_post",
      "[]",
      '["client_credentials"]',
      '["mcp"]',
      '["mcp"]',
      now.getTime(),
      now.getTime(),
    );
    database.prepare(
      'INSERT INTO "oauth_client_resource" ("id", "client_id", "resource_id", "created_at") VALUES (?, ?, ?, ?)',
    ).run("oauth-client-resource-mcp-test", "mcp-test-client", "http://localhost:5173/mcp", now.getTime());
    const tokenWithoutDpop = await app.request("/api/auth/oauth2/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "client_credentials",
        client_id: "mcp-test-client",
        client_secret: clientSecret,
        scope: "mcp",
        resource: "http://localhost:5173/mcp",
      }),
    });
    expect(tokenWithoutDpop.status).toBe(400);
    expect(await tokenWithoutDpop.json()).toMatchObject({
      error: "invalid_dpop_proof",
      error_description: "DPoP proof header is required",
    });

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
    await store.ensureIdentityUser({
      userId: "first-admin",
      workspaceId: "personal:first-admin",
      email: "first-admin@example.com",
      source: "header",
    });
    await store.ensureIdentityUser({
      userId: "second-admin",
      workspaceId: "personal:second-admin",
      email: "second-admin@example.com",
      source: "header",
    });
    expect(await store.addAdminUser("second-admin@example.com")).toMatchObject({ id: "second-admin" });
    expect(await store.isAdminUser("second-admin")).toBe(true);
    expect(await store.listAdminUsers()).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: "first-admin" }),
      expect.objectContaining({ id: "second-admin" }),
    ]));
    expect(await store.removeAdminUser("second-admin@example.com")).toBe("removed");
    expect(await store.deleteModelAlias("summary")).toBe(true);
    expect(await store.createArtifact({
      id: "019cc4dd-e5c5-7bd4-94e0-98df9cc40db9",
      ownerWorkspaceId: "personal:user-1",
      contentType: "text/html",
    })).toMatchObject({ id: "019cc4dd-e5c5-7bd4-94e0-98df9cc40db9", visibility: "private" });
    expect(await store.getArtifact("019cc4dd-e5c5-7bd4-94e0-98df9cc40db9")).toMatchObject({
      visibility: "private",
      contentType: "text/html",
    });
    expect(await store.createArtifact({
      id: "019cc4dd-e5c6-7bd4-94e0-98df9cc40dba",
      ownerWorkspaceId: "personal:user-1",
      contentType: "text/plain",
    })).not.toBeNull();
    expect(await store.listArtifacts("personal:user-1", undefined, 2)).toEqual([]);
    expect(await store.commitArtifactStorage(
      "019cc4dd-e5c5-7bd4-94e0-98df9cc40db9",
      "personal:user-1",
      null,
      "artifacts/version-1",
    )).toMatchObject({ storageKey: "artifacts/version-1" });
    expect(await store.commitArtifactStorage(
      "019cc4dd-e5c6-7bd4-94e0-98df9cc40dba",
      "personal:user-1",
      null,
      "artifacts/version-2",
    )).toMatchObject({ storageKey: "artifacts/version-2" });
    expect((await store.listArtifacts("personal:user-1", undefined, 1)).map(({ id }) => id))
      .toEqual(["019cc4dd-e5c6-7bd4-94e0-98df9cc40dba"]);
    expect((await store.listArtifacts(
      "personal:user-1",
      "019cc4dd-e5c6-7bd4-94e0-98df9cc40dba",
      2,
    )).map(({ id }) => id)).toEqual(["019cc4dd-e5c5-7bd4-94e0-98df9cc40db9"]);
    expect(await store.updateArtifactVisibility(
      "019cc4dd-e5c5-7bd4-94e0-98df9cc40db9",
      "personal:user-1",
      "public",
    )).toMatchObject({ visibility: "public" });
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
    })).toMatchObject({ id: "019cc4dd-e5c5-7bd4-94e0-98df9cc40db9", visibility: "private" });
    expect(database.prepare('PRAGMA foreign_key_list("artifact")').all()).toEqual([]);

    database.prepare(
      'INSERT INTO "user" ("id", "name", "email", "email_verified", "created_at", "updated_at") VALUES (?, ?, ?, ?, ?, ?)',
    ).run("user-1", "User", "user@example.com", 1, now.getTime(), now.getTime());
    database.prepare(
      'INSERT INTO "session" ("id", "expires_at", "token", "created_at", "updated_at", "user_agent", "user_id") VALUES (?, ?, ?, ?, ?, ?, ?)',
    ).run("session-1", expiresAt, "browser-token", now.getTime(), now.getTime(), "Dahlia", "user-1");
    database.prepare(
      'INSERT INTO "oauth_refresh_token" ("id", "token", "client_id", "session_id", "user_id", "expires_at", "created_at", "scopes") VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    ).run("refresh-1", "refresh-token", "dahlia-macos", "session-1", "user-1", expiresAt, now.getTime(), "[\"all-apis\"]");
    database.prepare(
      'INSERT INTO "oauth_access_token" ("id", "token", "client_id", "session_id", "user_id", "refresh_id", "expires_at", "created_at", "scopes") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    ).run("access-1", "access-token", "dahlia-macos", "session-1", "user-1", "refresh-1", expiresAt, now.getTime(), "[\"all-apis\"]");

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
