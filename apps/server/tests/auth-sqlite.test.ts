import { uuidV7 } from "../src/id";
import { decodeId, encodeId } from "../src/typeid";
import { z } from "zod";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

import { cimd } from "@better-auth/cimd";
import { afterEach, describe, expect, it } from "vitest";

import { createWorkerHandler } from "../src/worker";
import { createApp } from "../src/app";
import { LocalObjectStorage } from "../src/storage/local";
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
  it("retries interrupted Personal initialization without duplicating membership or Vaults", async () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-accounts-owner-"));
    directories.push(directory);
    const path = join(directory, "auth.sqlite");
    const config = { ...testConfig(path) };
    const store = createNodeAuthStore(config);
    await store.migrate();
    const auth = await initializeDahliaAuth(config, store);
    const context = await auth.$context;
    const database = new DatabaseSync(path);
    try {
      database.exec("CREATE TRIGGER fail_initial_owner BEFORE INSERT ON member BEGIN SELECT RAISE(ABORT, 'member insert failed'); END");
      await expect(context.internalAdapter.createUser({ name: "First", email: "first@example.com", emailVerified: true }, { method: "oauth", oauth: { providerId: "google", profile: {} } })).rejects.toThrow();
      const id = String(database.prepare("SELECT id FROM user WHERE email = 'first@example.com'").get()!.id);
      expect(database.prepare("SELECT count(*) AS count FROM vaults").get()).toEqual({ count: 0 });
      expect(database.prepare("SELECT count(*) AS count FROM organization WHERE kind = 'personal'").get()).toEqual({ count: 0 });
      database.exec("DROP TRIGGER fail_initial_owner");
      const identity = { userId: id, workspaceId: `personal:${id}`, source: "accounts" as const };
      expect(await Promise.all([store.ensureIdentityUser(identity), store.ensureIdentityUser(identity)])).toEqual([true, true]);
      expect(database.prepare("SELECT role FROM member WHERE organization_id = ?").all(id)).toEqual([{ role: "owner" }]);
      expect(database.prepare("SELECT vault_id, organization_id FROM vaults WHERE organization_id = ?").all(id)).toEqual([{ vault_id: id, organization_id: id }]);
      expect(database.prepare("SELECT id FROM organization WHERE domain IS NOT NULL").all()).toEqual([]);
      expect(await store.isAdminUser(id)).toBe(true);
    } finally { database.close(); await store.close?.(); }
  });

  it.each(["node", "worker"])("lists all users and non-member organizations for administrators only through %s", async (runtime) => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-admin-directory-"));
    directories.push(directory);
    const path = join(directory, "auth.sqlite");
    const config = { ...testConfig(path), authProvider: "header" as const };
    const store = createNodeAuthStore(config);
    await store.migrate();
    const app = createApp({ config, authStore: store });
    const worker = createWorkerHandler(async () => app);
    const workerFetch = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    const send = (path: string, email = "admin@example.com", origin = config.baseUrl) => {
      const request = new Request(`${config.baseUrl}${path}`, { headers: { "X-Forwarded-Email": email, origin } });
      return runtime === "node" ? app.request(request) : workerFetch(request, {} as Cloudflare.Env, {} as ExecutionContext);
    };
    await send("/api/v1/session");
    await send("/api/v1/session", "member@example.com");
    const raw = new DatabaseSync(path);
    const page = z.object({ items: z.array(z.object({ id: z.string() }).passthrough()), hasMore: z.boolean() });
    try {
      const otherOrg = uuidV7();
      const memberID = String(raw.prepare('SELECT user_id FROM account WHERE account_id = ?').get("member@example.com")!.user_id);
      raw.prepare('INSERT INTO organization (id, name, slug, created_at) VALUES (?, ?, ?, ?)').run(otherOrg, "Other organization", "other", Date.now());
      raw.prepare('INSERT INTO member (id, organization_id, user_id, role, created_at) VALUES (?, ?, ?, ?, ?)').run(uuidV7(), otherOrg, memberID, "owner", Date.now());
      raw.prepare('INSERT INTO team (id, name, organization_id, created_at) VALUES (?, ?, ?, ?)').run(uuidV7(), "Other team", otherOrg, Date.now());
      const organizations = page.parse(await (await send("/api/v1/admin/organizations")).json());
      expect(organizations.items).toContainEqual({ id: encodeId("organization", otherOrg), name: "Other organization", slug: "other", kind: "team", memberCount: 1, teamCount: 1 });
      expect(organizations.hasMore).toBe(false);
      const users = page.parse(await (await send("/api/v1/admin/users")).json());
      expect(users.items.map(({ email, role }) => ({ email, role }))).toEqual([{ email: "admin@example.com", role: "admin" }, { email: "member@example.com", role: "user" }]);
      expect(users.hasMore).toBe(false);
      expect(Object.keys(users.items[0]!).sort()).toEqual(["createdAt", "email", "id", "name", "role"]);
      for (let index = 0; index < 100; index++) raw.prepare('INSERT INTO "user" (id, name, email, email_verified, created_at, updated_at) VALUES (?, ?, ?, 0, ?, ?)').run(uuidV7(), `User ${index}`, `u${index}@example.com`, Date.now(), Date.now());
      const first = page.parse(await (await send("/api/v1/admin/users")).json());
      const second = page.parse(await (await send("/api/v1/admin/users?offset=100")).json());
      expect(first.items).toHaveLength(100); expect(first.hasMore).toBe(true);
      expect(second.items).toHaveLength(2); expect(second.hasMore).toBe(false);
      expect(new Set([...first.items, ...second.items].map((user) => user.id)).size).toBe(102);
      for (const kind of ["users", "organizations"]) {
        expect((await send(`/api/v1/admin/${kind}`, "member@example.com")).status).toBe(403);
        expect((await send(`/api/v1/admin/${kind}?offset=-1`)).status).toBe(400);
      }
    } finally { raw.close(); await store.close?.(); }
  });

  it("creates one external organization owner under concurrent first header access", async () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-header-concurrent-"));
    directories.push(directory);
    const path = join(directory, "header.sqlite");
    const config = { ...testConfig(path), authProvider: "header" as const };
    const store = createNodeAuthStore(config);
    await store.migrate();
    const app = createApp({ config, authStore: store, objectStorage: new LocalObjectStorage(join(directory, "storage")) });
    const responses = await Promise.all(["first", "second"].map((user) => Promise.resolve().then(() =>
      app.request("/api/v1/session", { headers: {
        "X-Forwarded-Email": `${user}@example.com`,
        "X-Forwarded-User": user,
      } }))));
    expect(responses.map(({ status }) => status)).toEqual([200, 200]);
    const database = new DatabaseSync(path);
    expect(database.prepare("SELECT count(*) AS count FROM organization WHERE domain = 'example.com'").get()).toEqual({ count: 1 });
    expect(database.prepare("SELECT count(*) AS count FROM member WHERE organization_id = (SELECT id FROM organization WHERE domain = 'example.com') AND role = 'owner'").get())
      .toEqual({ count: 1 });
    expect(database.prepare("SELECT count(*) AS count FROM team WHERE id = '01990ab0-0000-7000-8000-000000000002'").get()).toEqual({ count: 0 });
    expect(database.prepare("SELECT count(*) AS count FROM team_member WHERE team_id = '01990ab0-0000-7000-8000-000000000002'").get())
      .toEqual({ count: 0 });
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
      objectStorage: new LocalObjectStorage(join(directory, "storage")),
    });
    expect((await app.request("/api/auth/admin/list-users")).status).toBe(401);

    const first = await app.request("/api/v1/session", { headers: {
      "X-Forwarded-Email": "User@Example.com",
      "X-Forwarded-Preferred-Username": "First Name",
      "X-Forwarded-User": "stable-user-id",
    } });
    expect(first.status).toBe(200);

    const database = new DatabaseSync(path);
    const userID = decodeId("user", z.object({ user: z.object({ id: z.string() }) }).parse(await first.json()).user.id);
    expect(database.prepare(
      'SELECT id, name, email, email_verified, role FROM "user" WHERE id = ?',
    ).get(userID)).toEqual({
      id: userID,
      name: "First Name",
      email: "user@example.com",
      email_verified: 1,
      role: "admin",
    });
    const organizationId = String(database.prepare("SELECT id FROM organization WHERE domain = 'example.com'").get()!.id);
    expect(database.prepare('SELECT name, domain FROM organization WHERE id = ?').get(organizationId))
      .toEqual({ name: "example.com", domain: "example.com" });
    expect(database.prepare('SELECT user_id, role FROM member WHERE organization_id = ?').get(organizationId))
      .toEqual({ user_id: userID, role: "owner" });
    expect(database.prepare('SELECT id, name, organization_id FROM team WHERE id = ?').get("external-default"))
      .toBeUndefined();
    expect(database.prepare('SELECT user_id FROM team_member WHERE team_id = ?').get("external-default"))
      .toBeUndefined();

    const updated = await app.request("/api/v1/session", { headers: {
      "X-Forwarded-Email": "renamed@example.com",
      "X-Forwarded-Preferred-Username": "Renamed User",
      "X-Forwarded-User": "stable-user-id",
    } });
    expect(updated.status).toBe(200);
    expect(database.prepare('SELECT name, email FROM "user" WHERE id = ?').get(userID))
      .toEqual({ name: "First Name", email: "user@example.com" });
    expect(decodeId("user", z.object({ user: z.object({ id: z.string() }) }).parse(await updated.json()).user.id)).not.toBe(userID);

    const conflict = await app.request("/api/v1/session", { headers: {
      "X-Forwarded-Email": "renamed@example.com",
      "X-Forwarded-User": "different-user-id",
    } });
    expect(conflict.status).toBe(200);
    expect(database.prepare('SELECT count(*) AS count FROM "user"').get()).toEqual({ count: 2 });

    expect((await app.request("/api/v1/session", { headers: {
      "X-Forwarded-Email": "second@example.com",
      "X-Forwarded-User": "second-user-id",
    } })).status).toBe(200);
    const secondID = String(database.prepare("SELECT user_id FROM account WHERE account_id = ?").get("second@example.com")!.user_id);
    expect(database.prepare('SELECT role FROM member WHERE organization_id = ? AND user_id = ?')
      .get(organizationId, secondID)).toEqual({ role: "member" });
    expect(database.prepare('SELECT 1 FROM team_member WHERE team_id = ? AND user_id = ?')
      .get("01990ab0-0000-7000-8000-000000000002", secondID)).toBeUndefined();
    expect((await app.request("/api/v1/session", { headers: {
      "X-Forwarded-Email": "renamed@example.com",
      "X-Forwarded-Preferred-Username": "Renamed User",
      "X-Forwarded-User": "stable-user-id",
    } })).status).toBe(200);
    expect(database.prepare('SELECT user_id FROM team_member WHERE team_id = ?').get("external-default"))
      .toBeUndefined();

    const auth = await initializeDahliaAuth(config, store);
    const session = await (await auth.$context).internalAdapter.createSession(userID);
    const deleteResponse = await auth.handler(new Request(`${config.baseUrl}/api/auth/delete-user`, {
      method: "POST", headers: { "content-type": "application/json", origin: config.baseUrl,
        "X-Forwarded-Email": "renamed@example.com", "X-Forwarded-User": "stable-user-id", cookie: `better-auth.session_token=${session.token}` }, body: "{}",
    }));
    expect(deleteResponse.status).not.toBe(200);
    expect(database.prepare('SELECT 1 FROM "user" WHERE id = ?').get(userID)).toBeDefined();

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
      name: "20260912180000_runtime_support",
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
      objectStorage: new LocalObjectStorage(join(directory, "storage")),
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
    expect((await app.request("/api/auth/organization/list")).status).toBe(401);
    const unauthorizedAdmin = await app.request("/api/auth/admin/list-users");
    expect(unauthorizedAdmin.status, await unauthorizedAdmin.text()).toBe(401);
    expect(database.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('organization', 'member', 'invitation', 'team', 'team_member') ORDER BY name").all())
      .toEqual([{ name: "invitation" }, { name: "member" }, { name: "organization" }, { name: "team" }, { name: "team_member" }]);
    expect(database.prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'member_user_organization_idx'").get())
      .toEqual({ name: "member_user_organization_idx" });
    expect(database.prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'team_member_user_team_idx'").get())
      .toEqual({ name: "team_member_user_team_idx" });
    expect(database.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'search_documents_fts'",
    ).all()).toEqual([{ name: "search_documents_fts" }]);

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
    const firstAdmin = await store.resolveHeaderUser({ userId: "first-admin", workspaceId: "personal:first-admin", source: "header", email: "first-admin@example.com" });
    const secondAdmin = await store.resolveHeaderUser({ userId: "second-admin", workspaceId: "personal:second-admin", source: "header", email: "second-admin@example.com" });
    await store.addAdminUser("first-admin@example.com");
    expect(await store.addAdminUser("second-admin@example.com")).toMatchObject({ id: secondAdmin! });
    expect(await store.isAdminUser(secondAdmin!)).toBe(true);
    expect(await store.listAdminUsers()).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: firstAdmin! }), expect.objectContaining({ id: secondAdmin! }),
    ]));
    expect(await store.removeAdminUser(secondAdmin!)).toBe("removed");

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
