import { describe, expect, it } from "vitest";

import { createApp } from "./public-test-client";
import type { Identity } from "../src/auth/identity";
import type { AdminUserRecord } from "../src/auth/store";
import type { AppConfig } from "../src/config";
import { testStore } from "./test-store";
import { DEFAULT_SEARCH_SETTINGS } from "../src/search/settings-model";
import { createWorkerHandler } from "../src/worker";

const config: AppConfig = {
  authProvider: "header",
  authHeader: "X-Forwarded-Email",
  databaseType: "sqlite",
  baseUrl: "https://dahlia.example",
  oauthRedirectUris: [],
  maxRequestBytes: 1024,
};
const ownerHeaders = { "X-Forwarded-Email": "OWNER@example.com", origin: config.baseUrl, "content-type": "application/json" };
function administrativeStore() {
  const users = new Map<string, AdminUserRecord & { role: "admin" | "user" }>();
  const ensureIdentityUser = (identity: Identity) => {
    if (!users.has(identity.userId)) {
      users.set(identity.userId, {
        id: identity.userId,
        name: identity.name ?? identity.email ?? identity.userId,
        email: identity.email ?? `${identity.userId}@invalid`,
        role: users.size === 0 ? "admin" : "user",
        createdAt: new Date(),
      });
    }
    return Promise.resolve(true);
  };
  const store = testStore({
    ensureIdentityUser,
    listAdminUsers: () => Promise.resolve(
      [...users.values()].filter((user) => user.role === "admin").toSorted((a, b) => a.email.localeCompare(b.email)),
    ),
    isAdminUser: (id) => Promise.resolve(users.get(id)?.role === "admin"),
    addAdminUser: (email) => {
      const user = [...users.values()].find((candidate) => candidate.email === email);
      if (!user || user.role === "admin") return Promise.resolve(null);
      user.role = "admin";
      return Promise.resolve(user);
    },
    removeAdminUser: (id) => {
      const user = [...users.values()].find((candidate) => candidate.id === id && candidate.role === "admin");
      if (!user) return Promise.resolve("not_found");
      if ([...users.values()].filter((candidate) => candidate.role === "admin").length === 1) {
        return Promise.resolve("last_admin");
      }
      user.role = "user";
      return Promise.resolve("removed");
    },
  });
  return { store, users };
}

