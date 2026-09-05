import { describe, expect, it } from "vitest";

import { createApp } from "../src/app";
import type { Identity } from "../src/auth/identity";
import type { AdminUserRecord } from "../src/auth/store";
import type { AppConfig } from "../src/config";
import { testStore } from "./test-store";

const config: AppConfig = {
  authProvider: "header",
  authHeader: "X-Forwarded-Email",
  databaseType: "sqlite",
  baseUrl: "https://dahlia.example",
  oauthRedirectUris: [],
  maxRequestBytes: 1024,
};
const ownerHeaders = { "X-Forwarded-Email": "OWNER@example.com", origin: config.baseUrl };
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
    removeAdminUser: (email) => {
      const user = [...users.values()].find((candidate) => candidate.email === email && candidate.role === "admin");
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
  it("promotes the first authenticated user to administrator", async () => {
    const { store } = administrativeStore();
    const app = createApp({ config, authStore: store });
    const response = await app.request("/api/session", { headers: { "X-Forwarded-Email": "user@example.com" } });
    expect(await response.json()).toMatchObject({ capabilities: { admin: true } });
    expect((await app.request("/api/admin/members", {
      headers: { "X-Forwarded-Email": "user@example.com" },
    })).status).toBe(200);
  });

  it("fails administrator lookup closed without breaking the user session", async () => {
    const store = testStore({ isAdminUser: () => Promise.reject(new Error("database unavailable")) });
    const app = createApp({ config, authStore: store });
    const headers = { "X-Forwarded-Email": "user@example.com" };
    const session = await app.request("/api/session", { headers });
    expect(session.status).toBe(200);
    expect(await session.json()).toMatchObject({ capabilities: { admin: false } });
    expect((await app.request("/api/admin/members", { headers })).status).toBe(403);
  });

  it("does not expose model management endpoints", async () => {
    const { store } = administrativeStore();
    const app = createApp({ config, authStore: store });
    for (const [method, path] of [["GET", ""], ["POST", ""], ["PATCH", "/summary"], ["DELETE", "/summary"]]) {
      expect((await app.request(`/api/admin/models${path}`, { method, headers: ownerHeaders })).status).toBe(404);
    }
  });

  it("manages registered administrators and keeps at least one through the Dahlia API", async () => {
    const { store, users } = administrativeStore();
    const app = createApp({ config, authStore: store });

    await app.request("/api/session", { headers: ownerHeaders });
    await app.request("/api/session", { headers: { "X-Forwarded-Email": "second@example.com" } });

    const added = await app.request("/api/admin/members", {
      method: "POST",
      headers: ownerHeaders,
      body: JSON.stringify({ email: " SECOND@example.com " }),
    });
    expect(added.status).toBe(201);
    expect(users.get("second@example.com")?.role).toBe("admin");
    expect(await (await app.request("/api/admin/members", { headers: ownerHeaders })).json()).toMatchObject([
      { email: "owner@example.com", role: "admin", removable: true },
      { email: "second@example.com", role: "admin", removable: true },
    ]);
    expect((await app.request("/api/admin/members/second%40example.com", {
      method: "DELETE",
      headers: ownerHeaders,
    })).status).toBe(204);
    expect((await app.request("/api/admin/members/owner%40example.com", {
      method: "DELETE",
      headers: ownerHeaders,
    })).status).toBe(409);
  });
});
