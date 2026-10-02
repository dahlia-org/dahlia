import { createApp } from "../../src/app";
import { encodeId } from "../../src/typeid";
import { MeetingSyncService } from "../../src/sync/service";
import { SyncEvents } from "../../src/sync/events";
import documentFixture from "../../../desktop/Tests/DahliaTests/Fixtures/documents.json";
import { DocumentCore } from "../../src/documents/core";
import { createWorkerHandler, initializeWorkerApp, type WorkerEnv } from "../../src/worker";
import { createWorkerScreenshotTransformer } from "../../src/sync/worker-screenshot-transformer";
import { audioBase64 } from "../../src/summary/audio";
import { createHash } from "node:crypto";
import { connectPostgresUrl } from "../../src/db/postgres";
import { loadConfig } from "../../src/config";
import { createSearchEmbedder } from "../../src/search/embedding";
import { createImageCaptioner } from "../../src/image-analysis/captioner";
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
    if (path === "/runtime/documents") {
      const core = new DocumentCore(documentFixture.checkpoint);
      try {
        for (const update of documentFixture.updates) core.apply(update);
        assert.deepEqual(core.projection(), { text: documentFixture.text, blocks: documentFixture.blocks });
        const events = new SyncEvents(), watch = events.watch(["domain", "notes/fixture"], request.signal);
        try {
          watch.consume(); events.publish("domain"); events.publish("notes/fixture"); await watch.wait();
          assert.deepEqual([...watch.consume()].sort(), ["domain", "notes/fixture"]);
          watch.consume(); await watch.wait(); // Shared-DB fallback timer also works in workerd.
          assert.equal(events.pollInterval, 250);
        } finally { watch.close(); }
        return Response.json({ success: true });
      } finally { core.destroy(); }
    }
    if (path === "/runtime/document-capacity") {
      const concurrency = Number(new URL(request.url).searchParams.get("concurrency"));
      assert.ok(concurrency === 1 || concurrency === 2);
      const { checkpoint }: { checkpoint: string } = await request.json();
      const connection = connectPostgresUrl(env.DAHLIA_DATABASE_URL!, 4);
      try {
        const store = createPostgresApplicationStore(connection.db);
        const email = `capacity-${uuidV7()}@fixture.example.com`;
        const userId = (await store.resolveHeaderUser({ userId: email, email, source: "header" }))!;
        const identity = { userId, email, source: "header" as const };
        await store.addAdminUser(email);
        const organization = await store.organizations.create(identity, { name: "Capacity fixture", slug: `capacity-${uuidV7()}`, initialOwnerUserId: userId });
        const app = createApp({ config: { databaseType: "postgres", authProvider: "header", authHeader: "Cf-Access-Authenticated-User-Email", baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1_048_576 }, authStore: store });
        const documents = await Promise.all(Array.from({ length: concurrency }, async () => {
          const workspaceId = uuidV7(), meetingId = uuidV7(), documentId = uuidV7();
          await new MeetingSyncService(store.sync).commitTransaction(identity, { id: uuidV7(), schemaVersion: 3, workspaceId, createdAt: new Date().toISOString(), operations: [
            { id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null, data: { organizationId: organization.id, name: "Capacity", encryption: "none", createdAt: new Date().toISOString() } },
            { id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: { name: "Meeting", projectId: null, status: "READY", duration: null, recordingStartedAt: null, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } },
          ] });
          const document = await store.sync.withIdentity(identity, (scoped) => scoped.initializeMeetingNotes(workspaceId, meetingId, documentId));
          return { workspaceId, documentId, generation: document.generation };
        }));
        const began = performance.now();
        const results = await Promise.all(documents.map(async ({ workspaceId, documentId, generation }) => {
          const response = await app.request(`/api/v1/workspaces/${encodeId("workspace", workspaceId)}/documents/${encodeId("document", documentId)}/sync`, {
            method: "POST", headers: { "Cf-Access-Authenticated-User-Email": email, "content-type": "application/json" },
            body: JSON.stringify({ protocolVersion: 3, generation, vector: "AA==", update: checkpoint }),
          });
          assert.equal(response.status, 200);
          const result: { accepted: boolean; revision: number } = await response.json();
          assert.equal(result.accepted, true); return { accepted: result.accepted, revision: result.revision };
        }));
        return Response.json({ concurrency, durationMs: performance.now() - began, results });
      } finally { await connection.close(); }
    }
    if (path === "/runtime/sync-notifications") {
      const writer = connectPostgresUrl(env.DAHLIA_DATABASE_URL!, 2), readerConnection = connectPostgresUrl(env.DAHLIA_DATABASE_URL!, 2);
      let stream: ReadableStreamDefaultReader<Uint8Array> | undefined;
      try {
        const store = createPostgresApplicationStore(writer.db), readerStore = createPostgresApplicationStore(readerConnection.db);
        const email = `sync-${uuidV7()}@fixture.example.com`;
        const userId = (await store.resolveHeaderUser({ userId: email, email, source: "header" }))!;
        const identity = { userId, email, source: "header" as const };
        await store.addAdminUser(email);
        const organization = await store.organizations.create(identity, { name: "Sync fixture", slug: `sync-${uuidV7()}`, initialOwnerUserId: userId });
        const workspaceId = uuidV7(), meetingId = uuidV7(), documentId = uuidV7();
        await new MeetingSyncService(store.sync).commitTransaction(identity, { id: uuidV7(), schemaVersion: 3, workspaceId, createdAt: new Date().toISOString(), operations: [
          { id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null, data: { organizationId: organization.id, name: "Sync", encryption: "none", createdAt: new Date().toISOString() } },
          { id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: { name: "Meeting", projectId: null, status: "READY", duration: null, recordingStartedAt: null, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } },
        ] });
        const app = createApp({ config: { databaseType: "postgres", authProvider: "header", authHeader: "Cf-Access-Authenticated-User-Email", baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1_048_576 }, authStore: readerStore });
        const query = new URLSearchParams({ user: encodeId("user", userId), tab: uuidV7().replaceAll("-", ""), notes: JSON.stringify([{ workspaceId: encodeId("workspace", workspaceId), meetingId: encodeId("meeting", meetingId) }]) });
        const response = await app.request(`/api/v1/events?${query}`, { headers: { "Cf-Access-Authenticated-User-Email": email } });
        assert.equal(response.status, 200);
        stream = response.body!.getReader();
        const decoder = new TextDecoder(); let buffer = "";
        const nextDocument = async () => {
          while (true) {
            const boundary = buffer.indexOf("\n\n");
            if (boundary >= 0) {
              const frame = buffer.slice(0, boundary); buffer = buffer.slice(boundary + 2);
              if (frame.includes("event: document\n")) return frame;
            } else {
              const next = await stream!.read(); assert.equal(next.done, false); buffer += decoder.decode(next.value, { stream: true });
            }
          }
        };
        assert.match(await nextDocument(), /"cursor":"absent"/);
        // A separate connection/store writes, with no shared JS bus or PG NOTIFY.
        const doc = await store.sync.withIdentity(identity, (scoped) => scoped.initializeMeetingNotes(workspaceId, meetingId, documentId));
        let timeout: ReturnType<typeof setTimeout> | undefined;
        try {
          const frame = await Promise.race([nextDocument(), new Promise<never>((_, reject) => { timeout = setTimeout(() => reject(new Error("Worker Notes fallback timed out")), 2_000); })]);
          assert.ok(frame.includes(`${doc.generation}:${doc.revision}`));
        } finally { clearTimeout(timeout); }
        return Response.json({ success: true });
      } finally { await stream?.cancel(); await writer.close(); await readerConnection.close(); }
    }
    if (path === "/runtime/provider") {
      const backend = new URL(request.url).searchParams.get("backend")!;
      const config = loadConfig({ DAHLIA_AUTH_TYPE: "header", DAHLIA_AUTH_SECRET: env.DAHLIA_AUTH_SECRET, DAHLIA_AI_BACKEND: backend,
        OPENAI_BASE_URL: "https://api.cloudflare.com/client/v4/accounts/synthetic/ai/v1", OPENAI_API_KEY: "synthetic",
        DATABRICKS_HOST: "https://synthetic.example", DATABRICKS_CLIENT_ID: "synthetic", DATABRICKS_CLIENT_SECRET: "synthetic",
        DAHLIA_IMAGE_ANALYSIS_MODEL: backend === "cloudflare" ? "gpt-4.1" : "test.ai.gpt-5-6-luna",
        DAHLIA_SEARCH_EMBEDDING_MODEL: backend === "cloudflare" ? "@cf/baai/bge-m3" : "system.ai.embedding", DAHLIA_SEARCH_EMBEDDING_DIMENSIONS: "1024" });
      const transport: typeof fetch = (url) => Promise.resolve(String(url).endsWith("/token")
        ? Response.json({ access_token: "synthetic", expires_in: 3600 })
        : String(url).endsWith("/responses")
          ? Response.json({ status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: '{"ocr_text":"Test","caption":"A synthetic slide","informative":true,"reason":"A slide"}' }] }] })
          : Response.json(backend === "cloudflare" ? { success: true, result: { data: [Array(1024).fill(0.5)] } } : { data: [{ index: 0, embedding: Array(1024).fill(0.5) }] }));
      const caption = await createImageCaptioner(config, transport)!.analyze(new Uint8Array([1]), { outputLanguage: "ja" }, request.signal);
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
        await assert.rejects(store.organizations.delete(owner, invitationOnly.id));
        const workspaces = await store.sync.withIdentity(owner, (scoped) => scoped.listWorkspaces(invitationOnly.id));
        assert.equal(workspaces.length, 1);
        const workspaceId = workspaces[0]!.workspaceId;
        const confirmation = await store.sync.withIdentity(owner, (scoped) => scoped.confirmWorkspaceDeletion(invitationOnly.id, workspaceId));
        await store.sync.withIdentity(owner, (scoped) => scoped.forceDeleteWorkspace(invitationOnly.id, {
          schemaVersion: 3, id: uuidV7(), workspaceId, createdAt: new Date(), requestHash: "worker-governance-delete", operations: [],
        }, confirmation.revision, confirmation.changeCursor));
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
