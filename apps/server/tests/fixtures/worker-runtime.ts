import { createWorkerHandler, initializeWorkerApp, type WorkerEnv } from "../../src/worker";
import { createWorkerScreenshotTransformer } from "../../src/sync/worker-screenshot-transformer";
import { audioBase64 } from "../../src/summary/audio";
import { createHash } from "node:crypto";
import { connectPostgresUrl } from "../../src/db/postgres";
import { loadConfig } from "../../src/config";
import { createSearchEmbedder } from "../../src/search/embedding";
import { createImageCaptioner } from "../../src/image-analysis/captioner";
import { DEFAULT_ACCOUNT_SETTINGS } from "../../src/account-settings";
import { sql } from "drizzle-orm";
import assert from "node:assert/strict";
import { createPostgresApplicationStore } from "../../src/auth/store";
import { initializeDahliaAuth } from "../../src/auth/better-auth";
import { uuidV7 } from "../../src/id";

// Synthetic, local-only routes; this module is never a deployment entry point.
const handler = createWorkerHandler(async (env) => {
  const app = await initializeWorkerApp(env);
  const jobs = app.jobs!;
  app.jobs = { ...jobs, consume: async (body, signal) => {
    await jobs.consume(body, signal);
    await env.DAHLIA_STORAGE!.put("queue-completed", new TextEncoder().encode("ok"), { httpMetadata: { cacheControl: "no-store", contentType: "text/plain" } });
  } };
  return app;
});
export default {
  ...handler,
  async fetch(request: Request<unknown, IncomingRequestCfProperties>, env: WorkerEnv, context: ExecutionContext) {
    const path = new URL(request.url).pathname;
    if (path === "/runtime/provider") {
      const backend = new URL(request.url).searchParams.get("backend")!;
      const config = loadConfig({ DAHLIA_AUTH_TYPE: "header", DAHLIA_AUTH_SECRET: env.DAHLIA_AUTH_SECRET, DAHLIA_AI_BACKEND: backend,
        OPENAI_BASE_URL: "https://api.cloudflare.com/client/v4/accounts/synthetic/ai/v1", OPENAI_API_KEY: "synthetic",
        DATABRICKS_HOST: "https://synthetic.example", DATABRICKS_CLIENT_ID: "synthetic", DATABRICKS_CLIENT_SECRET: "synthetic", DATABRICKS_MODEL_SCHEMA: "test.ai",
        DAHLIA_CAPTIONING_MODEL: backend === "cloudflare" ? "gpt-4.1" : "test.ai.gpt-5-6-luna",
        DAHLIA_EMBEDDING_MODEL: backend === "cloudflare" ? "@cf/baai/bge-m3" : "test.ai.embedding", DAHLIA_SEARCH_EMBEDDING_DIMENSIONS: "1024" });
      const transport: typeof fetch = (url) => Promise.resolve(String(url).endsWith("/token")
        ? Response.json({ access_token: "synthetic", expires_in: 3600 })
        : String(url).endsWith("/responses")
          ? Response.json({ status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: '{"ocr_text":"Test","caption":"A synthetic slide"}' }] }] })
          : Response.json(backend === "cloudflare" ? { success: true, result: { data: [Array(1024).fill(0.5)] } } : { data: [{ index: 0, embedding: Array(1024).fill(0.5) }] }));
      const caption = await createImageCaptioner(config, transport)!.analyze(new Uint8Array([1]), { ...DEFAULT_ACCOUNT_SETTINGS, outputLanguage: "ja" }, request.signal);
      const vector = await createSearchEmbedder(config, transport)!.embedQuery("synthetic", request.signal);
      return Response.json({ caption, dimensions: vector.length });
    }
    if (path === "/runtime/audio") {
      const bytes = new Uint8Array([1, 2, 3, 4, 5]);
      await env.DAHLIA_STORAGE!.put("audio", bytes, { httpMetadata: { cacheControl: "no-store", contentType: "audio/mp4" } });
      const object = await env.DAHLIA_STORAGE!.get("audio");
      const hash = `SHA-256:${createHash("sha256").update(bytes).digest("hex")}`;
      let encoded = "";
      for await (const chunk of audioBase64(new Response(object!.body), bytes.length, hash, request.signal)) encoded += chunk;
      return new Response(encoded);
    }
    if (path === "/runtime/image") {
      const object = await env.DAHLIA_STORAGE!.get("image");
      const output = await createWorkerScreenshotTransformer(env.IMAGES!)(object!.body!, 480);
      return new Response(output, { headers: { "content-type": "image/webp" } });
    }
    if (path === "/runtime/organization-participation") {
      const connection = connectPostgresUrl(env.DAHLIA_DATABASE_URL!, 1);
      try {
        const store = createPostgresApplicationStore(connection.db);
        const config = loadConfig({ DAHLIA_AUTH_TYPE: "accounts", DAHLIA_APP_URL: "http://localhost:5173", DAHLIA_AUTH_SECRET: env.DAHLIA_AUTH_SECRET,
          GOOGLE_CLIENT_ID: "synthetic", GOOGLE_CLIENT_SECRET: "synthetic" });
        const auth = await initializeDahliaAuth(config, store);
        const context = await auth.$context;
        const domain = `${uuidV7()}.example.com`;
        const register = async (name: string, emailVerified = true) => {
          const user = await context.internalAdapter.createUser({ name, email: `${name}@${domain}`, emailVerified }, { method: "oauth", oauth: { providerId: "google", profile: {} } });
          return { userId: user.id, source: "accounts" as const, email: user.email };
        };
        const owner = await register("owner"), existing = await register("existing");
        await store.addAdminUser(owner.email);
        const create = async (name: string) => store.organizations.create(owner, { name, slug: `${name}-${uuidV7()}`, initialOwnerUserId: owner.userId });
        const automatic = await create("auto"), another = await create("another"), approval = await create("approval"), invitationOnly = await create("invitation");
        for (const org of [automatic, another]) await store.organizations.updateDomains(owner, org.id, { domains: [{ domain, joinPolicy: "auto_join" }] });
        await store.organizations.updateDomains(owner, approval.id, { domains: [{ domain, joinPolicy: "need_approval" }] });
        await store.organizations.updateDomains(owner, invitationOnly.id, { domains: [{ domain }] });
        assert.equal((await store.organizations.getDomains(owner, invitationOnly.id)).domains[0]?.joinPolicy, "invite_only");
        const verified = await register("verified"), unverified = await register("unverified", false);
        assert(await store.organizations.hasMember(verified.userId, automatic.id));
        assert(await store.organizations.hasMember(verified.userId, another.id));
        assert(!await store.organizations.hasMember(unverified.userId, automatic.id));
        assert(!await store.organizations.hasMember(existing.userId, automatic.id));
        assert.equal((await store.organizations.candidates(existing)).length, 3);
        assert.deepEqual(await store.organizations.candidates(unverified), []);
        await assert.rejects(store.organizations.join(unverified, automatic.id, false));
        await assert.rejects(store.organizations.join(existing, invitationOnly.id, false));
        await Promise.all([store.organizations.join(existing, approval.id, true), store.organizations.join(existing, approval.id, true)]);
        const requests = await store.organizations.requests(existing);
        assert.equal(requests.length, 1);
        await store.organizations.resolveRequest(owner, requests[0]!.id, "approved");
        assert(await store.organizations.hasMember(existing.userId, approval.id));
        await store.organizations.join(existing, automatic.id, false);
        assert(await store.organizations.hasMember(existing.userId, automatic.id));
        await assert.rejects(store.organizations.updateDomains(owner, automatic.id, { domains: Array.from({ length: 11 }, (_, i) => ({ domain: `${i}.${domain}`, joinPolicy: "auto_join" })) }));
        await assert.rejects(store.organizations.create(existing, { name: "Denied", slug: `denied-${uuidV7()}`, initialOwnerUserId: owner.userId }));
        await assert.rejects(store.organizations.delete(owner, owner.userId));
        const session = await context.internalAdapter.createSession(owner.userId);
        await connection.db.execute(sql`UPDATE auth.session SET active_organization_id = ${invitationOnly.id} WHERE id = ${session.id}`);
        await store.organizations.delete(owner, invitationOnly.id);
        const cleared = await connection.db.execute(sql`SELECT active_organization_id FROM auth.session WHERE id = ${session.id}`);
        assert.equal(cleared.rows[0]?.active_organization_id, null);
        return Response.json({ passed: true });
      } finally { await connection.close(); }
    }
    if (path === "/runtime/database") {
      const connection = connectPostgresUrl(env.DAHLIA_DATABASE_URL!, 1);
      try {
        const result = await connection.db.execute(sql`select pg_backend_pid() as pid`);
        return Response.json(result.rows[0]);
      } finally { await connection.close(); }
    }
    return handler.fetch!(request, env, context);
  },
};
