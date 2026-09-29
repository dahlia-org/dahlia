import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { makeSignature } from "better-auth/crypto";
import { expect, it, vi } from "vitest";
import { createApp } from "../src/app";
import { createWorkerHandler } from "../src/worker";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { initializeDahliaAuth } from "../src/auth/better-auth";
import type { AppConfig } from "../src/config";

it.each(["node", "worker"])("accepts accounts cookies at the gateway with origin and session checks (%s)", async runtime => {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-gateway-session-"));
  const path = join(directory, "auth.sqlite");
  const config: AppConfig = { authProvider: "accounts", authHeader: "X-Forwarded-Email", databaseType: "sqlite",
    databaseUrl: `file:${path}`, baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1048576,
    betterAuthSecret: "test-only-gateway-session-secret-value", googleClientId: "test", googleClientSecret: "test",
    provider: { backend: "openai", baseUrl: "https://upstream.example/v1", apiKey: "provider-secret" }, foundationModels: ["gpt-5.6-luna"] };
  const store = createNodeApplicationStore(config);
  try {
    await store.migrate();
    const auth = await initializeDahliaAuth(config, store);
    const context = await auth.$context;
    const user = await context.internalAdapter.createUser({ name: "Owner", email: "owner@example.com", emailVerified: true }, { method: "email-password" });
    const session = await context.internalAdapter.createSession(user.id, false);
    const cookie = `${context.authCookies.sessionToken.name}=${encodeURIComponent(`${session.token}.${await makeSignature(session.token, config.betterAuthSecret!)}`)}`;
    const transport = vi.fn<typeof fetch>(async () => Response.json({ status: "completed", output: [] }));
    const app = createApp({ config, authStore: store, auth, fetch: transport, extensions: [{ registerRoutes(app) {
      app.post("/api/v1/test-session", c => c.json({ id: c.get("identity").userId }));
    } }] });
    const worker = createWorkerHandler(async () => app);
    const fetchWorker = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    const request = (path: string, headers: HeadersInit, method = "POST") => {
      const req = new Request(`${config.baseUrl}${path}`, { method, headers, ...(method === "POST" ? { body: JSON.stringify({ model: "gpt-5.6-luna", input: "draft", stream: false, store: false }) } : {}) });
      return runtime === "node" ? app.fetch(req) : fetchWorker(req, {} as Cloudflare.Env, {} as ExecutionContext);
    };
    const headers = { cookie, origin: config.baseUrl, "content-type": "application/json" };
    expect((await request("/api/v1/responses", headers)).status).toBe(200);
    expect((await request("/api/v1/models", { cookie }, "GET")).status).toBe(200);
    expect((await request("/api/v1/test-session", headers)).status).toBe(200);
    expect(transport).toHaveBeenCalledTimes(1);
    const upstreamHeaders = new Headers(transport.mock.calls[0]![1]?.headers);
    expect(upstreamHeaders.has("cookie")).toBe(false);
    for (const origin of ["https://attacker.example", "null"]) expect((await request("/api/v1/responses", { ...headers, origin })).status).toBe(403);
    expect((await request("/api/v1/responses", { cookie })).status).toBe(403);
    expect((await request("/api/v1/responses", { origin: config.baseUrl })).status).toBe(401);
    expect((await request("/api/v1/responses", { ...headers, authorization: "Bearer invalid" })).status).toBe(401);
    expect((await request("/api/v1/test-session", { ...headers, origin: "https://attacker.example" })).status).toBe(403);
    const db = new DatabaseSync(path);
    try {
      db.prepare('UPDATE session SET impersonated_by = ? WHERE id = ?').run(user.id, session.id);
      expect((await request("/api/v1/responses", headers)).status).toBe(401);
      db.prepare('DELETE FROM session WHERE id = ?').run(session.id);
      expect((await request("/api/v1/responses", headers)).status).toBe(401);
    } finally { db.close(); }
    expect(transport).toHaveBeenCalledTimes(1);
  } finally { await store.close?.(); rmSync(directory, { recursive: true, force: true }); }
});