describe("administration", () => {
  it.each(["node", "worker"])("restricts and validates server search settings through %s", async (runtime) => {
    const { store } = administrativeStore();
    const app = createApp({ config, authStore: store });
    const worker = createWorkerHandler(async () => app);
    const fetchWorker = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    const send = (method: string, body?: unknown, headers = ownerHeaders) => {
      const request = new Request(`${config.baseUrl}/api/v1/admin/search-settings`, { method, headers,
        ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
      return runtime === "node" ? app.request(request) : fetchWorker(request, {} as Cloudflare.Env, {} as ExecutionContext);
    };
    expect(await (await send("GET")).json()).toEqual(DEFAULT_SEARCH_SETTINGS);
    for (const body of [{ ...DEFAULT_SEARCH_SETTINGS, title: 0 }, { ...DEFAULT_SEARCH_SETTINGS, title: 11 },
      { ...DEFAULT_SEARCH_SETTINGS, title: 1.5 }, { ...DEFAULT_SEARCH_SETTINGS, title: "5" }, { title: 5 },
      { ...DEFAULT_SEARCH_SETTINGS, unknown: 1 }]) expect((await send("PUT", body)).status).toBe(400);
    const updated = { ...DEFAULT_SEARCH_SETTINGS, title: 10 };
    expect(await (await send("PUT", updated)).json()).toEqual(updated);
    expect(await (await send("GET")).json()).toEqual(updated);
    expect((await send("PUT", DEFAULT_SEARCH_SETTINGS, { ...ownerHeaders, origin: "https://other.example" })).status).toBe(403);
    for (const method of ["GET", "PUT"]) {
      expect((await send(method, method === "PUT" ? updated : undefined, { ...ownerHeaders, "X-Forwarded-Email": "member@example.com" })).status).toBe(403);
    }
  });

  it("promotes the first authenticated user to administrator", async () => {
    const { store } = administrativeStore();
    const app = createApp({ config, authStore: store });
    const response = await app.request("/api/v1/session", { headers: { "X-Forwarded-Email": "user@example.com" } });
    expect(await response.json()).toMatchObject({ capabilities: { admin: true } });
    expect((await app.request("/api/v1/admin/members", {
      headers: { "X-Forwarded-Email": "user@example.com" },
    })).status).toBe(200);
  });

  it("fails administrator lookup closed without breaking the user session", async () => {
    const store = testStore({ isAdminUser: () => Promise.reject(new Error("database unavailable")) });
    const app = createApp({ config, authStore: store });
    const headers = { "X-Forwarded-Email": "user@example.com" };
    const session = await app.request("/api/v1/session", { headers });
    expect(session.status).toBe(200);
    expect(await session.json()).toMatchObject({ capabilities: { admin: false } });
    expect((await app.request("/api/v1/admin/members", { headers })).status).toBe(403);
  });

  it("does not expose model management endpoints", async () => {
    const { store } = administrativeStore();
    const app = createApp({ config, authStore: store });
    for (const [method, path] of [["GET", ""], ["POST", ""], ["PATCH", "/summaries"], ["DELETE", "/summaries"]]) {
      expect((await app.request(`/api/v1/admin/models${path}`, { method, headers: ownerHeaders })).status).toBe(404);
    }
  });

  it("manages registered administrators and keeps at least one through the Dahlia API", async () => {
    const { store, users } = administrativeStore();
    const app = createApp({ config, authStore: store });

    await app.request("/api/v1/session", { headers: ownerHeaders });
    await app.request("/api/v1/session", { headers: { "X-Forwarded-Email": "second@example.com" } });

    const added = await app.request("/api/v1/admin/members", {
      method: "POST",
      headers: ownerHeaders,
      body: JSON.stringify({ email: " SECOND@example.com " }),
    });
    expect(added.status).toBe(201);
    expect([...users.values()].find((user) => user.email === "second@example.com")?.role).toBe("admin");
    expect(await (await app.request("/api/v1/admin/members", { headers: ownerHeaders })).json()).toMatchObject({ items: [
      { email: "owner@example.com", role: "admin", removable: true },
      { email: "second@example.com", role: "admin", removable: true },
    ], nextCursor: null });
    expect((await app.request(`/api/v1/admin/members/${[...users.values()].find((user) => user.email === "second@example.com")!.id}`, {
      method: "DELETE",
      headers: ownerHeaders,
    })).status).toBe(204);
    expect((await app.request(`/api/v1/admin/members/${[...users.values()].find((user) => user.email === "owner@example.com")!.id}`, {
      method: "DELETE",
      headers: ownerHeaders,
    })).status).toBe(409);
  });
});


it.each(["node", "worker"])("opens organization directory details only for administrators through %s", async (runtime) => {
  const { store } = administrativeStore();
  const id = "019d4a01-2000-7000-8000-000000000001";
  const member = { id: "019d4a01-2000-7000-8000-000000000002", userId: "019d4a01-2000-7000-8000-000000000003", role: "member", name: "Member", email: "member@example.com" };
  const calls: unknown[] = [];
  store.getServerOrganization = (organizationId, limit, membersOffset, teamsOffset) => {
    calls.push([organizationId, limit, membersOffset, teamsOffset]);
    return Promise.resolve(organizationId === id ? { id, name: "Other organization", slug: "other", kind: "team", members: Array.from({ length: 101 }, () => member), teams: [] } : null);
  };
  const app = createApp({ config, authStore: store });
  const worker = createWorkerHandler(async () => app);
  const fetchWorker = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
  const send = (path = id, headers: Record<string, string> = ownerHeaders) => {
    const request = new Request(`${config.baseUrl}/api/v1/admin/organizations/${path}`, { headers });
    return runtime === "node" ? app.request(request) : fetchWorker(request, {} as Cloudflare.Env, {} as ExecutionContext);
  };
  const response = await send(`${id}?membersOffset=100&teamsOffset=200`);
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({ name: "Other organization", members: Array.from({ length: 100 }, () => member), hasMoreMembers: true, hasMoreTeams: false });
  expect(calls).toEqual([[id, 101, 100, 200]]);
  expect((await send(id, { ...ownerHeaders, "X-Forwarded-Email": "member@example.com" })).status).toBe(403);
  expect((await send(id, {})).status).toBe(401);
  expect(calls).toHaveLength(1);
  expect((await send(`${id}?membersOffset=-1`)).status).toBe(400);
  expect((await send("019d4a01-2000-7000-8000-000000000099")).status).toBe(404);
});
