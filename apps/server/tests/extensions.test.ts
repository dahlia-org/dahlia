import { describe, expect, it, vi } from "vitest";

import { createApp, type DahliaServerExtension, type GatewayExtensionContext } from "../src/app";
import type { AppConfig } from "../src/config";
import { composeMigrationManifests, serverMigrationManifest } from "../src/migrations";
import { testStore } from "./test-store";

const config: AppConfig = {
  authProvider: "header",
  authHeader: "X-Forwarded-Email",
  databaseType: "sqlite",
  baseUrl: "https://dahlia.example",
  oauthRedirectUris: [],
  maxRequestBytes: 1024,
};
const identityHeaders = { "X-Forwarded-Email": "user@example.com" };

describe("server extensions", () => {
  it("adds auth middleware, API routes, and session capabilities", async () => {
    const extension: DahliaServerExtension = {
      registerAuthRoutes(app) {
        app.use("/api/auth/extension/*", async (context) => context.json({ extension: true }, 418));
      },
      registerRoutes(app, services) {
        app.get("/api/extension", async (context) => {
          const identity = await services.browserIdentity(context.req.raw, context);
          return context.json({ workspaceId: identity.workspaceId });
        });
      },
      sessionCapabilities: () => ({ extension: true }),
    };
    const app = createApp({ config, authStore: testStore(), extensions: [extension] });

    expect((await app.request("/api/auth/extension/test")).status).toBe(418);
    expect((await app.request("/api/extension", { headers: identityHeaders })).status).toBe(200);
    expect(await (await app.request("/api/session", { headers: identityHeaders })).json())
      .toMatchObject({ capabilities: { extension: true } });
  });

  it("keeps core Gateway routes authoritative and authenticates added Gateway routes", async () => {
    const extension: DahliaServerExtension = {
      registerRoutes(app) {
        app.get("/api/v1/models", (context) => context.json({ shadowed: true }, 418));
        app.get("/api/v1/extension", (context) => context.json({ extension: true }));
      },
    };
    const app = createApp({ config, authStore: testStore(), extensions: [extension] });

    expect((await app.request("/api/v1/models")).status).toBe(401);
    expect((await app.request("/api/v1/extension")).status).toBe(401);
    const core = await app.request("/api/v1/models", { headers: identityHeaders });
    expect(core.status).toBe(200);
    expect(await core.json()).toEqual({ object: "list", data: [] });
    expect((await app.request("/api/v1/extension", { headers: identityHeaders })).status).toBe(200);
  });

  it("runs Gateway hooks in order and stops before the upstream", async () => {
    const order: string[] = [];
    const upstream = vi.fn();
    const extensions: DahliaServerExtension[] = [
      { beforeGateway: () => { order.push("first"); return Promise.resolve(undefined); } },
      {
        beforeGateway: () => {
          order.push("second");
          return Promise.resolve(Response.json({ error: "extension_denied" }, { status: 429 }));
        },
      },
      { beforeGateway: () => { order.push("third"); return Promise.resolve(undefined); } },
    ];
    const app = createApp({ config, authStore: testStore(), extensions, fetch: upstream });

    const response = await app.request("/api/v1/models", { headers: identityHeaders });
    expect(response.status).toBe(429);
    expect(order).toEqual(["first", "second"]);
    expect(upstream).not.toHaveBeenCalled();
  });

  it("exposes Gateway metadata without the request body", async () => {
    const hook = vi.fn((context: GatewayExtensionContext) => {
      void context;
      return Promise.resolve(Response.json({ stopped: true }, { status: 418 }));
    });
    const app = createApp({
      config,
      authStore: testStore(),
      extensions: [{ beforeGateway: hook }],
    });

    expect((await app.request("/api/v1/responses", {
      method: "POST",
      headers: identityHeaders,
      body: JSON.stringify({ model: "summary" }),
    })).status).toBe(418);
    expect(hook).toHaveBeenCalledWith(expect.objectContaining({
      method: "POST",
      path: "/api/v1/responses",
    }));
    expect(hook.mock.calls[0]?.[0]).not.toHaveProperty("request");
  });

  it("rejects duplicate session capability names", async () => {
    const extension: DahliaServerExtension = { sessionCapabilities: () => ({ admin: true }) };
    const app = createApp({ config, authStore: testStore(), extensions: [extension] });

    const response = await app.request("/api/session", { headers: identityHeaders });
    expect(response.status).toBe(500);
  });

  it("composes extension migrations after the Server migrations", () => {
    expect(composeMigrationManifests(serverMigrationManifest, {
      postgres: {
        directories: [{ id: "extension", path: "extension/drizzle" }],
        files: ["extension/drizzle/0000.sql"],
      },
      sqlite: {
        directories: [{
          id: "extension",
          path: "extension/drizzle/sqlite",
          files: ["0000_baseline/migration.sql"],
        }],
        files: ["extension/drizzle/sqlite/0000_baseline/migration.sql"],
      },
    })).toEqual({
      postgres: {
        directories: [
          ...serverMigrationManifest.postgres.directories,
          { id: "extension", path: "extension/drizzle" },
        ],
        files: [
          "drizzle/postgres/20260830001527_open_blue_shield/migration.sql",
          "extension/drizzle/0000.sql",
        ],
      },
      sqlite: {
        directories: [
          ...serverMigrationManifest.sqlite.directories,
          {
            id: "extension",
            path: "extension/drizzle/sqlite",
            files: ["0000_baseline/migration.sql"],
          },
        ],
        files: [
          "drizzle/sqlite/20260830001528_stiff_alex_power/migration.sql",
          "extension/drizzle/sqlite/0000_baseline/migration.sql",
        ],
      },
    });
  });
});
