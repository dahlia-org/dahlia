import { Client } from "pg";
import { makeSignature } from "better-auth/crypto";
import { encryptionConfig } from "../src/encryption/crypto";
import { AUTH_MAX_REQUEST_BYTES, createApp } from "../src/app";
import { encodeId } from "../src/typeid";
import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { initializeDahliaAuth } from "../src/auth/better-auth";
import { IdentityService, type Identity } from "../src/auth/identity";
import { uuidV7 } from "../src/id";
import type { SyncTransaction } from "../src/sync/types";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0)) await cleanup(); });
async function setup(authProvider: "header" | "accounts" = "header", authProviderId?: string, authHeader = "X-Forwarded-Email") {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-organizations-"));
  const path = join(directory, "test.sqlite");
  const postgresUrl = process.env.TEST_ORGANIZATION_DATABASE_URL;
  const suffix = uuidV7();
  const config = { authProvider, authProviderId, googleClientId: "test", googleClientSecret: "test",
    encryption: encryptionConfig({ DAHLIA_ENCRYPTION_MASTER_KEY_1: btoa("a".repeat(32)), DAHLIA_ENCRYPTION_ACTIVE_KEY_ID: "1" }), authHeader, databaseType: postgresUrl ? "postgres" as const : "sqlite" as const,
    databaseUrl: postgresUrl ?? `file:${path}`, baseUrl: "http://localhost:3000", oauthRedirectUris: [], maxRequestBytes: 1_000_000,
    betterAuthSecret: "test-organization-secret-at-least-32-characters" };
  const store = createNodeApplicationStore(config);
  await store.migrate();
  const auth = await initializeDahliaAuth(config, store);
  const raw = postgresUrl ? new Client({ connectionString: postgresUrl }) : new DatabaseSync(path);
  if (raw instanceof Client) {
    await raw.connect();
    await raw.query("SET search_path TO auth, app, search, public");
    await raw.query("SET app.maintenance = 'authorization'");
  } else raw.exec("PRAGMA foreign_keys = ON");
  const read = async (statement: string, ...parameters: string[]) => {
    if (!(raw instanceof Client)) return raw.prepare(statement).all(...parameters);
    let index = 0;
    return (await raw.query<Record<string, string>>(statement.replace(/\?/g, () => `$${++index}`), parameters)).rows;
  };
  cleanups.push(async () => { if (raw instanceof Client) await raw.end(); else raw.close(); await store.close?.(); rmSync(directory, { recursive: true }); });
  const user = async (address: string) => {
    const email = address.replace("@", `+${suffix}@${suffix}.`);
    const header: Identity = { userId: email, email, name: email, source: "header", workspaceId: email };
    const context = await auth.$context;
    const userId = authProvider === "header" ? await store.resolveHeaderUser(header)
      : (await context.internalAdapter.createUser({ email, name: email, emailVerified: true }, { method: "oauth", oauth: { providerId: "google", profile: {} } })).id;
    if (!userId) throw new Error("user missing");
    const identity = { ...header, userId, workspaceId: `personal:${userId}` };
    await store.ensureIdentityUser(identity);
    return identity;
  };
  const headers = async (actor: Identity) => {
    if (authProvider === "accounts") {
      const context = await auth.$context;
      const session = await context.internalAdapter.createSession(actor.userId);
      return new Headers({ origin: config.baseUrl, cookie: `${context.authCookies.sessionToken.name}=${encodeURIComponent(`${session.token}.${await makeSignature(session.token, config.betterAuthSecret)}`)}` });
    }
    const response = await auth.handler(new Request(`${config.baseUrl}/api/auth/header/sign-in`, { method: "POST", headers: { [config.authHeader]: actor.email!, origin: config.baseUrl } }));
    expect(response.status).toBe(200);
    return new Headers({ [config.authHeader]: actor.email!, origin: config.baseUrl, cookie: response.headers.getSetCookie().map((v) => v.split(";")[0]).join("; ") });
  };
  return { store, auth, read, user, config, headers };
}
function tx(vaultId: string, operations: SyncTransaction["operations"]): SyncTransaction {
  return { schemaVersion: 3, id: uuidV7(), vaultId, operations, requestHash: uuidV7(), createdAt: new Date() };
}
async function teamVault(env: Awaited<ReturnType<typeof setup>>, actor: Identity, encryption: "none" | "server" = "none") {
  const { store, auth, headers } = env;
  const org = await auth.api.createOrganization({ headers: await headers(actor), body: { name: "Team", slug: `team-${uuidV7()}` } });
  const vaultId = uuidV7();
  await store.sync.withIdentity(actor, (scoped) => scoped.commitTransaction(tx(vaultId, [{ id: uuidV7(), entity: "vault", action: "create", entityId: vaultId,
    baseRevision: null, data: { organizationId: org.id, encryption, name: "Team vault", createdAt: new Date() } }])));
  return { org, vaultId };
}

