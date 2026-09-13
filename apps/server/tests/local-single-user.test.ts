import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { createApp } from "../src/app";
import { initializeDahliaAuth } from "../src/auth/better-auth";
import { createNodeAuthStore } from "../src/auth/node-store";
import type { AppConfig } from "../src/config";

const directories: string[] = [];

function localConfig(localSingleUser: boolean): AppConfig {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-local-single-user-"));
  directories.push(directory);
  return {
    authProvider: "header",
    authHeader: "X-Forwarded-Email",
    localSingleUser,
    databaseType: "sqlite",
    databaseUrl: `file:${join(directory, "auth.sqlite")}`,
    baseUrl: "http://localhost:5173",
    betterAuthSecret: "test-only-better-auth-secret-value",
    oauthRedirectUris: [],
    maxRequestBytes: 1024,
  };
}

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

describe("local single-user header mode", () => {
  it("falls back to the fixed local user only when no proxy header is supplied", async () => {
    const config = localConfig(true);
    const store = createNodeAuthStore(config);
    try {
      await store.migrate();
      const app = createApp({ config, authStore: store, auth: await initializeDahliaAuth(config, store) });

      const response = await app.request("/api/v1/session");
      expect(response.status).toBe(200);
      const session = await response.json<{ user: { id: string; email: string }; workspace: { id: string } }>();
      expect(session.user.email).toBe("local@example.com");
      // The substituted email is projected onto an internal user exactly as a proxied identity is.
      expect(session.user.id).not.toBe("local@example.com");
      expect(session.workspace.id).toBe(`personal:${session.user.id}`);
      // The first user is promoted to administrator and stores the substituted email.
      expect(await store.listAdminUsers()).toMatchObject([{ email: "local@example.com", name: "local@example.com" }]);
      // Better Auth Header sign-in runs on the same substituted identity, so a cookie is issued.
      expect(response.headers.getSetCookie().length).toBeGreaterThan(0);

      // A supplied identity header still wins and resolves to its own user.
      const proxied = await app.request("/api/v1/session", { headers: { "X-Forwarded-Email": "person@example.com" } });
      expect(proxied.status).toBe(200);
      const other = await proxied.json<{ user: { id: string; email: string } }>();
      expect(other.user.email).toBe("person@example.com");
      expect(other.user.id).not.toBe(session.user.id);

      // Dropping the header returns to the local user, so the fallback is additive.
      expect(await (await app.request("/api/v1/session")).json())
        .toMatchObject({ user: { id: session.user.id, email: "local@example.com" } });
    } finally {
      await store.close?.();
    }
  });

  it("accepts a non-email header value and skips domain Organization enrollment", async () => {
    const config = localConfig(true);
    const store = createNodeAuthStore(config);
    try {
      await store.migrate();
      const app = createApp({ config, authStore: store, auth: await initializeDahliaAuth(config, store) });

      const response = await app.request("/api/v1/session", { headers: { "X-Forwarded-Email": " Garbage " } });
      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({ user: { email: "garbage" } });
      expect(await store.listAdminUsers()).toMatchObject([{ email: "garbage", name: "garbage" }]);

      // "garbage" carries no domain, so only the Personal Organization exists.
      expect(await store.listServerOrganizations(10, 0)).toMatchObject([{ name: "Personal", kind: "personal" }]);

      // An address with a domain still enrolls into its domain Organization.
      expect((await app.request("/api/v1/session", { headers: { "X-Forwarded-Email": "person@example.com" } })).status).toBe(200);
      expect(await store.listServerOrganizations(10, 0))
        .toMatchObject([{ name: "Personal", kind: "personal" }, { name: "Personal", kind: "personal" }, { name: "example.com", kind: "team" }]);
    } finally {
      await store.close?.();
    }
  });

  it("keeps requiring the proxy header while it is disabled", async () => {
    const config = localConfig(false);
    const store = createNodeAuthStore(config);
    try {
      await store.migrate();
      const app = createApp({ config, authStore: store, auth: await initializeDahliaAuth(config, store) });

      expect((await app.request("/api/v1/session")).status).toBe(401);
      expect((await app.request("/api/v1/session", { headers: { "X-Forwarded-Email": "garbage" } })).status).toBe(401);
      expect((await app.request("/api/v1/session", { headers: { "X-Forwarded-Email": "user@example.com" } })).status).toBe(200);
    } finally {
      await store.close?.();
    }
  });
});
