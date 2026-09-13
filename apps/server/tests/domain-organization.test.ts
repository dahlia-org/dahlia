import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client } from "pg";
import { expect, it } from "vitest";

import { createApp } from "../src/app";
import { initializeDahliaAuth } from "../src/auth/better-auth";
import { createNodeAuthStore } from "../src/auth/node-store";
import type { AppConfig } from "../src/config";

// PostgreSQL requires a dedicated empty database; this test installs its migrations.
for (const databaseType of ["sqlite", "postgres"] as const) {
  it.runIf(databaseType === "sqlite" || process.env.TEST_AUTH_DATABASE_URL)(
    `preserves domain membership opt-out across sessions and store restart on ${databaseType}`,
    async () => {
      const directory = mkdtempSync(join(tmpdir(), "dahlia-default-organization-"));
      const config: AppConfig = {
        authProvider: "header", authHeader: "X-Forwarded-Email", databaseType,
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
        const signIn = async (email: string) => {
          const response = await auth.handler(new Request(`${config.baseUrl}/api/auth/header/sign-in`, { method: "POST", headers: { origin: config.baseUrl, "X-Forwarded-Email": email } }));
          expect(response.status).toBe(200);
          return { cookie: response.headers.getSetCookie().map((v) => v.split(";")[0]).join("; "), origin: config.baseUrl, "X-Forwarded-Email": email };
        };
        const headers = await signIn("first@example.com");
        const user = (await auth.api.getSession({ headers }))!.user;
        let app = createApp({ config, authStore: store, auth });
        expect((await app.request("/api/v1/session", { headers })).status).toBe(200);
        const organization = (await auth.api.listOrganizations({ headers })).find((org) => org.domain === "example.com")!;
        expect(await store.getServerOrganization(organization.id, 10, 0, 0)).toMatchObject({ members: [expect.objectContaining({ userId: user.id, role: "owner" })] });
        const secondHeaders = await signIn("second@example.com");
        await auth.api.leaveOrganization({ headers: secondHeaders, body: { organizationId: organization.id } });
        await signIn("second@example.com");
        expect((await store.getServerOrganization(organization.id, 10, 0, 0))?.members.map((member) => member.userId)).toEqual([user.id]);
        await store.close?.();
        store = createNodeAuthStore(config);
        app = createApp({ config, authStore: store, auth: await initializeDahliaAuth(config, store) });
        expect((await app.request("/api/v1/session", { headers: secondHeaders })).status).toBe(200);
        expect((await store.getServerOrganization(organization.id, 10, 0, 0))?.members.map((member) => member.userId)).toEqual([user.id]);
      } finally {
        await store.close?.();
        rmSync(directory, { recursive: true, force: true });
      }
    },
  );
}
