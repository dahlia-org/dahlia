import { Client } from "pg";
import { makeSignature } from "better-auth/crypto";
import { encryptionConfig } from "../src/encryption/crypto";
import { AUTH_MAX_REQUEST_BYTES, createApp } from "../src/app";
import { decodeId, encodeId } from "../src/typeid";
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
async function setup(authProvider: "header" | "accounts" = "header", authProviderId?: string, authHeader = "X-Forwarded-Email", autoCreateOrgOnSignup = true) {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-organizations-"));
  const path = join(directory, "test.sqlite");
  const postgresUrl = process.env.TEST_ORGANIZATION_DATABASE_URL;
  const suffix = uuidV7();
  const config = { autoCreateOrgOnSignup, authProvider, authProviderId, googleClientId: "test", googleClientSecret: "test",
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
    const header: Identity = { userId: email, email, name: email, source: "header", };
    const context = await auth.$context;
    const userId = authProvider === "header" ? await store.resolveHeaderUser(header)
      : (await context.internalAdapter.createUser({ email, name: email, emailVerified: true }, { method: "oauth", oauth: { providerId: "google", profile: {} } })).id;
    if (!userId) throw new Error("user missing");
    const identity = { ...header, userId, };
    await store.ensureIdentityUser(identity);
    const own = await store.sync.withIdentity(identity, (scoped) => scoped.listWorkspaces());
    const personal = own.find((w) => w.personalUserId === userId && w.organizationName === `${email}のOrg`);
    return { ...identity, organizationId: personal?.organizationId ?? "", workspaceId: personal?.workspaceId ?? "" };
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
  const createOrganization = async (owner: Identity, name = "Team", slug = `team-${uuidV7()}`) => {
    const [previous] = await read('SELECT role FROM "user" WHERE id = ?', owner.userId);
    await read('UPDATE "user" SET role = ? WHERE id = ?', "admin", owner.userId);
    try { return await store.organizations.create(owner, { name, slug, initialOwnerUserId: owner.userId }); }
    finally { await read('UPDATE "user" SET role = ? WHERE id = ?', String(previous?.role ?? "user"), owner.userId); }
  };
  const clearPersonalWorkspaces = async (organizationId: string) => {
    const [owner] = await read("SELECT user_id FROM member WHERE organization_id = ? AND role = 'owner'", organizationId);
    const actor: Identity = { userId: String(owner!.user_id), source: "header" };
    const workspaces = await read("SELECT workspace_id FROM workspaces WHERE organization_id = ? AND personal_user_id IS NOT NULL", organizationId);
    for (const row of workspaces) {
      const workspaceId = String(row.workspace_id);
      const confirmation = await store.sync.withIdentity(actor, (scoped) => scoped.confirmWorkspaceDeletion(organizationId, workspaceId));
      await store.sync.withIdentity(actor, (scoped) => scoped.forceDeleteWorkspace(organizationId, tx(workspaceId, []), confirmation.revision, confirmation.changeCursor));
    }
  };
  return { store, auth, read, user, config, headers, createOrganization, clearPersonalWorkspaces };
}
const autoDomains = (domains: readonly string[]) => domains.map((domain) => ({ domain, joinPolicy: "auto_join" as const }));
function tx(workspaceId: string, operations: SyncTransaction["operations"]): SyncTransaction {
  return { schemaVersion: 3, id: uuidV7(), workspaceId, operations, requestHash: uuidV7(), createdAt: new Date() };
}
async function teamWorkspace(env: Awaited<ReturnType<typeof setup>>, actor: Identity, encryption: "none" | "server" = "none") {
  const { store, createOrganization } = env;
  const org = await createOrganization(actor, "Team", `team-${uuidV7()}`);
  const workspaceId = uuidV7();
  await store.sync.withIdentity(actor, (scoped) => scoped.commitTransaction(tx(workspaceId, [{ id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId,
    baseRevision: null, data: { organizationId: org.id, encryption, name: "Team workspace", icon: "briefcase", color: "blue", createdAt: new Date() } }])));
  return { org, workspaceId };
}

describe("Organization-owned Workspaces", () => {
  it("keeps signup Org creation off by default, even after enabling it for existing users", async () => {
    const { store, user, config, createOrganization } = await setup("header", undefined, "X-Forwarded-Email", false);
    const actor = await user("default@example.com");
    expect(await store.sync.withIdentity(actor, (scoped) => scoped.listOrganizations())).toEqual([]);
    const enabled = createNodeApplicationStore({ ...config, autoCreateOrgOnSignup: true });
    try {
      await enabled.ensureIdentityUser(actor);
      expect(await enabled.sync.withIdentity(actor, (scoped) => scoped.listOrganizations())).toEqual([]);
    } finally { await enabled.close?.(); }
    const org = await createOrganization(actor);
    expect(await store.sync.withIdentity(actor, (scoped) => scoped.listWorkspaces(org.id)))
      .toMatchObject([{ personalUserId: actor.userId, organizationId: org.id, role: "admin" }]);
  });

  it.each(["header", "accounts"] as const)("retains a unique private Workspace across concurrent joining, leaving and rejoining in %s", async (mode) => {
    const { store, user, auth, headers, createOrganization, read, config } = await setup(mode);
    const owner = await user("owner@example.com"), member = await user("member@example.com");
    const org = await createOrganization(owner);
    await store.organizations.updateDomains(owner, org.id, { domains: autoDomains([member.email!.split("@")[1]!]) });
    await Promise.all([store.organizations.join(member, org.id, false), store.organizations.join(member, org.id, false)]);
    const [workspace] = await store.sync.withIdentity(member, (scoped) => scoped.listWorkspaces(org.id));
    expect(workspace).toMatchObject({ personalUserId: member.userId, organizationId: org.id });
    expect(workspace!.workspaceId).not.toBe(member.workspaceId);
    await store.addAdminUser(owner.email!);
    expect(await store.sync.withIdentity(owner, (scoped) => scoped.getWorkspace(workspace!.workspaceId))).toBeNull();
    expect(await store.sync.withIdentity(member, (scoped) => scoped.putPermission(workspace!.workspaceId, "user", owner.userId, "viewer"))).toBe(false);
    await auth.api.leaveOrganization({ headers: await headers(member), body: { organizationId: org.id } });
    expect(await store.sync.withIdentity(member, (scoped) => scoped.getWorkspace(workspace!.workspaceId))).toBeNull();
    expect(await read("SELECT workspace_id FROM workspaces WHERE organization_id = ? AND personal_user_id = ?", org.id, member.userId)).toEqual([{ workspace_id: workspace!.workspaceId }]);
    if (config.databaseType === "postgres") {
      const direct = new Client({ connectionString: config.databaseUrl });
      await direct.connect();
      try {
        await direct.query("BEGIN");
        await direct.query("SELECT set_config('app.user_id', $1, true)", [member.userId]);
        expect((await direct.query("SELECT workspace_id FROM app.workspaces WHERE workspace_id = $1", [workspace!.workspaceId])).rows).toEqual([]);
        expect((await direct.query("SELECT app.current_identity_can_read_workspace($1) AS allowed", [workspace!.workspaceId])).rows).toEqual([{ allowed: false }]);
        await direct.query("ROLLBACK");
      } finally { await direct.end(); }
    }
    await store.organizations.join(member, org.id, false);
    expect(await store.sync.withIdentity(member, (scoped) => scoped.listWorkspaces(org.id))).toMatchObject([{ workspaceId: workspace!.workspaceId }]);
  });

  it("rolls back membership when private Workspace provisioning fails", async () => {
    const { store, user, auth, createOrganization, read, config } = await setup();
    const owner = await user("owner@example.com"), member = await user("member@example.com");
    const org = await createOrganization(owner);
    const postgres = config.databaseType === "postgres";
    if (postgres) {
      await read("CREATE FUNCTION app.fail_private_workspace() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'provision failed'; END $$");
      await read("CREATE TRIGGER fail_private_workspace BEFORE INSERT ON app.workspaces FOR EACH ROW EXECUTE FUNCTION app.fail_private_workspace()");
    } else await read("CREATE TRIGGER fail_private_workspace BEFORE INSERT ON workspaces BEGIN SELECT RAISE(ABORT, 'provision failed'); END");
    try {
      await expect(auth.api.addMember({ body: { organizationId: org.id, userId: member.userId, role: "member" } })).rejects.toThrow();
      expect(await store.organizations.hasMember(member.userId, org.id)).toBe(false);
    } finally {
      await read(postgres ? "DROP TRIGGER fail_private_workspace ON app.workspaces" : "DROP TRIGGER fail_private_workspace");
      if (postgres) await read("DROP FUNCTION app.fail_private_workspace()");
    }
    await auth.api.addMember({ body: { organizationId: org.id, userId: member.userId, role: "member" } });
    expect(await store.sync.withIdentity(member, (scoped) => scoped.listWorkspaces(org.id))).toHaveLength(1);
  });

  it.each([true, false])("rejects oversized organization JSON before validation (content length: %s)", async (knownLength) => {
    const { store, auth, config, user, read } = await setup();
    const actor = await user("creator@example.com");
    await store.addAdminUser(actor.email!);
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
      const projected = { ...identity, userId, };
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
    expect(await read("SELECT organization_id FROM member WHERE user_id = ?", actor.userId)).toHaveLength(1);
    for (const invalid of [null, "invalid", "a@@example.com", "a@example.com,b@example.com"]) {
      const rejected = new Headers({ "X-Forwarded-User": email, origin: config.baseUrl });
      if (authHeader !== "X-Forwarded-Email") rejected.set("X-Forwarded-Email", email);
      if (invalid !== null) rejected.set(authHeader, invalid);
      await expect(service.fromBrowser(new Request(config.baseUrl, { headers: rejected }))).rejects.toThrow("valid email");
      expect((await auth.handler(new Request(`${config.baseUrl}/api/auth/header/sign-in`, { method: "POST", headers: rejected }))).status).toBe(401);
    }
    expect(await read("SELECT id FROM account WHERE account_id = ?", email)).toHaveLength(1);
  });

  it("manages normalized domains through the public API and enrolls only new Header users", async () => {
    const { user, auth, headers, store, config, read, createOrganization } = await setup();
    const owner = await user("owner@example.com");
    const existing = await user("existing@example.com");
    const org = await createOrganization(owner, "Team", `team-${uuidV7()}`);
    const domain = owner.email!.split("@")[1]!;
    const otherDomain = `another-${uuidV7()}.com`;
    const app = createApp({ config, auth, authStore: store });
    const path = `/api/v1/organizations/${encodeId("organization", org.id)}/domains`;
    const send = (method: string, actor = owner, domains?: unknown, origin = config.baseUrl) => app.request(path, {
      method, headers: { [config.authHeader]: actor.email!, origin, "content-type": "application/json" },
      ...(method === "PUT" ? { body: JSON.stringify({ domains: Array.isArray(domains) ? autoDomains(domains) : domains }) } : {}),
    });
    expect(await (await send("GET")).json()).toEqual({ domains: autoDomains([]) });
    const saved = await send("PUT", owner, [` ${domain.toUpperCase()} `, otherDomain]);
    expect(saved.status).toBe(200);
    expect(await saved.json()).toEqual({ domains: autoDomains([domain, otherDomain].sort()) });
    await user("existing@example.com");
    expect(await read("SELECT organization_id FROM member WHERE user_id = ?", existing.userId)).toEqual([{ organization_id: existing.organizationId }]);
    const newcomer = await user("new@example.com");
    expect(await read("SELECT role FROM member WHERE organization_id = ? AND user_id = ?", org.id, newcomer.userId)).toEqual([{ role: "member" }]);
    const secondId = await store.resolveHeaderUser({ source: "header", userId: `second@${otherDomain}`, email: `second@${otherDomain}` });
    expect(await read("SELECT role FROM member WHERE organization_id = ? AND user_id = ?", org.id, secondId!)).toEqual([{ role: "member" }]);
    expect((await send("GET", newcomer)).status).toBe(200);
    expect((await send("GET", existing)).status).toBe(403);
    expect((await send("PUT", newcomer, [])).status).toBe(403);
    expect((await send("PUT", owner, [], "https://untrusted.example")).status).toBe(403);
    const [membership] = await read("SELECT id FROM member WHERE organization_id = ? AND user_id = ?", org.id, newcomer.userId);
    await auth.api.updateMemberRole({ headers: await headers(owner), body: { organizationId: org.id, memberId: String(membership!.id), role: "admin" } });
    expect((await send("PUT", newcomer, [domain])).status).toBe(200);
    await expect(store.organizations.updateDomains({ ...owner, impersonated: true }, org.id, { domains: autoDomains([]) }))
      .rejects.toMatchObject({ statusCode: 403 });
    await expect(store.organizations.updateDomains(owner, uuidV7(), { domains: autoDomains([domain]) })).rejects.toMatchObject({ statusCode: 403 });
    for (const [code, cases] of [
      ["shared_email_domain", [["gmail.com"], ["GMAIL.COM"], ["mail.gmail.com"], ["yahoo.co.jp"], ["outlook.com"], ["icloud.com"]]],
      ["invalid_organization_domain", [["me@example.com"], ["https://example.com"], ["*.example.com"], ["bad..com"], ["localhost"], Array(11).fill(domain)]],
    ] as const) {
      for (const invalid of cases) {
        const response = await send("PUT", owner, invalid);
        expect(response.status).toBe(400);
        expect(await response.json()).toMatchObject({ code });
        expect(await (await send("GET")).json()).toEqual({ domains: autoDomains([domain]) });
      }
    }
    // A domain added by an older snapshot must also be blocked at enrollment.
    await read("INSERT INTO organization_domains (domain, organization_id, join_policy) VALUES (?, ?, 'auto_join')", "gmail.com", org.id);
    const shared = await store.resolveHeaderUser({ source: "header", userId: `shared-${uuidV7()}@gmail.com` });
    expect(await read("SELECT organization_id FROM member WHERE user_id = ?", shared!)).toHaveLength(1);
    expect((await send("PUT", owner, [])).status).toBe(200);
    const later = await user("later@example.com");
    expect(await read("SELECT organization_id FROM member WHERE user_id = ?", later.userId)).toEqual([{ organization_id: later.organizationId }]);
    expect(await read("SELECT role FROM member WHERE organization_id = ? AND user_id = ?", org.id, newcomer.userId)).toEqual([{ role: "admin" }]);
  });

  it("allows domains across organizations and rolls back a failed replacement", async () => {
    const { clearPersonalWorkspaces, user, store, read, config, createOrganization } = await setup();
    const owner = await user("owner@example.com");
    const a = await createOrganization(owner, "Team", `team-${uuidV7()}`);
    const b = await createOrganization(owner, "Second", `team-${uuidV7()}`);
    const domain = owner.email!.split("@")[1]!;
    const claims = await Promise.allSettled([a, b].map((org) => store.organizations.updateDomains(owner, org.id, { domains: autoDomains([domain]) })));
    expect(claims.filter((result) => result.status === "fulfilled")).toHaveLength(2);
    const winner = claims[0]!.status === "fulfilled" ? a : b;
    const loser = winner.id === a.id ? b : a;
    expect(await store.organizations.getDomains(owner, loser.id)).toEqual({ domains: autoDomains([domain]) });
    const newcomer = await user("both@example.com");
    expect(await read("SELECT id FROM member WHERE user_id = ?", newcomer.userId)).toHaveLength(3);
    const postgres = config.databaseType === "postgres";
    if (postgres) {
      await read("CREATE FUNCTION app.fail_auto_join() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'domain save failed'; END $$");
      await read("CREATE TRIGGER fail_auto_join BEFORE INSERT ON app.organization_domains FOR EACH ROW EXECUTE FUNCTION app.fail_auto_join()");
    } else await read("CREATE TRIGGER fail_auto_join BEFORE INSERT ON organization_domains BEGIN SELECT RAISE(ABORT, 'domain save failed'); END");
    try {
      await expect(store.organizations.updateDomains(owner, winner.id, { domains: autoDomains([`new-${domain}`]) })).rejects.toThrow();
      expect(await store.organizations.getDomains(owner, winner.id)).toEqual({ domains: autoDomains([domain]) });
    } finally {
      await read(postgres ? "DROP TRIGGER fail_auto_join ON app.organization_domains" : "DROP TRIGGER fail_auto_join");
      if (postgres) await read("DROP FUNCTION app.fail_auto_join()");
    }
    await store.addAdminUser(owner.email!);
    await clearPersonalWorkspaces(winner.id);
    await store.organizations.delete(owner, winner.id);
    expect(await store.organizations.updateDomains(owner, loser.id, { domains: autoDomains([domain]) })).toEqual({ domains: autoDomains([domain]) });
  });

  it("keeps domains distinct and prevents legacy fields from claiming them", async () => {
    const { user, auth, headers, store, read, createOrganization } = await setup();
    const actor = await user("owner@example.com");
    const ah = await headers(actor);
    const org = await createOrganization(actor, "Team", `team-${uuidV7()}`);
    const domain = actor.email!.split("@")[1]!;
    await store.organizations.updateDomains(actor, org.id, { domains: autoDomains([domain]) });
    const removed = await user("member@example.com");
    const other = await user("other@sub.example.com");
    expect(await read("SELECT organization_id FROM member WHERE user_id = ?", other.userId)).toEqual([{ organization_id: other.organizationId }]);
    const updated = await auth.handler(new Request(`${(await auth.$context).baseURL}/organization/update`, {
      method: "POST", headers: { ...Object.fromEntries(ah), "content-type": "application/json" },
      body: JSON.stringify({ organizationId: org.id, data: { name: "Renamed", domain: `changed-${domain}` } }),
    }));
    expect(updated.status).toBe(200);
    expect(await store.organizations.getDomains(actor, org.id)).toEqual({ domains: autoDomains([domain]) });
    await auth.api.removeMember({ headers: ah, body: { organizationId: org.id, memberIdOrEmail: removed.email! } });
    await headers(removed);
    expect(await read("SELECT id FROM member WHERE organization_id = ? AND user_id = ?", org.id, removed.userId)).toHaveLength(0);
    expect(await store.sync.withIdentity(removed, (scoped) => scoped.getWorkspace(actor.userId))).toBeNull();
  });

  it("initializes Personal once and joins a domain only at user creation", async () => {
    const { clearPersonalWorkspaces, store, auth, headers, read, user, createOrganization } = await setup();
    const [a, same] = await Promise.all([user("alice@example.com"), user("alice@example.com")]);
    expect(a.userId).toBe(same.userId);
    expect((await read("SELECT slug FROM organization WHERE id = ?", a.organizationId))[0]).toEqual({ slug: a.email!.split("@")[0]!.replace(/[^a-z0-9]/g, "_") });
    expect(await read("SELECT role FROM workspace_permissions WHERE workspace_id = ?", a.workspaceId)).toEqual([{ role: "admin" }]);
    const domain = a.email!.split("@")[1]!;
    const org = await createOrganization(a, "Team", `team-${uuidV7()}`);
    const orgId = org.id;
    await store.organizations.updateDomains(a, orgId, { domains: autoDomains([domain]) });
    expect(await read("SELECT role FROM member WHERE organization_id = ?", orgId)).toEqual([{ role: "owner" }]);
    const b = await user("bob@example.com");
    await auth.api.leaveOrganization({ headers: await headers(b), body: { organizationId: orgId } });
    await store.ensureIdentityUser(b);
    await user("bob@example.com");
    expect(await read("SELECT id FROM member WHERE organization_id = ? AND user_id = ?", orgId, b.userId)).toHaveLength(0);
    await store.addAdminUser(a.email!);
    await clearPersonalWorkspaces(orgId);
    await store.organizations.delete(a, orgId);
    await user("alice@example.com");
    expect(await read("SELECT domain FROM organization_domains WHERE domain = ?", domain)).toHaveLength(0);
    const c = await user("carol@example.com");
    expect(await read("SELECT organization_id FROM member WHERE user_id = ?", c.userId)).toEqual([{ organization_id: c.organizationId }]);
    await expect(store.sync.withIdentity(a, (scoped) => scoped.commitTransaction(tx(a.workspaceId, [{ id: uuidV7(), entity: "workspace", action: "reset", entityId: a.workspaceId, baseRevision: 1, data: {} }])))).rejects.toThrow("personal_workspace_immutable");
  });

  it("preserves legacy slug syntax during name edits and sharing changes", async () => {
    const env = await setup();
    const { user, auth, headers, read, store } = env;
    const owner = await user("legacy@example.com");
    const recipient = await user("recipient@example.com");
    const { org, workspaceId } = await teamWorkspace(env, owner);
    const legacySlug = `legacy.${uuidV7()}`;
    await read("UPDATE organization SET slug = ? WHERE id = ?", legacySlug, org.id);
    const ownerHeaders = await headers(owner);
    await auth.api.updateOrganization({ headers: ownerHeaders, body: { organizationId: org.id, data: { name: "Renamed" } } });
    await expect(auth.api.updateOrganization({ headers: ownerHeaders, body: { organizationId: org.id, data: { slug: "new.invalid" } } })).rejects.toThrow("invalid_organization_slug");
    expect(await store.sync.withIdentity(owner, (scoped) => scoped.putPermission(workspaceId, "user", recipient.userId, "viewer"))).toBe(true);
    expect(await store.sync.withIdentity(owner, (scoped) => scoped.deletePermission(workspaceId, "user", recipient.userId))).toBe(true);
    expect(await read("SELECT slug FROM organization WHERE id = ?", org.id)).toEqual([{ slug: legacySlug }]);
  });

  it("allocates readable slugs across concurrent registrations and normalized collisions", async () => {
    const { user, read } = await setup();
    const a = await user("kazuki.matsuda@example.com");
    const base = a.email!.split("@")[0]!.replace(/[^a-z0-9]/g, "_");
    const b = await user("kazuki_matsuda@other.com");
    expect(await read("SELECT slug FROM organization WHERE id = ?", b.organizationId)).toEqual([{ slug: `${base}_2` }]);
    const others = await Promise.all([user("kazuki.matsuda@third.com"), user("kazuki.matsuda@fourth.com")]);
    const slugs = await Promise.all(others.map(async (actor) => (await read("SELECT slug FROM organization WHERE id = ?", actor.organizationId))[0]!.slug));
    expect(slugs.sort()).toEqual([`${base}_3`, `${base}_4`]);

  });

  it.each(["header", "accounts"] as const)("validates slug edits and preserves ownership in %s mode", async (mode) => {
    const { auth, user, headers, read, store, createOrganization } = await setup(mode);
    const owner = await user("slug.owner@example.com");
    const member = await user("slug.member@example.com");
    const ownerHeaders = await headers(owner);
    const memberHeaders = await headers(member);
    const slug = `edited_${uuidV7()}`;
    // Existing released slugs remain valid until explicitly changed.
    await read("UPDATE organization SET slug = ? WHERE id = ?", `personal-${owner.userId}`, owner.organizationId);
    await store.ensureIdentityUser(owner);
    expect(await read("SELECT slug FROM organization WHERE id = ?", owner.organizationId)).toEqual([{ slug: `personal-${owner.userId}` }]);
    const edit = (organizationId: string, value: string, requestHeaders = ownerHeaders) => auth.api.updateOrganization({ headers: requestHeaders, body: { organizationId, data: { slug: value } } });
    await edit(owner.organizationId, slug);
    await edit(owner.organizationId, slug);
    expect(await read("SELECT slug FROM organization WHERE id = ?", owner.organizationId)).toEqual([{ slug }]);
    const org = await createOrganization(owner, "Team", `team_${uuidV7()}`);
    for (const invalid of ["", "BadSlug", "has.dot", "has space", "日本語"]) {
      await expect(edit(owner.organizationId, invalid)).rejects.toThrow();
      await expect(auth.api.createOrganization({ headers: ownerHeaders, body: { name: "Invalid", slug: invalid } })).rejects.toThrow();
    }
    await expect(edit(org.id, slug)).rejects.toThrow();
    await expect(edit(org.id, `personal-${uuidV7()}`)).rejects.toThrow("reserved_organization_slug");
    await expect(edit(owner.organizationId, `unauthorized_${uuidV7()}`, memberHeaders)).rejects.toThrow();
    await expect(edit(org.id, `unauthorized_${uuidV7()}`, memberHeaders)).rejects.toThrow();
    const teamSlug = `renamed_${uuidV7()}`;
    await edit(org.id, teamSlug);
    expect(await read("SELECT slug FROM organization WHERE id = ?", org.id)).toEqual([{ slug: teamSlug }]);
    expect(await read("SELECT slug FROM organization WHERE id = ?", owner.organizationId)).toEqual([{ slug }]);
    expect(await read("SELECT user_id, role FROM member WHERE organization_id = ?", owner.organizationId)).toEqual([{ user_id: owner.userId, role: "owner" }]);
    if (mode === "header") {
      const domain = owner.email!.split("@")[1]!;
      const domainOrg = org.id;
      await store.organizations.updateDomains(owner, domainOrg, { domains: autoDomains([domain]) });
      await auth.api.addMember({ body: { organizationId: domainOrg, userId: member.userId, role: "member" } });
      await expect(edit(domainOrg, `member_${uuidV7()}`, memberHeaders)).rejects.toThrow();
      const [domainMember] = await read("SELECT id FROM member WHERE organization_id = ? AND user_id = ?", domainOrg, member.userId);
      await auth.api.updateMemberRole({ headers: ownerHeaders, body: { organizationId: domainOrg, memberId: String(domainMember!.id), role: "admin" } });
      const newDomainSlug = `domain_${uuidV7()}`;
      await edit(domainOrg, newDomainSlug, memberHeaders);
      const newcomer = await user("slug.newcomer@example.com");
      expect(await read("SELECT slug FROM organization WHERE id = ?", domainOrg)).toEqual([{ slug: newDomainSlug }]);
      expect(await read("SELECT role FROM member WHERE organization_id = ? AND user_id = ?", domainOrg, newcomer.userId)).toEqual([{ role: "member" }]);
    }
  });

  it("rolls back failed domain enrollment and retries the complete registration", async () => {
    const { read, user, config, store, createOrganization } = await setup();
    const owner = await user("owner@example.com");
    const org = await createOrganization(owner, "Team", `team-${uuidV7()}`);
    await store.organizations.updateDomains(owner, org.id, { domains: autoDomains([owner.email!.split("@")[1]!]) });
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
    expect(await read("SELECT workspace_id FROM workspaces WHERE organization_id = ?", a.organizationId)).toEqual([{ workspace_id: a.workspaceId }]);
  });

  it("automatically enrolls verified Google users in domain organizations", async () => {
    const { user, read, store, createOrganization } = await setup("accounts");
    const owner = await user("owner@example.com");
    const org = await createOrganization(owner, "Team", `team-${uuidV7()}`);
    await store.organizations.updateDomains(owner, org.id, { domains: autoDomains([owner.email!.split("@")[1]!]) });
    const a = await user("google@example.com");

    expect(await read("SELECT organization_id FROM member WHERE user_id = ?", a.userId)).toEqual(expect.arrayContaining([{ organization_id: a.organizationId }, { organization_id: org.id }]));
  });

  it.each([undefined, "native-admin-test-password"])("projects native Header user provisioning with password %s", async (password) => {
    const { store, auth, config, read, user, headers, createOrganization } = await setup("header", "databricks");
    const administrator = await user("administrator@example.com");
    await store.addAdminUser(administrator.email!);
    const email = `created-${uuidV7()}@${uuidV7()}.example.com`;
    const org = await createOrganization(administrator, "Team", `team-${uuidV7()}`);
    await store.organizations.updateDomains(administrator, org.id, { domains: autoDomains([email.split("@")[1]!]) });
    const created = await auth.api.createUser({ headers: await headers(administrator), body: { email, name: "Created", password } });
    const app = createApp({ config, auth, authStore: store });
    const response = await app.request("/api/v1/session", { headers: { [config.authHeader]: email } });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ user: { id: encodeId("user", created.user.id) } });
    expect(await read("SELECT user_id, provider_id FROM account WHERE issuer = ? AND account_id = ?", "urn:dahlia:header", email))
      .toEqual([{ user_id: created.user.id, provider_id: "databricks" }]);
    expect(await read("SELECT workspace_id FROM workspaces WHERE personal_user_id = ?", created.user.id)).toHaveLength(2);
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
    expect(await read("SELECT workspace_id FROM workspaces WHERE personal_user_id = ?", created.user.id)).toHaveLength(1);
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
    const { org, workspaceId } = await teamWorkspace(env, a);
    await store.sync.withIdentity(a, (scoped) => scoped.putPermission(workspaceId, "user", b.userId, "editor"));
    await store.sync.withIdentity(a, (scoped) => scoped.putPermission(workspaceId, "user", c.userId, "viewer"));
    const projectId = uuidV7();
    const receipt = await store.sync.withIdentity(b, (scoped) => scoped.commitTransaction(tx(workspaceId, [{ id: uuidV7(), entity: "project", action: "create", entityId: projectId,
      baseRevision: null, data: { name: "Editor project", description: "", parentProjectId: null, projectType: "internal", createdAt: new Date() } }])));
    for (const actor of [a, b, c]) {
      expect((await store.sync.withIdentity(actor, (scoped) => scoped.listChanges(workspaceId, 0, 100, 100))).some((item) => item.transactionId === receipt.id)).toBe(true);
    }
    await expect(store.sync.withIdentity(b, (scoped) => scoped.commitTransaction(tx(workspaceId, [{ id: uuidV7(), entity: "workspace", action: "update", entityId: workspaceId,
      baseRevision: 1, data: { name: "Denied" } }])))).rejects.toThrow("workspace_admin_required");
    expect(await store.sync.withIdentity(b, (scoped) => scoped.putPermission(workspaceId, "user", c.userId, "admin"))).toBe(false);
    for (const preservePermissions of [false, true]) {
      await expect(store.sync.withIdentity(b, (scoped) => scoped.commitTransaction(tx(workspaceId, [{ id: uuidV7(), entity: "workspace", action: "reset", entityId: workspaceId,
        baseRevision: 1, data: { preservePermissions } }])))).rejects.toThrow("workspace_admin_required");
    }
    const { workspaceId: managedWorkspaceId } = await teamWorkspace(env, a);
    await store.sync.withIdentity(a, (scoped) => scoped.putPermission(managedWorkspaceId, "user", b.userId, "admin"));
    for (const [sourceWorkspaceId, destinationWorkspaceId] of [[workspaceId, managedWorkspaceId], [managedWorkspaceId, workspaceId]]) {
      await expect(store.sync.withIdentity(b, (scoped) => scoped.transferWorkspace({ sourceWorkspaceId: sourceWorkspaceId!, destinationWorkspaceId: destinationWorkspaceId!,
        sourceRevision: 1, destinationRevision: 1, audienceHash: "unused", idempotencyKey: uuidV7(), requestHash: uuidV7() }))).rejects.toThrow("workspace_not_found");
    }
    await expect(store.sync.withIdentity(a, (scoped) => scoped.putPermission(workspaceId, "user", a.userId, "editor"))).rejects.toThrow();
    expect((await store.sync.withIdentity(a, (scoped) => scoped.getWorkspace(workspaceId)))?.organizationId).toBe(org.id);
    expect((await store.sync.withIdentity(a, (scoped) => scoped.listSnapshot(workspaceId, undefined, 100))).items[0]?.record).not.toHaveProperty("createdBy");
  });

  for (const mode of ["header", "accounts"] as const) it(`uses the same invitations, teams, and atomic Admin guards with ${mode}`, async () => {
    const env = await setup(mode);
    const { auth, store, read, user, headers } = env;
    const a = await user("alice@example.com"), b = await user("bob@example.com");
    const { org, workspaceId } = await teamWorkspace(env, a);
    const ah = await headers(a), bh = await headers(b);
    const invitation = await auth.api.createInvitation({ headers: ah, body: { email: b.email!, role: "member", organizationId: org.id } });
    await auth.api.acceptInvitation({ headers: bh, body: { invitationId: invitation.id } });
    const team = await auth.api.createTeam({ headers: ah, body: { name: "Editors", organizationId: org.id } });
    expect(await read("SELECT user_id FROM team_member WHERE team_id = ?", team.id)).toEqual([{ user_id: a.userId }]);
    await auth.api.addTeamMember({ headers: ah, body: { teamId: team.id, userId: b.userId, organizationId: org.id } });
    for (const principalType of ["user", "organization", "team"] as const) {
      const principalId = principalType === "user" ? b.userId : principalType === "organization" ? org.id : team.id;
      for (const role of ["viewer", "editor", "admin"] as const) {
        await store.sync.withIdentity(a, (scoped) => scoped.putPermission(workspaceId, principalType, principalId, role));
        expect((await store.sync.withIdentity(b, (scoped) => scoped.getWorkspace(workspaceId)))?.role).toBe(role);
        const projectId = uuidV7();
        const write = () => store.sync.withIdentity(b, (scoped) => scoped.commitTransaction(tx(workspaceId, [{ id: uuidV7(), entity: "project", action: "create", entityId: projectId, baseRevision: null,
          data: { name: projectId, description: "", parentProjectId: null, createdAt: new Date() } }])));
        if (role === "viewer") await expect(write()).rejects.toThrow();
        else {
          await write();
          await store.sync.withIdentity(b, (scoped) => scoped.commitTransaction(tx(workspaceId, [{ id: uuidV7(), entity: "project", action: "delete", entityId: projectId, baseRevision: 1, data: {} }])));
        }
      }
      await store.sync.withIdentity(a, (scoped) => scoped.deletePermission(workspaceId, principalType, principalId));
    }
    // Two individually valid demotions cannot remove both remaining Admins.
    await store.sync.withIdentity(a, (scoped) => scoped.putPermission(workspaceId, "user", b.userId, "admin"));
    const results = await Promise.allSettled([a, b].map((actor) => store.sync.withIdentity(actor, (scoped) => scoped.putPermission(workspaceId, "user", actor.userId, "editor"))));
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(await read("SELECT role FROM workspace_permissions WHERE workspace_id = ? AND role = 'admin'", workspaceId)).toHaveLength(1);
    const adminId = (await read("SELECT principal_id FROM workspace_permissions WHERE workspace_id = ? AND role = 'admin'", workspaceId))[0]!.principal_id;
    const adminActor = adminId === a.userId ? a : b;
    await store.sync.withIdentity(adminActor, (scoped) => scoped.putPermission(workspaceId, "team", team.id, "admin"));
    await store.sync.withIdentity(adminActor, (scoped) => scoped.deletePermission(workspaceId, "user", adminActor.userId));
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
    expect((await store.sync.withIdentity(a, (scoped) => scoped.getWorkspace(workspaceId)))?.role).toBe("admin");
    await expect(auth.api.createInvitation({ headers: ah, body: { email: b.email!, role: "member", organizationId: a.userId } })).rejects.toThrow();
    await expect(auth.api.createTeam({ headers: ah, body: { name: "Forbidden", organizationId: a.userId } })).rejects.toThrow();
  });

  it("exposes only governance metadata and rejects a stale encrypted Workspace deletion", async () => {
    const env = await setup();
    const { auth, store, read, user, headers, config } = env;
    const a = await user("alice@example.com"), b = await user("bob@example.com"), c = await user("carol@example.com");
    const { org, workspaceId } = await teamWorkspace(env, a, "server");
    const ah = await headers(a);
    await store.sync.withIdentity(a, (scoped) => scoped.putPermission(workspaceId, "user", b.userId, "admin"));
    await store.sync.withIdentity(a, (scoped) => scoped.deletePermission(workspaceId, "user", a.userId));
    expect(await store.sync.withIdentity(a, (scoped) => scoped.getWorkspace(workspaceId))).toBeNull();
    const listed = await store.sync.withIdentity(a, (scoped) => scoped.listGovernanceWorkspaces(org.id));
    expect(listed.items).toEqual(expect.arrayContaining([{ workspaceId, name: "Team workspace", icon: "briefcase", color: "blue", revision: 1, creatorId: a.userId }]));
    expect((await read("SELECT name FROM workspaces WHERE workspace_id = ?", workspaceId))[0]).toEqual({ name: "" });
    await expect(store.sync.withIdentity(c, (scoped) => scoped.listGovernanceWorkspaces(org.id))).rejects.toThrow("organization_admin_required");
    const confirmation = await store.sync.withIdentity(a, (scoped) => scoped.confirmWorkspaceDeletion(org.id, workspaceId));
    const projectId = uuidV7();
    await store.sync.withIdentity(b, (scoped) => scoped.commitTransaction(tx(workspaceId, [{ id: uuidV7(), entity: "project", action: "create", entityId: projectId,
      baseRevision: null, data: { name: "Secret project", description: "Private", parentProjectId: null, createdAt: new Date() } }])));
    const deletion = tx(workspaceId, []);
    await expect(store.sync.withIdentity(a, (scoped) => scoped.forceDeleteWorkspace(org.id, deletion, confirmation.revision, confirmation.changeCursor))).rejects.toThrow("workspace_delete_confirmation_stale");
    const current = await store.sync.withIdentity(a, (scoped) => scoped.confirmWorkspaceDeletion(org.id, workspaceId));
    const result = await store.sync.withIdentity(a, (scoped) => scoped.forceDeleteWorkspace(org.id, deletion, current.revision, current.changeCursor));
    expect(result.records).toEqual([{ entity: "workspace", id: workspaceId, revision: null, record: null }]);
    expect((await read("SELECT workspace_id FROM workspaces WHERE workspace_id = ?", workspaceId))[0]).toBeUndefined();
    expect((await store.sync.withIdentity(a, (scoped) => scoped.forceDeleteWorkspace(org.id, deletion, current.revision, current.changeCursor))).receipt).toBe("compact");
    const hiddenReceipt = await store.sync.withIdentity(b, (scoped) => scoped.resolveTransaction(deletion)).catch((error: unknown) => {
      expect(error).toMatchObject({ status: 404, code: "workspace_not_found" });
      return null;
    });
    expect(hiddenReceipt).toBeNull();
    const app = createApp({ config, authStore: store, auth });
    const response = await app.request(`/api/v1/organizations/${encodeId("organization", org.id)}/workspaces`, { headers: ah });
    expect(response.status, await response.clone().text()).toBe(200);
    await store.addAdminUser(a.email!);
    await env.clearPersonalWorkspaces(org.id);
    await store.organizations.delete(a, org.id);
  });

  it.each(["header", "accounts"] as const)("creates a Team Organization through the public API in %s mode", async (mode) => {
    const { config, auth, store, user, headers } = await setup(mode);
    const actor = await user("creator@example.com");
    await store.addAdminUser(actor.email!);
    const app = createApp({ config, authStore: store, auth });
    const requestHeaders = await headers(actor);
    requestHeaders.set("content-type", "application/json");
    const response = await app.request("/api/v1/organizations", { method: "POST", headers: requestHeaders,
      body: JSON.stringify({ name: "Created inside migration", slug: `created-${uuidV7()}`, initialOwnerUserId: encodeId("user", actor.userId) }) });
    expect(response.status, await response.clone().text()).toBe(201);
    const created = await response.json<{ id: string }>();
    expect(created).not.toHaveProperty("kind");
    expect(created.id).toMatch(/^org_/);
    const listed = await app.request("/api/v1/organizations", { headers: requestHeaders });
    expect(await listed.json()).toMatchObject({ items: expect.arrayContaining([expect.objectContaining({ id: created.id })]) as unknown });
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
    expect(created.status).toBe(403);
    const forged = await auth.handler(new Request(`${config.baseUrl}/api/auth/organization/create`, { method: "POST",
      headers: { ...headers, origin: "https://attacker.example", cookie, "content-type": "application/json" }, body: JSON.stringify({ name: "Bad", slug: "bad" }) }));
    expect(forged.status).toBe(403);
  });
  it.each(["header", "accounts"] as const)("applies all join policies, verified email and explicit rejoining in %s mode", async (mode) => {
    const { user, store, auth, headers, read, createOrganization } = await setup(mode);
    const owner = await user("owner@example.com");
    const existing = await user("existing@example.com");
    const invite = await createOrganization(owner, "Invitation");
    const approval = await createOrganization(owner, "Approval");
    const automatic = await createOrganization(owner, "Automatic");
    const another = await createOrganization(owner, "Another automatic");
    const domain = owner.email!.split("@")[1]!;
    for (const [org, joinPolicy] of [[invite, "invite_only"], [approval, "need_approval"], [automatic, "auto_join"], [another, "auto_join"]] as const) {
      await store.organizations.updateDomains(owner, org.id, { domains: [{ domain, joinPolicy }] });
    }
    expect(await store.organizations.candidates(existing)).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: approval.id, joinPolicy: "need_approval", requestStatus: null }),
      expect.objectContaining({ id: automatic.id, joinPolicy: "auto_join" }),
      expect.objectContaining({ id: another.id, joinPolicy: "auto_join" }),
    ]));
    expect((await store.organizations.candidates(existing)).map((org) => org.id)).not.toContain(invite.id);
    const newcomer = await user("newcomer@example.com");
    expect(await read("SELECT organization_id FROM member WHERE user_id = ?", newcomer.userId)).toHaveLength(3);
    expect(await read("SELECT role FROM member WHERE user_id = ? AND organization_id = ?", newcomer.userId, automatic.id)).toEqual([{ role: "member" }]);
    await headers(existing);
    expect(await read("SELECT organization_id FROM member WHERE user_id = ?", existing.userId)).toHaveLength(1);
    await expect(store.organizations.join(existing, invite.id, false)).rejects.toMatchObject({ statusCode: 403 });
    await expect(store.organizations.join(existing, approval.id, false)).rejects.toMatchObject({ statusCode: 403 });
    await expect(store.organizations.join({ ...existing, impersonated: true }, automatic.id, false)).rejects.toMatchObject({ statusCode: 403 });
    await expect(store.organizations.requests(existing, approval.id)).rejects.toMatchObject({ statusCode: 403 });
    await store.organizations.join(existing, automatic.id, false);
    await store.organizations.join(existing, automatic.id, false);
    expect(await read("SELECT id FROM member WHERE user_id = ? AND organization_id = ?", existing.userId, automatic.id)).toHaveLength(1);
    await auth.api.leaveOrganization({ headers: await headers(existing), body: { organizationId: automatic.id } });
    await store.organizations.join(existing, automatic.id, false);
    await auth.api.removeMember({ headers: await headers(owner), body: { organizationId: automatic.id, memberIdOrEmail: existing.email! } });
    await headers(existing);
    expect(await read("SELECT id FROM member WHERE user_id = ? AND organization_id = ?", existing.userId, automatic.id)).toHaveLength(0);
    await store.organizations.join(existing, automatic.id, false);
    expect(await read("SELECT id FROM member WHERE user_id = ? AND organization_id = ?", existing.userId, automatic.id)).toHaveLength(1);
    // A verified flag is required even if a persisted address matches.
    await read('UPDATE "user" SET email_verified = false WHERE id = ?', existing.userId);
    expect(await store.organizations.candidates(existing)).toEqual([]);
    await expect(store.organizations.join(existing, another.id, false)).rejects.toMatchObject({ statusCode: 403 });
    await expect(store.organizations.join(existing, approval.id, true)).rejects.toMatchObject({ statusCode: 403 });
  });

  it.each(["header", "accounts"] as const)("serializes duplicate requests, approval races, cancellation and reapplication in %s mode", async (mode) => {
    const { user, store, read, createOrganization } = await setup(mode);
    const owner = await user("owner@example.com"), applicant = await user("applicant@example.com"), other = await user("other@example.com");
    const org = await createOrganization(owner);
    const domain = owner.email!.split("@")[1]!;
    await store.organizations.updateDomains(owner, org.id, { domains: [{ domain, joinPolicy: "need_approval" }] });
    await Promise.all([store.organizations.join(applicant, org.id, true), store.organizations.join(applicant, org.id, true)]);
    const [first] = await store.organizations.requests(applicant);
    expect(first?.status).toBe("pending");
    expect(await store.organizations.requests(applicant)).toHaveLength(1);
    expect(await store.organizations.candidates(applicant)).toMatchObject([{ id: org.id, requestStatus: "pending" }]);
    await expect(store.organizations.resolveRequest(other, first!.id, "cancelled")).rejects.toMatchObject({ statusCode: 403 });
    await expect(store.organizations.resolveRequest(applicant, first!.id, "approved")).rejects.toMatchObject({ statusCode: 403 });
    await expect(store.organizations.resolveRequest({ ...owner, impersonated: true }, first!.id, "approved")).rejects.toMatchObject({ statusCode: 403 });
    await store.organizations.resolveRequest(applicant, first!.id, "cancelled");
    await store.organizations.resolveRequest(applicant, first!.id, "cancelled");
    await store.organizations.join(applicant, org.id, true);
    const second = (await store.organizations.requests(applicant)).find((request) => request.status === "pending")!;
    await store.organizations.resolveRequest(owner, second.id, "rejected");
    await store.organizations.join(applicant, org.id, true);
    const third = (await store.organizations.requests(applicant)).find((request) => request.status === "pending")!;
    const race = await Promise.allSettled([store.organizations.resolveRequest(owner, third.id, "approved"), store.organizations.resolveRequest(owner, third.id, "rejected")]);
    expect(race.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(race.filter((result) => result.status === "rejected")).toMatchObject([{ reason: { statusCode: 409 } }]);
    const resolved = (await store.organizations.requests(applicant)).find((request) => request.id === third.id)!;
    expect(await read("SELECT id FROM member WHERE user_id = ? AND organization_id = ?", applicant.userId, org.id)).toHaveLength(resolved.status === "approved" ? 1 : 0);
    expect((await store.organizations.requests(owner, org.id)).map((request) => request.status)).toEqual(expect.arrayContaining(["cancelled", "rejected", resolved.status]));
    expect(resolved.resolvedBy).toBe(owner.userId);
  });

  it("cancels only ineligible pending requests and rolls back failed approvals", async () => {
    const { user, store, read, config, createOrganization } = await setup();
    const owner = await user("owner@example.com"), applicant = await user("applicant@example.com");
    const org = await createOrganization(owner);
    const domain = owner.email!.split("@")[1]!;
    await store.organizations.updateDomains(owner, org.id, { domains: [{ domain, joinPolicy: "need_approval" }] });
    await store.organizations.join(applicant, org.id, true);
    const [request] = await store.organizations.requests(applicant);
    await store.organizations.updateDomains(owner, org.id, { domains: [{ domain, joinPolicy: "need_approval" }, { domain: `other-${domain}`, joinPolicy: "invite_only" }] });
    expect((await store.organizations.requests(applicant))[0]?.status).toBe("pending");
    const postgres = config.databaseType === "postgres";
    if (postgres) {
      await read("CREATE FUNCTION app.fail_join_resolution() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'resolution failed'; END $$");
      await read("CREATE TRIGGER fail_join_resolution BEFORE UPDATE ON app.organization_join_requests FOR EACH ROW EXECUTE FUNCTION app.fail_join_resolution()");
    } else await read("CREATE TRIGGER fail_join_resolution BEFORE UPDATE ON organization_join_requests BEGIN SELECT RAISE(ABORT, 'resolution failed'); END");
    try {
      await expect(store.organizations.resolveRequest(owner, request!.id, "approved")).rejects.toThrow();
      expect(await read("SELECT id FROM member WHERE user_id = ? AND organization_id = ?", applicant.userId, org.id)).toHaveLength(0);
      expect((await store.organizations.requests(applicant))[0]?.status).toBe("pending");
      await expect(store.organizations.updateDomains(owner, org.id, { domains: [] })).rejects.toThrow();
      expect((await store.organizations.getDomains(owner, org.id)).domains).toHaveLength(2);
    } finally {
      await read(postgres ? "DROP TRIGGER fail_join_resolution ON app.organization_join_requests" : "DROP TRIGGER fail_join_resolution");
      if (postgres) await read("DROP FUNCTION app.fail_join_resolution()");
    }
    for (const joinPolicy of ["auto_join", "invite_only"] as const) {
      await store.organizations.updateDomains(owner, org.id, { domains: [{ domain, joinPolicy }] });
      expect((await store.organizations.requests(applicant)).every((request) => request.status === "cancelled")).toBe(true);
      await store.organizations.updateDomains(owner, org.id, { domains: [{ domain, joinPolicy: "need_approval" }] });
      await store.organizations.join(applicant, org.id, true);
    }
    await store.organizations.updateDomains(owner, org.id, { domains: [] });
    expect((await store.organizations.requests(applicant)).every((request) => request.status === "cancelled")).toBe(true);
    expect(await read("SELECT role FROM member WHERE organization_id = ?", org.id)).toEqual([{ role: "owner" }]);
  });

  it.each(["header", "accounts"] as const)("reuses invited membership without demotion and applies invited teams in %s mode", async (mode) => {
    const { user, store, auth, headers, read, createOrganization } = await setup(mode);
    const owner = await user("owner@example.com"), recipient = await user("recipient@example.com");
    const org = await createOrganization(owner);
    const domain = owner.email!.split("@")[1]!;
    const ownerHeaders = await headers(owner);
    const recipientHeaders = await headers(recipient);
    const team = await auth.api.createTeam({ headers: ownerHeaders, body: { name: "Invited team", organizationId: org.id } });
    const invitation = await auth.api.createInvitation({ headers: ownerHeaders, body: { email: recipient.email!, organizationId: org.id, role: "member", teamId: team.id } });
    await store.organizations.updateDomains(owner, org.id, { domains: [{ domain, joinPolicy: "need_approval" }] });
    await store.organizations.join(recipient, org.id, true);
    const [request] = await store.organizations.requests(recipient);
    await store.organizations.resolveRequest(owner, request!.id, "approved");
    const [member] = await read("SELECT id FROM member WHERE user_id = ? AND organization_id = ?", recipient.userId, org.id);
    await auth.api.updateMemberRole({ headers: ownerHeaders, body: { organizationId: org.id, memberId: String(member!.id), role: "admin" } });
    const accepted = await auth.api.acceptInvitation({ headers: recipientHeaders, body: { invitationId: invitation.id } });
    expect(accepted.member).toMatchObject({ id: member!.id, role: "admin" });
    expect(await read("SELECT id FROM member WHERE user_id = ? AND organization_id = ?", recipient.userId, org.id)).toHaveLength(1);
    expect(await read("SELECT user_id FROM team_member WHERE team_id = ? AND user_id = ?", team.id, recipient.userId)).toHaveLength(1);
    const racing = await user("racing@example.com");
    const racingHeaders = await headers(racing);
    const racingInvitation = await auth.api.createInvitation({ headers: ownerHeaders, body: { email: racing.email!, organizationId: org.id, role: "admin", teamId: team.id } });
    await store.organizations.join(racing, org.id, true);
    const [racingRequest] = await store.organizations.requests(racing);
    await Promise.all([store.organizations.resolveRequest(owner, racingRequest!.id, "approved"), auth.api.acceptInvitation({ headers: racingHeaders, body: { invitationId: racingInvitation.id } })]);
    expect(await read("SELECT role FROM member WHERE user_id = ? AND organization_id = ?", racing.userId, org.id)).toEqual([{ role: "admin" }]);
    expect(await read("SELECT user_id FROM team_member WHERE team_id = ? AND user_id = ?", team.id, racing.userId)).toHaveLength(1);
  });

  it.each(["header", "accounts"] as const)("separates Server administrators from initial owners and rejects lifecycle bypasses in %s mode", async (mode) => {
    const { clearPersonalWorkspaces, user, store, auth, headers, read, config } = await setup(mode);
    const administrator = await user("server-admin@example.com"), owner = await user("owner@example.com"), ordinary = await user("ordinary@example.com");
    await store.addAdminUser(administrator.email!);
    const input = { name: "Managed", slug: `managed-${uuidV7()}`, initialOwnerUserId: owner.userId };
    for (const actor of [owner, ordinary, { ...administrator, impersonated: true }]) {
      await expect(store.organizations.create(actor, input)).rejects.toMatchObject({ statusCode: 403 });
    }
    await expect(store.organizations.create(administrator, { ...input, initialOwnerUserId: uuidV7() })).rejects.toMatchObject({ statusCode: 400 });
    const org = await store.organizations.create(administrator, input);
    expect(await read("SELECT user_id, role FROM member WHERE organization_id = ?", org.id)).toEqual([{ user_id: owner.userId, role: "owner" }]);
    await expect(store.organizations.delete(owner, org.id)).rejects.toMatchObject({ statusCode: 403 });
    await expect(store.organizations.delete({ ...administrator, impersonated: true }, org.id)).rejects.toMatchObject({ statusCode: 403 });
    const app = createApp({ config, authStore: store, auth });
    for (const actor of [administrator, owner, ordinary]) {
      const actorHeaders = await headers(actor);
      actorHeaders.set("content-type", "application/json");
      for (const route of ["/api/auth/organization/create", "/api/v1/organizations"]) {
        const response = await app.request(route, { method: "POST", headers: actorHeaders, body: JSON.stringify({ name: "Forbidden personal", slug: `forbidden-${uuidV7()}`, kind: "personal", userId: encodeId("user", administrator.userId), initialOwnerUserId: encodeId("user", administrator.userId) }) });
        expect(response.status).toBeGreaterThanOrEqual(400);
      }
      await expect(auth.api.createOrganization({ body: { userId: administrator.userId, name: "Bypass", slug: `bypass-${uuidV7()}` } })).rejects.toMatchObject({ statusCode: 403 });
      await expect(auth.api.deleteOrganization({ headers: actorHeaders, body: { organizationId: org.id } })).rejects.toMatchObject({ statusCode: 404 });
    }
    await expect(store.organizations.delete(administrator, administrator.organizationId)).rejects.toThrow("organization_has_workspaces");
    const ownerHeaders = await headers(owner); // Include a second device session.
    const activeTeam = await auth.api.createTeam({ headers: ownerHeaders, body: { name: "Active", organizationId: org.id } });
    await read("UPDATE session SET active_organization_id = ?, active_team_id = ? WHERE user_id = ?", org.id, activeTeam.id, owner.userId);
    await auth.api.removeTeam({ headers: await headers(owner), body: { teamId: activeTeam.id, organizationId: org.id } });
    expect(await read("SELECT active_team_id FROM session WHERE user_id = ? AND active_organization_id = ?", owner.userId, org.id))
      .toEqual([{ active_team_id: null }, { active_team_id: null }]);
    const remainingTeam = await auth.api.createTeam({ headers: ownerHeaders, body: { name: "Remaining", organizationId: org.id } });
    await read("UPDATE session SET active_team_id = ? WHERE user_id = ?", remainingTeam.id, owner.userId);
    await read("UPDATE session SET active_organization_id = ? WHERE user_id = ?", ordinary.userId, ordinary.userId);
    await clearPersonalWorkspaces(org.id);
    const response = await app.request(`/api/v1/admin/organizations/${encodeId("organization", org.id)}`, { method: "DELETE", headers: await headers(administrator) });
    expect(response.status, await response.clone().text()).toBe(204);
    expect(await read("SELECT id FROM organization WHERE id = ?", org.id)).toHaveLength(0);
    const sessions = await read("SELECT active_organization_id, active_team_id FROM session WHERE user_id = ?", owner.userId);
    expect(sessions.length).toBeGreaterThanOrEqual(2);
    expect(sessions.every((session) => session.active_organization_id === null && session.active_team_id === null)).toBe(true);
    expect(await read("SELECT active_organization_id FROM session WHERE user_id = ?", ordinary.userId)).toEqual([{ active_organization_id: ordinary.userId }]);
  });

  it("rejects organization deletion with owned Workspaces or the last effective Workspace admin", async () => {
    const env = await setup();
    const { user, store, read, createOrganization } = env;
    const administrator = await user("server-admin@example.com"), owner = await user("owner@example.com");
    await store.addAdminUser(administrator.email!);
    const { org: owning, workspaceId } = await teamWorkspace(env, owner);
    await expect(store.organizations.delete(administrator, owning.id)).rejects.toThrow("organization_has_workspaces");
    const shared = await createOrganization(owner);
    await store.sync.withIdentity(owner, (scoped) => scoped.putPermission(workspaceId, "organization", shared.id, "admin"));
    await store.sync.withIdentity(owner, (scoped) => scoped.deletePermission(workspaceId, "user", owner.userId));
    await env.headers(owner);
    await read("UPDATE session SET active_organization_id = ? WHERE user_id = ?", shared.id, owner.userId);
    await env.clearPersonalWorkspaces(shared.id);
    await expect(store.organizations.delete(administrator, shared.id)).rejects.toThrow("last_workspace_admin");
    expect(await read("SELECT active_organization_id FROM session WHERE user_id = ?", owner.userId)).toEqual([{ active_organization_id: shared.id }]);
    expect(await read("SELECT id FROM organization WHERE id = ?", shared.id)).toHaveLength(1);
    expect(await read("SELECT principal_id FROM workspace_permissions WHERE workspace_id = ?", workspaceId)).toEqual([{ principal_id: shared.id }]);
    await store.sync.withIdentity(owner, (scoped) => scoped.putPermission(workspaceId, "user", owner.userId, "admin"));
    await store.organizations.delete(administrator, shared.id);
    expect(await read("SELECT principal_id FROM workspace_permissions WHERE workspace_id = ?", workspaceId)).toEqual([{ principal_id: owner.userId }]);
  });

  it.each(["header", "accounts"] as const)("keeps participation metadata and join request IDs scoped over HTTP in %s mode", async (mode) => {
    const { user, store, auth, headers, config, createOrganization } = await setup(mode);
    const owner = await user("owner@example.com"), applicant = await user("applicant@example.com");
    const org = await createOrganization(owner);
    const organizationId = encodeId("organization", org.id);
    const app = createApp({ config, authStore: store, auth });
    const send = async (actor: Identity, path: string, method = "GET", body?: unknown) => {
      const requestHeaders = await headers(actor);
      requestHeaders.set("content-type", "application/json");
      return app.request(path, { method, headers: requestHeaders, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    };
    const domain = owner.email!.split("@")[1]!;
    expect((await send(owner, `/api/v1/organizations/${organizationId}/domains`, "PUT", { domains: [{ domain }] })).status).toBe(200);
    expect(await (await send(applicant, "/api/v1/organization-candidates")).json()).toEqual({ items: [], nextCursor: null });
    expect((await send(owner, `/api/v1/organizations/${organizationId}/domains`, "PUT", { domains: [{ domain, joinPolicy: "need_approval" }] })).status).toBe(200);
    expect(await (await send(applicant, "/api/v1/organization-candidates")).json()).toEqual({ items: [{ id: organizationId, name: "Team", logo: null, joinPolicy: "need_approval", requestStatus: null }], nextCursor: null });
    expect((await send(applicant, `/api/v1/organizations/${organizationId}/join-requests`, "POST")).status).toBe(204);
    const own = await (await send(applicant, "/api/v1/organization-join-requests")).json<{ items: { id: string; userId: string; organizationId: string }[] }>();
    const requestId = own.items[0]!.id;
    expect(requestId).toMatch(/^ojr_/);
    expect(own.items[0]).toMatchObject({ userId: encodeId("user", applicant.userId), organizationId, status: "pending", organizationName: "Team", userName: applicant.name, userEmail: applicant.email });
    expect((await send(applicant, `/api/v1/organizations/${organizationId}/join-requests`)).status).toBe(403);
    expect((await send(applicant, `/api/v1/organization-join-requests/${requestId}/approve`, "POST")).status).toBe(403);
    expect((await send(applicant, `/api/v1/organization-join-requests/${requestId}/cancel`, "POST")).status).toBe(204);
    expect((await send(applicant, `/api/v1/organizations/${organizationId}/join-requests`, "POST")).status).toBe(204);
    const pending = (await store.organizations.requests(applicant)).find((request) => request.status === "pending")!;
    expect((await send(owner, `/api/v1/organization-join-requests/${encodeId("organizationJoinRequest", pending.id)}/approve`, "POST")).status).toBe(204);
    expect(await (await send(applicant, "/api/v1/organization-candidates")).json()).toEqual({ items: [], nextCursor: null });
    expect((await send(owner, `/api/v1/organization-join-requests/${encodeId("organization", pending.id)}/approve`, "POST")).status).toBe(400);
    expect(await (await send(owner, `/api/v1/organizations/${organizationId}/join-requests`)).json()).toMatchObject({ items: expect.arrayContaining([expect.objectContaining({ id: encodeId("organizationJoinRequest", pending.id), status: "approved", resolvedBy: encodeId("user", owner.userId) })]) as unknown });
    expect(await store.sync.withIdentity(applicant, (scoped) => scoped.getWorkspace(owner.userId))).toBeNull();
  });

  it("accepts scoped Desktop bearer tokens for creation, owner lookup and deletion", async () => {
    const { clearPersonalWorkspaces, user, store, auth, config, read } = await setup("accounts");
    const administrator = await user("server-admin@example.com"), owner = await user("owner@example.com");
    await store.addAdminUser(administrator.email!);
    const app = createApp({ config, authStore: store, auth });
    const originalFetch = globalThis.fetch;
    globalThis.fetch = async (input, init) => {
      const request = new Request(input, init);
      if (new URL(request.url).pathname === "/api/auth/jwks") return app.request(request);
      throw new Error("Unexpected token verification request");
    };
    try {
      const token = async (actor: Identity, impersonated = false) => (await auth.api.signJWT({ body: { payload: { sub: actor.userId, email: actor.email, aud: `${config.baseUrl}/api/v1`, scope: "all-apis", impersonated } } })).token;
      const requestHeaders = { authorization: `Bearer ${await token(administrator)}`, "content-type": "application/json" };
      expect((await app.request("/api/v1/admin/users", { headers: requestHeaders })).status).toBe(200);
      expect(await (await app.request("/api/v1/organizations", { headers: requestHeaders })).json()).toMatchObject({ canCreateOrganizations: true });
      const created = await app.request("/api/v1/organizations", { method: "POST", headers: requestHeaders,
        body: JSON.stringify({ name: "Desktop", slug: `desktop-${uuidV7()}`, initialOwnerUserId: encodeId("user", owner.userId) }) });
      expect(created.status, await created.clone().text()).toBe(201);
      const org = await created.json<{ id: string }>();
      expect(await read("SELECT user_id, role FROM member WHERE organization_id = ?", decodeId("organization", org.id))).toEqual([{ user_id: owner.userId, role: "owner" }]);
      const ordinaryHeaders = { authorization: `Bearer ${await token(owner)}` };
      expect((await app.request("/api/v1/admin/users", { headers: ordinaryHeaders })).status).toBe(403);
      expect(await (await app.request("/api/v1/organizations", { headers: ordinaryHeaders })).json()).toMatchObject({ canCreateOrganizations: false });
      expect((await app.request(`/api/v1/admin/organizations/${org.id}`, { method: "DELETE", headers: ordinaryHeaders })).status).toBe(403);
      expect((await app.request("/api/v1/admin/users", { headers: { authorization: `Bearer ${await token(administrator, true)}` } })).status).toBe(401);
      await clearPersonalWorkspaces(decodeId("organization", org.id));
      expect((await app.request(`/api/v1/admin/organizations/${org.id}`, { method: "DELETE", headers: requestHeaders })).status).toBe(204);
    } finally { globalThis.fetch = originalFetch; }
  });

});
