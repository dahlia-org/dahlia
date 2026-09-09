import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { serverMigrationManifest } from "../src/migrations";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { makeSignature } from "better-auth/crypto";
import { Client } from "pg";
import { expect, it } from "vitest";

import { createApp } from "../src/app";
import { initializeDahliaAuth } from "../src/auth/better-auth";
import { createNodeAuthStore } from "../src/auth/node-store";
import type { AppConfig } from "../src/config";

// PostgreSQL requires a dedicated empty database; this test installs its migrations.
for (const databaseType of ["sqlite", "postgres"] as const) {
  it.runIf(databaseType === "sqlite" || process.env.TEST_AUTH_DATABASE_URL)(
    `preserves default organization deletion across sessions and store restart on ${databaseType}`,
    async () => {
      const directory = mkdtempSync(join(tmpdir(), "dahlia-default-organization-"));
      const config: AppConfig = {
        authProvider: "accounts", authHeader: "X-Forwarded-Email", databaseType,
        databaseUrl: databaseType === "sqlite" ? `file:${join(directory, "auth.sqlite")}` : process.env.TEST_AUTH_DATABASE_URL,
        baseUrl: "http://localhost:5173", googleClientId: "google-client", googleClientSecret: "google-secret",
        betterAuthSecret: "test-only-better-auth-secret-value", oauthRedirectUris: [], maxRequestBytes: 1024,
      };
      if (databaseType === "postgres") {
        const client = new Client({ connectionString: config.databaseUrl });
        await client.connect();
        try {
          expect((await client.query("SELECT to_regnamespace('auth') AS auth, to_regnamespace('app') AS app")).rows)
            .toEqual([{ auth: null, app: null }]);
        } finally { await client.end(); }
      }
      let store = createNodeAuthStore(config);
      try {
        await store.migrate();
        const auth = await initializeDahliaAuth(config, store);
        const context = await auth.$context;
        const user = await context.internalAdapter.createUser({ name: "First user", email: "first@example.com", emailVerified: true }, { method: "oauth", oauth: { providerId: "google", profile: {} } });
        const session = await context.internalAdapter.createSession(user.id);
        const cookie = `${context.authCookies.sessionToken.name}=${encodeURIComponent(`${session.token}.${await makeSignature(session.token, config.betterAuthSecret!)}`)}`;
        const headers = { cookie, origin: config.baseUrl };
        let app = createApp({ config, authStore: store, auth });
        expect((await app.request("/api/session", { headers })).status).toBe(200);
        expect(await store.getExternalOrganization(user.id)).toMatchObject({ id: "external", role: "owner" });
        const deleted = await app.request("/api/auth/organization/delete", {
          method: "POST", headers: { ...headers, "content-type": "application/json" },
          body: JSON.stringify({ organizationId: "external" }),
        });
        expect(deleted.status, await deleted.text()).toBe(200);
        expect(await store.listServerOrganizations(10, 0)).toEqual([]);
        for (let attempt = 0; attempt < 2; attempt++) {
          expect((await app.request("/api/session", { headers })).status).toBe(200);
          expect(await store.listServerOrganizations(10, 0)).toEqual([]);
        }
        await store.close?.();
        store = createNodeAuthStore(config);
        app = createApp({ config, authStore: store, auth: await initializeDahliaAuth(config, store) });
        expect((await app.request("/api/session", { headers })).status).toBe(200);
        expect(await store.listServerOrganizations(10, 0)).toEqual([]);
      } finally {
        await store.close?.();
        rmSync(directory, { recursive: true, force: true });
      }
    },
  );
}

it("backfills existing SQLite default organizations without changing ownership", async () => {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-default-organization-upgrade-"));
  const path = join(directory, "auth.sqlite");
  const database = new DatabaseSync(path);
  const files = serverMigrationManifest.sqlite.files;
  try {
    for (const file of files.slice(0, -1)) database.exec(readFileSync(new URL(`../${file}`, import.meta.url), "utf8"));
    database.exec("INSERT INTO organization(id, name, slug, created_at) VALUES ('external', 'Custom name', 'external', 1000)");
    database.exec(readFileSync(new URL(`../${files.at(-1)!}`, import.meta.url), "utf8"));
    expect(database.prepare("SELECT name, initialized_at FROM server_initializations").all())
      .toEqual([{ name: "default_organization", initialized_at: 1000 }]);
    expect(database.prepare("SELECT name FROM organization").all()).toEqual([{ name: "Custom name" }]);
    expect(database.prepare("SELECT * FROM member").all()).toEqual([]);
    database.exec("DELETE FROM organization");
    expect(database.prepare("SELECT count(*) AS count FROM server_initializations").get()).toEqual({ count: 1 });
  } finally {
    database.close();
    rmSync(directory, { recursive: true, force: true });
  }
});
