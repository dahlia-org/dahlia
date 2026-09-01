import { describe, expect, it, vi } from "vitest";

import { createApp } from "../src/app";
import type { ModelAliasInput, ModelAliasRecord } from "../src/auth/store";
import type { AppConfig } from "../src/config";
import { testStore } from "./test-store";

const config: AppConfig = {
  authProvider: "header",
  authHeader: "X-Forwarded-Email",
  databaseType: "sqlite",
  baseUrl: "https://dahlia.example",
  adminEmail: "owner@example.com",
  oauthRedirectUris: [],
  maxRequestBytes: 1024,
};
const ownerHeaders = { "X-Forwarded-Email": "OWNER@example.com", origin: config.baseUrl };
const databricksConfig: AppConfig = {
  ...config,
  provider: { backend: "databricks", baseUrl: "https://workspace.example/ai-gateway/codex/v1" },
  databricksWorkspace: {
    host: "https://workspace.example",
    clientId: "app-client-id",
    clientSecret: "app-client-secret",
    tokenUrl: "https://workspace.example/oidc/v1/token",
  },
};

function administrativeStore() {
  const models: ModelAliasRecord[] = [];
  const administrators = new Map<string, Date>();
  const store = testStore({
    listModelAliases: () => Promise.resolve(models.toSorted((left, right) => left.alias.localeCompare(right.alias))),
    getEnabledModelAlias: (alias) => Promise.resolve(models.find((model) => model.alias === alias && model.enabled) ?? null),
    createModelAlias: (input: ModelAliasInput) => {
      if (models.some((model) => model.alias === input.alias)) return Promise.resolve(false);
      const now = new Date();
      models.push({ ...input, createdAt: now, updatedAt: now });
      return Promise.resolve(true);
    },
    updateModelAlias: (alias, update) => {
      const model = models.find((candidate) => candidate.alias === alias);
      if (!model) return Promise.resolve(false);
      Object.assign(model, update, { updatedAt: new Date() });
      return Promise.resolve(true);
    },
    deleteModelAlias: (alias) => {
      const index = models.findIndex((model) => model.alias === alias);
      if (index < 0) return Promise.resolve(false);
      models.splice(index, 1);
      return Promise.resolve(true);
    },
    listPlatformAdmins: () => Promise.resolve(
      [...administrators].map(([email, createdAt]) => ({ email, createdAt })).toSorted((a, b) => a.email.localeCompare(b.email)),
    ),
    isPlatformAdmin: (email) => Promise.resolve(administrators.has(email)),
    addPlatformAdmin: (email) => {
      if (administrators.has(email)) return Promise.resolve(false);
      administrators.set(email, new Date());
      return Promise.resolve(true);
    },
    deletePlatformAdmin: (email) => Promise.resolve(administrators.delete(email)),
  });
  return { administrators, models, store };
}