describe("Organization-owned Vaults", () => {
  it.each([true, false])("rejects oversized organization JSON before validation (content length: %s)", async (knownLength) => {
    const { store, auth, config, user, read } = await setup();
    const actor = await user("creator@example.com");
    const app = createApp({ config, auth, authStore: store });
    const body = new TextEncoder().encode(JSON.stringify({ name: "x".repeat(AUTH_MAX_REQUEST_BYTES), slug: "oversized" }));
    const headers = new Headers({ [config.authHeader]: actor.email!, "content-type": "application/json" });
    if (knownLength) headers.set("content-length", String(body.length));
    const response = await app.request("/api/v1/organizations", { method: "POST", headers,
      body: knownLength ? body : new ReadableStream({ start(controller) { controller.enqueue(body); controller.close(); } }),
      ...(!knownLength ? { duplex: "half" } : {}) });
    expect(response.status).toBe(413);
    expect(await response.json()).toMatchObject({ status: 413, code: "request_too_large" });
    expect(await read("SELECT id FROM organization WHERE slug = ?", "oversized")).toEqual([]);
  });

  it.each([undefined, "databricks"])("uses the configured Header provider ID %s without replacing existing accounts", async (authProviderId) => {
    const { read, user, headers } = await setup("header", authProviderId);
    const actor = await user("provider@example.com");
    await headers(actor);
    const accounts = await read("SELECT id, user_id, issuer, account_id, provider_id FROM account WHERE user_id = ?", actor.userId);
    expect(accounts).toEqual([expect.objectContaining({ user_id: actor.userId, account_id: actor.email, provider_id: authProviderId ?? "external" })]);
    await read("UPDATE account SET provider_id = ? WHERE user_id = ?", "header", actor.userId);
    await headers(actor);
    expect(await read("SELECT id, user_id, issuer, account_id, provider_id FROM account WHERE user_id = ?", actor.userId)).toEqual(accounts);
  });

  it.each(["X-Forwarded-Email", "Cf-Access-Authenticated-User-Email"])("uses only %s for API and browser identity", async (authHeader) => {
    const { store, auth, config, read } = await setup("header", "databricks", authHeader);
    const service = new IdentityService(config, auth, async (identity) => {
      const userId = await store.resolveHeaderUser(identity);
      if (!userId) return null;
      const projected = { ...identity, userId, workspaceId: `personal:${userId}` };
      return await store.ensureIdentityUser(projected) ? projected : null;
    });
    const domain = `${uuidV7()}.example.com`;
    const email = `user@${domain}`;
    const requestHeaders = new Headers({ [authHeader]: `  ${email.toUpperCase()}  `, "X-Forwarded-User": "ignored", origin: config.baseUrl });
    const actor = await service.fromBrowser(new Request(config.baseUrl, { headers: requestHeaders }));
    expect(actor.email).toBe(email);
    expect(actor.userId).not.toBe(email);
    requestHeaders.set("X-Forwarded-User", "different");
    const response = await auth.handler(new Request(`${config.baseUrl}/api/auth/header/sign-in`, { method: "POST", headers: requestHeaders }));
    expect(response.status).toBe(200);
    requestHeaders.set("cookie", response.headers.getSetCookie().map((v) => v.split(";")[0]).join("; "));
    expect((await service.fromBrowser(new Request(config.baseUrl, { headers: requestHeaders }))).userId).toBe(actor.userId);
    expect(await read("SELECT account_id, provider_id FROM account WHERE user_id = ?", actor.userId)).toEqual([{ account_id: email, provider_id: "databricks" }]);
    const orgs = await read("SELECT id, name FROM organization WHERE domain = ?", domain);
    expect(orgs).toHaveLength(1);
    expect(orgs[0]!.name).toBe(domain);
    expect(await read("SELECT role FROM member WHERE organization_id = ? AND user_id = ?", String(orgs[0]!.id), actor.userId)).toEqual([{ role: "owner" }]);
    for (const invalid of [null, "invalid", "a@@example.com", "a@example.com,b@example.com"]) {
      const rejected = new Headers({ "X-Forwarded-User": email, origin: config.baseUrl });
      if (authHeader !== "X-Forwarded-Email") rejected.set("X-Forwarded-Email", email);
      if (invalid !== null) rejected.set(authHeader, invalid);
      await expect(service.fromBrowser(new Request(config.baseUrl, { headers: rejected }))).rejects.toThrow("valid email");
      expect((await auth.handler(new Request(`${config.baseUrl}/api/auth/header/sign-in`, { method: "POST", headers: rejected }))).status).toBe(401);
    }
    expect(await read("SELECT id FROM account WHERE account_id = ?", email)).toHaveLength(1);
  });

  it("keeps domains distinct and prevents clients from claiming or changing them", async () => {
    const { auth, read, user, headers, store } = await setup();
    const [a, b, c] = await Promise.all([user("alice@example.com"), user("bob@example.com"), user("carol@sub.example.com")]);
    const domain = a.email!.split("@")[1]!;
    const [org] = await read("SELECT id FROM organization WHERE domain = ?", domain);
    const orgId = String(org!.id);
    const members = await read("SELECT role FROM member WHERE organization_id = ?", orgId);
    expect(members.filter((m) => m.role === "owner")).toHaveLength(1);
    expect(members.filter((m) => m.role === "member")).toHaveLength(1);
    const [other] = await read("SELECT id FROM organization WHERE domain = ?", c.email!.split("@")[1]!);
    expect(other!.id).not.toBe(orgId);
    const [owner] = await read("SELECT user_id FROM member WHERE organization_id = ? AND role = 'owner'", orgId);
    const actor = owner!.user_id === a.userId ? a : b;
    const removed = actor.userId === a.userId ? b : a;
    const ah = await headers(actor);
    const claimed = await auth.handler(new Request(`${(await auth.$context).baseURL}/organization/create`, { method: "POST", headers: { ...Object.fromEntries(ah), "content-type": "application/json" }, body: JSON.stringify({ name: "Claim", slug: `claim-${uuidV7()}`, domain: `claim-${domain}` }) }));
    expect(claimed.status).toBe(200);
    expect(await read("SELECT id FROM organization WHERE domain = ?", `claim-${domain}`)).toHaveLength(0);
    const updated = await auth.handler(new Request(`${(await auth.$context).baseURL}/organization/update`, { method: "POST", headers: { ...Object.fromEntries(ah), "content-type": "application/json" }, body: JSON.stringify({ organizationId: orgId, data: { name: "Unclaimed", domain: `changed-${domain}` } }) }));
    expect(updated.status).toBe(200);
    await expect(store.organizations.transaction(async (database) => {
      await database((await auth.$context).options).update({ model: "organization", where: [{ field: "id", value: orgId }], update: { domain: `changed-${domain}` } });
    })).rejects.toThrow("organization_domain_immutable");
    expect(await read("SELECT domain FROM organization WHERE id = ?", orgId)).toEqual([{ domain }]);
    await auth.api.updateOrganization({ headers: ah, body: { organizationId: orgId, data: { name: "Renamed" } } });
    await auth.api.removeMember({ headers: ah, body: { organizationId: orgId, memberIdOrEmail: removed.email! } });
    await headers(removed);
    expect(await read("SELECT id FROM member WHERE organization_id = ? AND user_id = ?", orgId, removed.userId)).toHaveLength(0);
    expect(await store.sync.withIdentity(removed, (scoped) => scoped.getVault(actor.userId))).toBeNull();
  });

  it("initializes Personal once and joins a domain only at user creation", async () => {
    const { store, auth, headers, read, user } = await setup();
    const [a, same] = await Promise.all([user("alice@example.com"), user("alice@example.com")]);
    expect(a.userId).toBe(same.userId);
    expect((await read("SELECT kind, slug FROM organization WHERE id = ?", a.userId))[0]).toEqual({ kind: "personal", slug: `personal-${a.userId}` });
    expect(await read("SELECT role FROM vault_permissions WHERE vault_id = ?", a.userId)).toEqual([{ role: "admin" }]);
    const domain = a.email!.split("@")[1]!;
    const [org] = await read("SELECT id FROM organization WHERE domain = ?", domain);
    const orgId = String(org!.id);
    expect(await read("SELECT role FROM member WHERE organization_id = ?", orgId)).toEqual([{ role: "owner" }]);
    const b = await user("bob@example.com");
    await auth.api.leaveOrganization({ headers: await headers(b), body: { organizationId: orgId } });
    await store.ensureIdentityUser(b);
    await user("bob@example.com");
    expect(await read("SELECT id FROM member WHERE organization_id = ? AND user_id = ?", orgId, b.userId)).toHaveLength(0);
    await auth.api.deleteOrganization({ headers: await headers(a), body: { organizationId: orgId } });
    await user("alice@example.com");
    expect(await read("SELECT id FROM organization WHERE domain = ?", domain)).toHaveLength(0);
    const c = await user("carol@example.com");
    const [replacement] = await read("SELECT id FROM organization WHERE domain = ?", domain);
    expect(replacement!.id).not.toBe(orgId);
    expect(await read("SELECT user_id, role FROM member WHERE organization_id = ?", String(replacement!.id))).toEqual([{ user_id: c.userId, role: "owner" }]);
    await expect(store.sync.withIdentity(a, (scoped) => scoped.commitTransaction(tx(a.userId, [{ id: uuidV7(), entity: "vault", action: "reset", entityId: a.userId, baseRevision: 1, data: {} }])))).rejects.toThrow("personal_vault_immutable");
  });

  it("rolls back failed domain enrollment and retries the complete registration", async () => {
    const { read, user, config } = await setup();
    const postgres = config.databaseType === "postgres";
    const address = `interrupted-${uuidV7()}@example.com`;
    if (postgres) {
      await read("CREATE FUNCTION auth.fail_domain_member() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.organization_id <> NEW.user_id THEN RAISE EXCEPTION 'domain enrollment failed'; END IF; RETURN NEW; END $$");
      await read("CREATE TRIGGER fail_domain_member BEFORE INSERT ON auth.member FOR EACH ROW EXECUTE FUNCTION auth.fail_domain_member()");
    } else await read("CREATE TRIGGER fail_domain_member BEFORE INSERT ON member WHEN NEW.organization_id <> NEW.user_id BEGIN SELECT RAISE(ABORT, 'domain enrollment failed'); END");
    try {
      await expect(user(address)).rejects.toThrow();
      expect(await read('SELECT id FROM "user" WHERE email LIKE ?', `${address.split("@")[0]}+%@%`)).toHaveLength(0);
    } finally {
      await read(postgres ? "DROP TRIGGER fail_domain_member ON auth.member" : "DROP TRIGGER fail_domain_member");
      if (postgres) await read("DROP FUNCTION auth.fail_domain_member()");
    }
    const a = await user(address);
    expect((await user(address)).userId).toBe(a.userId);
    expect(await read("SELECT id FROM member WHERE user_id = ?", a.userId)).toHaveLength(2);
    expect(await read("SELECT vault_id FROM vaults WHERE organization_id = ?", a.userId)).toEqual([{ vault_id: a.userId }]);
  });

  it("does not automatically enroll Google users in domain organizations", async () => {
    const { user, read } = await setup("accounts");
    const a = await user("google@example.com");
    expect(await read("SELECT id FROM organization WHERE domain = ?", a.email!.split("@")[1]!)).toHaveLength(0);
    expect(await read("SELECT organization_id FROM member WHERE user_id = ?", a.userId)).toEqual([{ organization_id: a.userId }]);
  });

  it.each([undefined, "native-admin-test-password"])("projects native Header user provisioning with password %s", async (password) => {
    const { store, auth, config, read, user, headers } = await setup("header", "databricks");
    const administrator = await user("administrator@example.com");
    await store.addAdminUser(administrator.email!);
    const email = `created-${uuidV7()}@${uuidV7()}.example.com`;
    const created = await auth.api.createUser({ headers: await headers(administrator), body: { email, name: "Created", password } });
    const app = createApp({ config, auth, authStore: store });
    const response = await app.request("/api/v1/session", { headers: { [config.authHeader]: email } });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ user: { id: encodeId("user", created.user.id) } });
    expect(await read("SELECT user_id, provider_id FROM account WHERE issuer = ? AND account_id = ?", "urn:dahlia:header", email))
      .toEqual([{ user_id: created.user.id, provider_id: "databricks" }]);
    expect(await read("SELECT id FROM organization WHERE id = ?", created.user.id)).toHaveLength(1);
    expect(await read("SELECT id FROM member WHERE user_id = ?", created.user.id)).toHaveLength(2);
    const credentials = await read("SELECT id FROM account WHERE user_id = ? AND provider_id = ?", created.user.id, "credential");
    expect(credentials).toHaveLength(password ? 1 : 0);
  });

  it("does not adopt an existing accounts-mode user by matching Header email", async () => {
    const { store, user, read } = await setup("accounts");
    const actor = await user("existing@example.com");
    expect(await store.resolveHeaderUser({ ...actor, source: "header" })).toBeNull();
    expect(await read("SELECT id FROM account WHERE user_id = ? AND issuer = ?", actor.userId, "urn:dahlia:header")).toEqual([]);
  });

  it("rejects native Header email edits without changing the user or identity mapping", async () => {
    const { store, auth, config, read, user, headers } = await setup();
    const administrator = await user("administrator@example.com");
    await store.addAdminUser(administrator.email!);
    const target = await user("target@example.com");
    const actorHeaders = await headers(administrator);
    const app = createApp({ config, auth, authStore: store });
    const data = { email: `changed-${uuidV7()}@example.com`, name: "Must roll back" };
    await expect(auth.api.adminUpdateUser({ headers: actorHeaders, body: { userId: target.userId, data } }))
      .rejects.toThrow("header_email_change_disabled");
    const httpHeaders = new Headers(actorHeaders);
    httpHeaders.set("content-type", "application/json");
    const rejected = await app.request("/api/auth/admin/update-user", { method: "POST", headers: httpHeaders,
      body: JSON.stringify({ userId: encodeId("user", target.userId), data }) });
    expect(rejected.status).toBe(403);
    expect(await read('SELECT email, name FROM "user" WHERE id = ?', target.userId)).toEqual([{ email: target.email, name: target.name }]);
    expect(await read("SELECT account_id FROM account WHERE user_id = ?", target.userId)).toEqual([{ account_id: target.email }]);
    expect((await app.request("/api/v1/session", { headers: { [config.authHeader]: target.email! } })).status).toBe(200);
  });

  it.each(["header", "accounts"] as const)("retains the last administrator across native and custom mutations in %s mode", async (mode) => {
    const { store, auth, config, read, user, headers } = await setup(mode);
    await user("first@example.com");
    const actor = await user("administrator@example.com");
    await store.addAdminUser(actor.email!);
    for (const other of await store.listAdminUsers()) {
      if (other.id !== actor.userId) expect(await store.removeAdminUser(other.id)).toBe("removed");
    }
    const actorHeaders = await headers(actor);
    const app = createApp({ config, auth, authStore: store });
    const original = await read('SELECT role, name FROM "user" WHERE id = ?', actor.userId);
    for (const channel of ["api", "http"] as const) {
      for (const endpoint of ["set-role", "update-user"] as const) {
        if (channel === "api") {
          const operation = endpoint === "set-role"
            ? auth.api.setRole({ headers: actorHeaders, body: { userId: actor.userId, role: "user" } })
            : auth.api.adminUpdateUser({ headers: actorHeaders, body: { userId: actor.userId, data: { role: "user", name: "must roll back" } } });
          await expect(operation).rejects.toThrow("last_admin");
        } else {
          const requestHeaders = new Headers(actorHeaders);
          requestHeaders.set("content-type", "application/json");
          const response = await app.request(`/api/auth/admin/${endpoint}`, { method: "POST", headers: requestHeaders,
            body: JSON.stringify({ userId: encodeId("user", actor.userId), ...(endpoint === "set-role" ? { role: "user" } : { data: { role: "user", name: "must roll back" } }) }) });
          expect(response.status).toBe(409);
          expect(await response.json()).toMatchObject({ code: "last_admin" });
        }
        expect(await read('SELECT role, name FROM "user" WHERE id = ?', actor.userId)).toEqual(original);
      }
    }
    expect(await store.removeAdminUser(actor.userId)).toBe("last_admin");
    const created = await auth.api.createUser({ headers: actorHeaders, body: { email: `created-${uuidV7()}@example.com`, name: "Created" } });
    expect(await read("SELECT id FROM organization WHERE id = ?", created.user.id)).toHaveLength(1);
    await auth.api.setRole({ headers: actorHeaders, body: { userId: created.user.id, role: "admin" } });
    expect(await store.isAdminUser(created.user.id)).toBe(true);
    const outcomes = await Promise.all([
      auth.api.setRole({ headers: actorHeaders, body: { userId: actor.userId, role: "user" } })
        .then(() => "removed", (error: Error) => error.message),
      store.removeAdminUser(created.user.id),
    ]);
    expect(outcomes.sort()).toEqual(["last_admin", "removed"]);
    expect(await store.listAdminUsers()).toHaveLength(1);
  });

  it.each(["header", "accounts"] as const)("preserves credentials and sessions when account deletion is rejected in %s mode", async (mode) => {
    const { store, auth, config, read, user, headers } = await setup(mode);
    const administrator = await user("administrator@example.com");
    await store.addAdminUser(administrator.email!);
    const administratorHeaders = await headers(administrator);
    const app = createApp({ config, auth, authStore: store });
    for (const channel of ["api", "http"] as const) {
      const target = await user(`${channel}@example.com`);
      if (mode === "accounts") {
        await (await auth.$context).internalAdapter.createAccount({ userId: target.userId, providerId: "google", issuer: "https://accounts.google.com", accountId: target.email! });
      }
      const targetHeaders = await headers(target);
      const accounts = await read('SELECT id FROM account WHERE user_id = ?', target.userId);
      const sessions = await read('SELECT id FROM session WHERE user_id = ?', target.userId);
      expect(accounts).toHaveLength(1);
      expect(sessions).toHaveLength(1);
      if (channel === "api") {
        await expect(auth.api.removeUser({ headers: administratorHeaders, body: { userId: target.userId } })).rejects.toThrow("account_delete_disabled");
      } else {
        const requestHeaders = new Headers(administratorHeaders);
        requestHeaders.set("content-type", "application/json");
        const response = await app.request("/api/auth/admin/remove-user", { method: "POST", headers: requestHeaders,
          body: JSON.stringify({ userId: encodeId("user", target.userId) }) });
        expect(response.status).toBe(403);
        expect(await response.json()).toMatchObject({ message: "account_delete_disabled" });
      }
      expect(await read('SELECT id FROM "user" WHERE id = ?', target.userId)).toHaveLength(1);
      expect(await read('SELECT id FROM account WHERE user_id = ?', target.userId)).toEqual(accounts);
      expect(await read('SELECT id FROM session WHERE user_id = ?', target.userId)).toEqual(sessions);
      expect((await auth.api.getSession({ headers: targetHeaders }))?.user.id).toBe(target.userId);
      // Self deletion stays disabled before it reaches the same destructive adapter calls.
      await expect(auth.api.deleteUser({ headers: targetHeaders, body: {} })).rejects.toThrow();
      expect(await read('SELECT id FROM account WHERE user_id = ?', target.userId)).toEqual(accounts);
      expect(await read('SELECT id FROM session WHERE user_id = ?', target.userId)).toEqual(sessions);
      if (mode === "header") expect((await auth.api.getSession({ headers: await headers(target) }))?.user.id).toBe(target.userId);
    }
  });

  it("gives Editors content writes on the shared delta while reserving management for Admins", async () => {
    const env = await setup();
    const { store, user } = env;
    const a = await user("alice@example.com"), b = await user("bob@example.com"), c = await user("carol@example.com");
    const { org, vaultId } = await teamVault(env, a);
    await store.sync.withIdentity(a, (scoped) => scoped.putPermission(vaultId, "user", b.userId, "editor"));
    await store.sync.withIdentity(a, (scoped) => scoped.putPermission(vaultId, "user", c.userId, "viewer"));
    const projectId = uuidV7();
    const receipt = await store.sync.withIdentity(b, (scoped) => scoped.commitTransaction(tx(vaultId, [{ id: uuidV7(), entity: "project", action: "create", entityId: projectId,
      baseRevision: null, data: { name: "Editor project", description: "", parentProjectId: null, projectType: "internal", createdAt: new Date() } }])));
    for (const actor of [a, b, c]) {
      expect((await store.sync.withIdentity(actor, (scoped) => scoped.listChanges(vaultId, 0, 100, 100))).some((item) => item.transactionId === receipt.id)).toBe(true);
    }
    await expect(store.sync.withIdentity(b, (scoped) => scoped.commitTransaction(tx(vaultId, [{ id: uuidV7(), entity: "vault", action: "update", entityId: vaultId,
      baseRevision: 1, data: { name: "Denied" } }])))).rejects.toThrow("vault_admin_required");
    expect(await store.sync.withIdentity(b, (scoped) => scoped.putPermission(vaultId, "user", c.userId, "admin"))).toBe(false);
    for (const preservePermissions of [false, true]) {
      await expect(store.sync.withIdentity(b, (scoped) => scoped.commitTransaction(tx(vaultId, [{ id: uuidV7(), entity: "vault", action: "reset", entityId: vaultId,
        baseRevision: 1, data: { preservePermissions } }])))).rejects.toThrow("vault_admin_required");
    }
    const { vaultId: managedVaultId } = await teamVault(env, a);
    await store.sync.withIdentity(a, (scoped) => scoped.putPermission(managedVaultId, "user", b.userId, "admin"));
    for (const [sourceVaultId, destinationVaultId] of [[vaultId, managedVaultId], [managedVaultId, vaultId]]) {
      await expect(store.sync.withIdentity(b, (scoped) => scoped.transferVault({ sourceVaultId: sourceVaultId!, destinationVaultId: destinationVaultId!,
        sourceRevision: 1, destinationRevision: 1, audienceHash: "unused", idempotencyKey: uuidV7(), requestHash: uuidV7() }))).rejects.toThrow("vault_not_found");
    }
    await expect(store.sync.withIdentity(a, (scoped) => scoped.putPermission(vaultId, "user", a.userId, "editor"))).rejects.toThrow();
    expect((await store.sync.withIdentity(a, (scoped) => scoped.getVault(vaultId)))?.organizationId).toBe(org.id);
    expect((await store.sync.withIdentity(a, (scoped) => scoped.listSnapshot(vaultId, undefined, 100))).items[0]?.record).not.toHaveProperty("createdBy");
  });

  for (const mode of ["header", "accounts"] as const) it(`uses the same invitations, teams, and atomic Admin guards with ${mode}`, async () => {
    const env = await setup(mode);
    const { auth, store, read, user, headers } = env;
    const a = await user("alice@example.com"), b = await user("bob@example.com");
    const { org, vaultId } = await teamVault(env, a);
    const ah = await headers(a), bh = await headers(b);
    const invitation = await auth.api.createInvitation({ headers: ah, body: { email: b.email!, role: "member", organizationId: org.id } });
    await auth.api.acceptInvitation({ headers: bh, body: { invitationId: invitation.id } });
    const team = await auth.api.createTeam({ headers: ah, body: { name: "Editors", organizationId: org.id } });
    expect(await read("SELECT user_id FROM team_member WHERE team_id = ?", team.id)).toEqual([{ user_id: a.userId }]);
    await auth.api.addTeamMember({ headers: ah, body: { teamId: team.id, userId: b.userId, organizationId: org.id } });
    for (const principalType of ["user", "organization", "team"] as const) {
      const principalId = principalType === "user" ? b.userId : principalType === "organization" ? org.id : team.id;
      for (const role of ["viewer", "editor", "admin"] as const) {
        await store.sync.withIdentity(a, (scoped) => scoped.putPermission(vaultId, principalType, principalId, role));
        expect((await store.sync.withIdentity(b, (scoped) => scoped.getVault(vaultId)))?.role).toBe(role);
        const projectId = uuidV7();
        const write = () => store.sync.withIdentity(b, (scoped) => scoped.commitTransaction(tx(vaultId, [{ id: uuidV7(), entity: "project", action: "create", entityId: projectId, baseRevision: null,
          data: { name: projectId, description: "", parentProjectId: null, createdAt: new Date() } }])));
        if (role === "viewer") await expect(write()).rejects.toThrow();
        else {
          await write();
          await store.sync.withIdentity(b, (scoped) => scoped.commitTransaction(tx(vaultId, [{ id: uuidV7(), entity: "project", action: "delete", entityId: projectId, baseRevision: 1, data: {} }])));
        }
      }
      await store.sync.withIdentity(a, (scoped) => scoped.deletePermission(vaultId, principalType, principalId));
    }
    // Two individually valid demotions cannot remove both remaining Admins.
    await store.sync.withIdentity(a, (scoped) => scoped.putPermission(vaultId, "user", b.userId, "admin"));
    const results = await Promise.allSettled([a, b].map((actor) => store.sync.withIdentity(actor, (scoped) => scoped.putPermission(vaultId, "user", actor.userId, "editor"))));
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(await read("SELECT role FROM vault_permissions WHERE vault_id = ? AND role = 'admin'", vaultId)).toHaveLength(1);
    const adminId = (await read("SELECT principal_id FROM vault_permissions WHERE vault_id = ? AND role = 'admin'", vaultId))[0]!.principal_id;
    const adminActor = adminId === a.userId ? a : b;
    await store.sync.withIdentity(adminActor, (scoped) => scoped.putPermission(vaultId, "team", team.id, "admin"));
    await store.sync.withIdentity(adminActor, (scoped) => scoped.deletePermission(vaultId, "user", adminActor.userId));
    await expect(auth.api.removeTeam({ headers: ah, body: { teamId: team.id, organizationId: org.id } })).rejects.toThrow();
    const removals = await Promise.allSettled([a, b].map((actor) => auth.api.removeTeamMember({
      headers: ah, body: { teamId: team.id, userId: actor.userId, organizationId: org.id },
    })));
    expect(removals.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const remaining = await read("SELECT user_id FROM team_member WHERE team_id = ?", team.id);
    expect(remaining).toHaveLength(1);
    await auth.api.addTeamMember({ headers: ah, body: { teamId: team.id, organizationId: org.id,
      userId: remaining[0]!.user_id === a.userId ? b.userId : a.userId } });
    await auth.api.leaveOrganization({ headers: bh, body: { organizationId: org.id } });
    expect(await read("SELECT id FROM team_member WHERE team_id = ? AND user_id = ?", team.id, b.userId)).toHaveLength(0);
    await expect(auth.api.leaveOrganization({ headers: ah, body: { organizationId: org.id } })).rejects.toThrow();
    expect((await store.sync.withIdentity(a, (scoped) => scoped.getVault(vaultId)))?.role).toBe("admin");
    await expect(auth.api.createInvitation({ headers: ah, body: { email: b.email!, role: "member", organizationId: a.userId } })).rejects.toThrow();
    await expect(auth.api.createTeam({ headers: ah, body: { name: "Forbidden", organizationId: a.userId } })).rejects.toThrow();
  });

  it("exposes only governance metadata and rejects a stale encrypted Vault deletion", async () => {
    const env = await setup();
    const { auth, store, read, user, headers, config } = env;
    const a = await user("alice@example.com"), b = await user("bob@example.com"), c = await user("carol@example.com");
    const { org, vaultId } = await teamVault(env, a, "server");
    const ah = await headers(a);
    await store.sync.withIdentity(a, (scoped) => scoped.putPermission(vaultId, "user", b.userId, "admin"));
    await store.sync.withIdentity(a, (scoped) => scoped.deletePermission(vaultId, "user", a.userId));
    expect(await store.sync.withIdentity(a, (scoped) => scoped.getVault(vaultId))).toBeNull();
    const listed = await store.sync.withIdentity(a, (scoped) => scoped.listGovernanceVaults(org.id));
    expect(listed.items).toEqual([{ vaultId, name: "Team vault", revision: 1, creatorId: a.userId }]);
    expect((await read("SELECT name FROM vaults WHERE vault_id = ?", vaultId))[0]).toEqual({ name: "" });
    await expect(store.sync.withIdentity(c, (scoped) => scoped.listGovernanceVaults(org.id))).rejects.toThrow("organization_admin_required");
    const confirmation = await store.sync.withIdentity(a, (scoped) => scoped.confirmVaultDeletion(org.id, vaultId));
    const projectId = uuidV7();
    await store.sync.withIdentity(b, (scoped) => scoped.commitTransaction(tx(vaultId, [{ id: uuidV7(), entity: "project", action: "create", entityId: projectId,
      baseRevision: null, data: { name: "Secret project", description: "Private", parentProjectId: null, createdAt: new Date() } }])));
    const deletion = tx(vaultId, []);
    await expect(store.sync.withIdentity(a, (scoped) => scoped.forceDeleteVault(org.id, deletion, confirmation.revision, confirmation.changeCursor))).rejects.toThrow("vault_delete_confirmation_stale");
    const current = await store.sync.withIdentity(a, (scoped) => scoped.confirmVaultDeletion(org.id, vaultId));
    const result = await store.sync.withIdentity(a, (scoped) => scoped.forceDeleteVault(org.id, deletion, current.revision, current.changeCursor));
    expect(result.records).toEqual([{ entity: "vault", id: vaultId, revision: null, record: null }]);
    expect((await read("SELECT vault_id FROM vaults WHERE vault_id = ?", vaultId))[0]).toBeUndefined();
    expect((await store.sync.withIdentity(a, (scoped) => scoped.forceDeleteVault(org.id, deletion, current.revision, current.changeCursor))).receipt).toBe("compact");
    const hiddenReceipt = await store.sync.withIdentity(b, (scoped) => scoped.resolveTransaction(deletion)).catch((error: unknown) => {
      expect(error).toMatchObject({ status: 404, code: "vault_not_found" });
      return null;
    });
    expect(hiddenReceipt).toBeNull();
    const app = createApp({ config, authStore: store, auth });
    const response = await app.request(`/api/v1/organizations/${encodeId("organization", org.id)}/vaults`, { headers: ah });
    expect(response.status, await response.clone().text()).toBe(200);
    await auth.api.deleteOrganization({ headers: ah, body: { organizationId: org.id } });
  });

  it.each(["header", "accounts"] as const)("creates a Team Organization through the public API in %s mode", async (mode) => {
    const { config, auth, store, user, headers } = await setup(mode);
    const actor = await user("creator@example.com");
    const app = createApp({ config, authStore: store, auth });
    const requestHeaders = await headers(actor);
    requestHeaders.set("content-type", "application/json");
    const response = await app.request("/api/v1/organizations", { method: "POST", headers: requestHeaders,
      body: JSON.stringify({ name: "Created inside migration", slug: `created-${uuidV7()}` }) });
    expect(response.status, await response.clone().text()).toBe(201);
    const created = await response.json<{ id: string }>();
    expect(created).toMatchObject({ kind: "team", role: "owner" });
    expect(created.id).toMatch(/^org_/);
    const listed = await app.request("/api/v1/organizations", { headers: requestHeaders });
    expect(await listed.json()).toMatchObject({ items: expect.arrayContaining([expect.objectContaining({ id: created.id, kind: "team" })]) as unknown });
  });

  it("uses Better Auth sessions behind a required, matching proxy identity", async () => {
    const { auth, config, user, store } = await setup();
    const a = await user("alice@example.com");
    const headers = { "X-Forwarded-Email": a.email!, origin: config.baseUrl };
    const response = await auth.handler(new Request(`${config.baseUrl}/api/auth/header/sign-in`, { method: "POST", headers }));
    expect(response.status).toBe(200);
    const cookie = response.headers.getSetCookie().map((value) => value.split(";")[0]).join("; ");
    expect(cookie).not.toBe("");
    const service = new IdentityService(config, auth, async (identity) => {
      const userId = await store.resolveHeaderUser(identity);
      return userId ? { ...identity, userId } : null;
    });
    expect((await service.fromBrowser(new Request(config.baseUrl, { headers: { ...headers, cookie } }))).userId).toBe(a.userId);
    await expect(service.fromBrowser(new Request(config.baseUrl, { headers: { cookie } }))).rejects.toThrow("valid email");
    await expect(service.fromBrowser(new Request(config.baseUrl, { headers: { cookie, "X-Forwarded-Email": "bob@example.com" } }))).rejects.toThrow("proxy_session_mismatch");
    const created = await auth.handler(new Request(`${config.baseUrl}/api/auth/organization/create`, { method: "POST",
      headers: { ...headers, cookie, "content-type": "application/json" }, body: JSON.stringify({ name: "Team", slug: `team-${uuidV7()}` }) }));
    expect(created.status).toBe(200);
    const organization = await created.json<{ members: unknown[] }>();
    expect(organization).toMatchObject({ kind: "team" });
    expect(organization.members).toHaveLength(1);
    const forged = await auth.handler(new Request(`${config.baseUrl}/api/auth/organization/create`, { method: "POST",
      headers: { ...headers, origin: "https://attacker.example", cookie, "content-type": "application/json" }, body: JSON.stringify({ name: "Bad", slug: "bad" }) }));
    expect(forged.status).toBe(403);
  });
});