describe("administration", () => {
  it("starts without an administrator and keeps administration unavailable", async () => {
    const { store } = administrativeStore();
    const app = createApp({ config: { ...config, adminEmail: undefined }, authStore: store });
    const response = await app.request("/api/session", { headers: { "X-Forwarded-Email": "user@example.com" } });
    expect(await response.json()).toMatchObject({ capabilities: { admin: false } });
    expect((await app.request("/api/admin/models", {
      headers: { "X-Forwarded-Email": "user@example.com" },
    })).status).toBe(403);
  });

  it("fails administrator lookup closed without breaking the user session", async () => {
    const store = testStore({ isPlatformAdmin: () => Promise.reject(new Error("database unavailable")) });
    const app = createApp({ config: { ...config, adminEmail: undefined }, authStore: store });
    const headers = { "X-Forwarded-Email": "user@example.com" };
    const session = await app.request("/api/session", { headers });
    expect(session.status).toBe(200);
    expect(await session.json()).toMatchObject({ capabilities: { admin: false } });
    expect((await app.request("/api/admin/models", { headers })).status).toBe(403);
  });

  it("exposes admin capability and manages model aliases", async () => {
    const { store } = administrativeStore();
    const app = createApp({ config, authStore: store });

    const session = await app.request("/api/session", { headers: ownerHeaders });
    expect(await session.json()).toMatchObject({ capabilities: { admin: true } });

    const created = await app.request("/api/admin/models", {
      method: "POST",
      headers: ownerHeaders,
      body: JSON.stringify({ alias: "summary", upstreamModel: "provider/model", displayName: null, enabled: true }),
    });
    expect(created.status).toBe(201);
    expect(await created.json()).toMatchObject({ alias: "summary", upstreamModel: "provider/model", enabled: true });

    const updated = await app.request("/api/admin/models/summary", {
      method: "PATCH",
      headers: ownerHeaders,
      body: JSON.stringify({ upstreamModel: "provider/model", displayName: "Summary", enabled: false }),
    });
    expect(await updated.json()).toMatchObject({ alias: "summary", displayName: "Summary", enabled: false });
    expect((await app.request("/api/admin/models", { headers: ownerHeaders })).status).toBe(200);
    expect((await app.request("/api/admin/models/summary", { method: "DELETE", headers: ownerHeaders })).status).toBe(204);
  });

  it("exposes Databricks models with their saved enabled state", async () => {
    const { models, store } = administrativeStore();
    const longestAlias = "m".repeat(255);
    const now = new Date();
    models.push({
      alias: "gpt-5-6-luna",
      upstreamModel: "system.ai.gpt-5-6-luna",
      displayName: "GPT 5.6 Luna",
      enabled: true,
      createdAt: now,
      updatedAt: now,
    }, {
      alias: "missing",
      upstreamModel: "system.ai.missing",
      displayName: null,
      enabled: true,
      createdAt: now,
      updatedAt: now,
    });
    const upstream = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input).endsWith("/oidc/v1/token")) {
        return Response.json({ access_token: "app-token", expires_in: 3600 });
      }
      expect(new Headers(init?.headers).get("authorization")).toBe("Bearer app-token");
      return Response.json({ model_services: [
        { name: "model-services/system.ai.gpt-5-6-luna" },
        { name: "model-services/system.ai.gpt-5-6-sol" },
        { name: `model-services/system.ai.${longestAlias}` },
      ] });
    });
    const app = createApp({
      config: databricksConfig,
      authStore: store,
      fetch: upstream,
    });
    const headers = ownerHeaders;

    expect(await (await app.request("/api/session", { headers })).json())
      .toMatchObject({ capabilities: { admin: true, databricksModels: true } });
    const response = await app.request("/api/admin/models", { headers });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject([
      { alias: "gpt-5-6-luna", displayName: "GPT 5.6 Luna", enabled: true, configured: true },
      { alias: "gpt-5-6-sol", displayName: null, enabled: false, configured: false },
      { alias: longestAlias, upstreamModel: `system.ai.${longestAlias}`, configured: false },
    ]);
    expect((await app.request("/api/admin/models", {
      method: "POST",
      headers,
      body: JSON.stringify({
        alias: longestAlias,
        upstreamModel: `system.ai.${longestAlias}`,
        displayName: null,
        enabled: true,
      }),
    })).status).toBe(201);
    expect(upstream).toHaveBeenCalledTimes(2);
  });

  it("keeps Databricks model discovery failures private and uncached", async () => {
    const { store } = administrativeStore();
    const upstream = vi.fn(async (input: RequestInfo | URL) => String(input).endsWith("/oidc/v1/token")
      ? Response.json({ access_token: "app-token", expires_in: 3600 })
      : new Response("provider details", { status: 503 }));
    const app = createApp({
      config: databricksConfig,
      authStore: store,
      fetch: upstream,
    });
    const response = await app.request("/api/admin/models", {
      headers: ownerHeaders,
    });

    expect(response.status).toBe(502);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toMatchObject({
      error: { message: "Databricks model list is unavailable", code: "provider_models_unavailable" },
    });
    expect((await app.request("/api/admin/models", { headers: ownerHeaders })).status).toBe(502);
    expect(upstream).toHaveBeenCalledTimes(3);
  });

  it("validates aliases, origins, and administrator authorization", async () => {
    const { store } = administrativeStore();
    const app = createApp({ config, authStore: store });
    const body = JSON.stringify({ alias: "Not Valid", upstreamModel: "model", enabled: true });

    expect((await app.request("/api/admin/models", { method: "POST", headers: ownerHeaders, body })).status).toBe(400);
    expect((await app.request("/api/admin/models", {
      method: "POST",
      headers: ownerHeaders,
      body: JSON.stringify({ alias: "valid", upstreamModel: "m".repeat(768), enabled: true }),
    })).status).toBe(400);
    expect((await app.request("/api/admin/models", {
      method: "POST",
      headers: { "X-Forwarded-Email": "owner@example.com", origin: "https://attacker.example" },
      body,
    })).status).toBe(403);
    expect((await app.request("/api/admin/models", {
      headers: { "X-Forwarded-Email": "user@example.com" },
    })).status).toBe(403);
  });

  it("manages multiple database administrators while keeping the environment administrator immutable", async () => {
    const { administrators, store } = administrativeStore();
    const app = createApp({ config, authStore: store });

    const added = await app.request("/api/admin/members", {
      method: "POST",
      headers: ownerHeaders,
      body: JSON.stringify({ email: " SECOND@example.com " }),
    });
    expect(added.status).toBe(201);
    expect(administrators.has("second@example.com")).toBe(true);
    expect(await (await app.request("/api/admin/members", { headers: ownerHeaders })).json()).toMatchObject([
      { email: "owner@example.com", source: "environment", removable: false },
      { email: "second@example.com", source: "database", removable: true },
    ]);
    expect((await app.request("/api/admin/members/owner%40example.com", {
      method: "DELETE",
      headers: ownerHeaders,
    })).status).toBe(409);
    expect((await app.request("/api/admin/members/second%40example.com", {
      method: "DELETE",
      headers: ownerHeaders,
    })).status).toBe(204);
    expect(administrators.size).toBe(0);
  });
});
