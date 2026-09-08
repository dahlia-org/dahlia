import { LocalObjectStorage } from "../src/storage/local";
import { createAudioSummaryMethod } from "../src/summary/audio";
import { DEFAULT_ACCOUNT_SETTINGS } from "../src/account-settings";
import { TextContentDigest } from "../src/sync/text-content";
import { summaryMetadata } from "../src/summary/metadata";
import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { MeetingSyncService } from "../src/sync/service";
import { SummaryService } from "../src/summary/service";
import { SummaryWorker } from "../src/summary/node-worker";
import { SummaryError, summaryDocument, type SummaryMethod } from "../src/summary/model";
import { createTranscriptSummaryMethod, summaryImageContent } from "../src/summary/transcript";
import { accountSettingsPatchSchema } from "../src/account-settings";
import { loadConfig } from "../src/config";
import { createApp } from "../src/app";
import { createWorkerHandler } from "../src/worker";
import { uuidV7 } from "../src/id";
import type { AppConfig } from "../src/config";
import type { Identity } from "../src/auth/identity";

const dirs: string[] = [];
afterEach(() => { vi.restoreAllMocks(); for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true }); });
const owner: Identity = { userId: "owner", workspaceId: "personal:owner", source: "header" };
const output = { title: "Decisions", description: "Launch discussion", tags: ["launch"], action_items: [],
  sections: [{ heading: "Decisions", blocks: [{ type: "paragraph", level: 3, content: { text: "Ship next week", transcript_ref: null }, items: [], language: "", image_id: "" }] }] };
const doc = () => summaryDocument(output, new Set());
async function setup() {
  const dir = mkdtempSync(join(tmpdir(), "dahlia-summary-")); dirs.push(dir);
  const path = join(dir, "db.sqlite");
  const config: AppConfig = { authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite", databaseUrl: `file:${path}`,
    baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1_048_576, syncSharingEnabled: true };
  const store = createNodeApplicationStore(config); await store.migrate(); await store.ensureIdentityUser(owner);
  const sync = new MeetingSyncService(store.sync, new LocalObjectStorage(join(dir, "recordings"))); const vaultId = uuidV7(); const meetingId = uuidV7();
  await sync.commitTransaction(owner, { schemaVersion: 2, id: uuidV7(), vaultId, createdAt: new Date().toISOString(), operations: [
    { id: uuidV7(), entity: "vault", action: "create", entityId: vaultId, baseRevision: null, data: { name: "Vault", createdAt: new Date().toISOString() } },
    { id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
      data: { name: "Meeting", description: "", status: "READY", projectId: null, duration: 60, recordingStartedAt: new Date().toISOString(), createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } },
  ] });
  const method: SummaryMethod = { id: "transcript", captureSettings: (settings, detail) => ({ ...settings.summary.methodSettings.transcript, detail: detail ?? settings.summary.detail }), version: vi.fn(async () => "version1"), generate: vi.fn(async () => doc()) };
  const service = new SummaryService(store.sync, store.accountSettings, [method]);
  return { store, sync, method, service, vaultId, meetingId, config, path };
}

describe("server summary jobs", () => {
  it("escapes meeting and project XML without serializing internal input fields", async () => {
    const date = new Date(0);
    const { content } = await summaryImageContent({
      meeting: { name: '<Meeting & "team">', description: "</context>'", createdAt: date, recordingStartedAt: null },
      project: { name: "<Project>", description: "A&B", path: "parent/<child>", revision: 42 }, images: [],
    }, {} as MeetingSyncService, owner, new AbortController().signal);
    expect(content).toEqual([{ type: "input_text", text: `<context>
  <meeting>
    <name>&lt;Meeting &amp; &quot;team&quot;&gt;</name>
    <description>&lt;/context&gt;&apos;</description>
    <recorded_at>1970-01-01T00:00:00.000Z</recorded_at>
  </meeting>
  <project>
    <name>&lt;Project&gt;</name>
    <description>A&amp;B</description>
    <path>parent/&lt;child&gt;</path>
  </project>
</context>` }]);
  });

  it.each(["node", "worker"])("advertises only registered capabilities through %s", async (runtime) => {
    const { store, method, config } = await setup();
    try {
      const methods: SummaryMethod[] = [method, { ...method, id: "audio" }];
      const app = createApp({ config, authStore: store, imageAnalysisEnabled: true,
        summaryService: new SummaryService(store.sync, store.accountSettings, methods) });
      const worker = createWorkerHandler(async () => app);
      const fetch = worker.fetch!.bind(worker) as unknown as
        (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
      const send = (authenticated: boolean) => {
        const request = new Request("http://localhost:5173/api/v1/capabilities", {
          headers: authenticated ? { "X-Forwarded-Email": "owner@example.com" } : {},
        });
        return runtime === "node" ? app.request(request) : fetch(request, {} as Cloudflare.Env, {} as ExecutionContext);
      };
      expect((await send(false)).status).toBe(401);
      expect(await (await send(true)).json()).toEqual({
        sync: { version: 4 }, recordingArchive: { version: 1 }, meetingEvents: { version: 1 },
        search: { version: 1 }, imageAnalysis: { version: 1 },
        meetingSummaryGeneration: { version: 1, sources: ["transcript", "audio"] },
      });
      methods.length = 0;
      expect(await (await send(true)).json()).not.toHaveProperty("meetingSummaryGeneration");
      vi.spyOn(store.sync, "isAvailable").mockResolvedValueOnce(false);
      expect(await (await send(true)).json()).toEqual({});
    } finally { await store.close?.(); }
  });

  it("keeps immutable versions, pages without bodies, and deletes all versions atomically", async () => {
    const { store, sync, method, service, vaultId, meetingId } = await setup();
    try {
      expect(await sync.latestSummary(owner, vaultId, meetingId)).toMatchObject({ revision: 0, present: false });
      method.generate = async (job) => ({ ...doc(), metadata: {
        generatedBy: "server", inputTypes: ["transcript"], detailLevel: job.settings.detail, outputLanguage: job.outputLanguage,
        request: { model: job.settings.model, reasoning: { effort: job.settings.reasoningEffort } },
        response: { model: "returned-model", usage: { input_tokens: 10, output_tokens_details: { reasoning_tokens: 2 } } },
      } });
      for (const [model, reasoningEffort] of [["first-model", "low"], ["second-model", "high"]] as const) {
        await store.accountSettings.update(owner.userId, { summary: { methodSettings: { transcript: { model, reasoningEffort } } } });
        await service.start(owner, vaultId, meetingId, { id: uuidV7() });
        await new SummaryWorker(store.summaryJobs, [method], sync).processOne();
      }
      const first = await sync.summaryVersion(owner, vaultId, meetingId, "1");
      expect(first).not.toHaveProperty("kind");
      expect(first).not.toHaveProperty("generation");
      expect(first.metadata).toMatchObject({ generatedBy: "server", inputTypes: ["transcript"], detailLevel: "detailed" });
      expect(first.metadata).not.toHaveProperty("source");
      expect(first.metadata).not.toHaveProperty("method");
      expect(first.metadata?.request).toEqual({ model: "first-model", reasoning: { effort: "low" } });
      expect(first.metadata?.response?.usage?.total_tokens).toBeUndefined();
      const second = await sync.summaryVersion(owner, vaultId, meetingId, "2");
      expect(second.metadata?.request.reasoning?.effort).toBe("high");
      expect((await sync.latestSummary(owner, vaultId, meetingId)).record?.document).toBe(second.document);
      const manifest = await sync.latestSummary(owner, vaultId, meetingId, "1");
      expect(manifest).not.toHaveProperty("record");
      const digest = new TextContentDigest(); digest.add(second.document);
      expect(manifest).toMatchObject({ revision: 2, sha256: digest.digestHex(), byteCount: digest.byteCount });
      const transaction = { schemaVersion: 2, id: uuidV7(), vaultId, createdAt: new Date().toISOString(), operations: [{
        id: uuidV7(), entity: "summary", action: "upsert", entityId: meetingId, baseRevision: 2,
        data: { title: "Manual", document: JSON.stringify({ ...doc(), title: "Manual" }), createdAt: new Date().toISOString() },
      }] };
      await expect(sync.commitTransaction(owner, { ...transaction, id: uuidV7(), operations: [{ ...transaction.operations[0],
        data: { ...transaction.operations[0]!.data, document: JSON.stringify({ ...doc(), metadata: { generatedBy: "server", response: { usage: { input_tokens: -1 } } } }) },
      }] })).rejects.toMatchObject({ status: 400 });
      await sync.commitTransaction(owner, transaction);
      await sync.commitTransaction(owner, transaction);
      expect((await sync.summaryVersion(owner, vaultId, meetingId, "3")).metadata).toBeNull();
      expect(await sync.summaryVersion(owner, vaultId, meetingId, "1")).toEqual(first);
      const page = await sync.summaryVersions(owner, vaultId, meetingId, undefined, "2");
      expect(page.items.map((row) => row.revision)).toEqual([3, 2]);
      expect(page.items[0]).not.toHaveProperty("document");
      expect(page.items[0]).not.toHaveProperty("kind");
      expect((await sync.summaryVersions(owner, vaultId, meetingId, page.nextCursor!, "2")).items.map((row) => row.revision)).toEqual([1]);
      await expect(sync.commitTransaction(owner, { ...transaction, id: uuidV7() })).rejects.toMatchObject({ status: 409 });
      expect((await sync.summaryVersions(owner, vaultId, meetingId)).items).toHaveLength(3);
      await sync.commitTransaction(owner, { schemaVersion: 2, id: uuidV7(), vaultId, createdAt: new Date().toISOString(), operations: [
        { id: uuidV7(), entity: "summary", action: "delete", entityId: meetingId, baseRevision: 3, data: {} },
      ] });
      expect(await sync.latestSummary(owner, vaultId, meetingId)).toMatchObject({ revision: 4, present: false });
      expect((await sync.summaryVersions(owner, vaultId, meetingId)).items).toEqual([]);
      await expect(sync.summaryVersion(owner, vaultId, meetingId, "1")).rejects.toMatchObject({ status: 404 });
    } finally { await store.close?.(); }
  });

  it("serves latest and history without metadata support and applies current shared permissions", async () => {
    const { store, sync, config, path, vaultId, meetingId } = await setup();
    const savedDocument = JSON.stringify(doc());
    try {
      await sync.commitTransaction(owner, { schemaVersion: 2, id: uuidV7(), vaultId, createdAt: new Date().toISOString(), operations: [{
        id: uuidV7(), entity: "summary", action: "upsert", entityId: meetingId, baseRevision: 0,
        data: { title: "Saved", document: savedDocument, createdAt: new Date().toISOString() },
      }] });
      const app = createApp({ config, authStore: store });
      const headers = { "x-forwarded-email": "reader@example.com", "x-forwarded-user": "reader" };
      const base = `/api/v1/vaults/${vaultId}/meetings/${meetingId}/summary`;
      const routes = ["/latest", "", "/1"];
      for (const route of routes) {
        expect((await app.request(`${base}${route}`)).status).toBe(401);
        expect((await app.request(`${base}${route}`, { headers })).status).toBe(404);
      }
      const db = new DatabaseSync(path);
      try {
        db.prepare("INSERT INTO vault_permissions(vault_id, principal_type, principal_id, role, granted_by_user_id, created_at) VALUES (?, 'user', 'reader', 'member', 'owner', ?)").run(vaultId, Date.now());
        for (const route of routes) {
          const response = await app.request(`${base}${route}`, { headers });
          expect(response.status).toBe(200);
          expect(response.headers.get("cache-control")).toBe("no-store");
        }
        for (const meetingPath of [`/api/v1/vaults/${vaultId}/meetings/${meetingId}`, `/api/v1/meetings/${meetingId}`]) {
          const response = await app.request(meetingPath, { headers });
          expect(response.status).toBe(200);
          const meeting = await response.json();
          expect(meeting).toMatchObject({ meetingId, name: "Meeting", revision: 1, summaryRevision: 1,
            transcriptRevision: 0, isRecording: false, contentOmitted: true, hasSummary: true });
          for (const key of ["summaryTitle", "summaryDocument", "summaryCreatedAt"]) expect(meeting).not.toHaveProperty(key);
        }
        const page: { items: Record<string, unknown>[] } = await (await app.request(`${base}?limit=1`, { headers })).json();
        expect(page).toMatchObject({ items: [{ revision: 1, title: "Saved" }], nextCursor: null });
        expect(page.items[0]).not.toHaveProperty("document");
        expect(await (await app.request(`${base}?cursor=1`, { headers })).json()).toMatchObject({ items: [] });
        const latest: { sha256: string; byteCount: number; record: { document: string } } = await (await app.request(`${base}/latest`, { headers })).json();
        expect(latest).toMatchObject({ revision: 1, present: true, record: { title: "Saved", document: savedDocument } });
        const manifest = await (await app.request(`${base}/latest?manifest=1`, { headers })).json();
        expect(manifest).toMatchObject({ revision: 1, sha256: latest.sha256, byteCount: latest.byteCount });
        expect(manifest).not.toHaveProperty("record");
        expect(await (await app.request(`${base}/1`, { headers })).json()).toMatchObject({ revision: 1, document: latest.record.document });
        for (const suffix of ["versions", "versions/1", "invalid", "1.5", "-1"]) {
          expect((await app.request(`${base}/${suffix}`, { headers })).status).toBe(404);
        }
        expect((await app.request(`${base}/2`, { headers })).status).toBe(404);
        // The fixed job route must retain its existing unavailable-service behavior.
        expect(await (await app.request(`${base}/job`, { headers })).json()).toEqual({ error: "summary_unavailable" });
        expect((await app.request(`/api/v1/vaults/${vaultId}/text/summary/${meetingId}?revision=1`, { headers })).status).toBe(404);
        expect((await app.request(`${base}/latest?manifest=invalid`, { headers })).status).toBe(400);
        expect((await app.request(`${base}?limit=101`, { headers })).status).toBe(400);
        expect((await app.request(`${base}/999999999999`, { headers })).status).toBe(400);
        db.prepare("DELETE FROM vault_permissions WHERE principal_id = 'reader'").run();
        for (const route of routes) expect((await app.request(`${base}${route}`, { headers })).status).toBe(404);
      } finally { db.close(); }
    } finally { await store.close?.(); }
  });

  it("backfills existing summaries without inventing metadata metadata", async () => {
    const { store, path, vaultId, meetingId } = await setup();
    try {
      const db = new DatabaseSync(path);
      try {
        const document = JSON.stringify(doc());
        db.prepare("UPDATE meetings SET summary_title = 'Old', summary_document = ?, summary_created_at = 1234, summary_revision = 7 WHERE meeting_id = ?").run(document, meetingId);
        db.exec(readFileSync(new URL("../drizzle/sqlite/20260908040515_summary_version_backfill/migration.sql", import.meta.url), "utf8"));
        expect(db.prepare("SELECT vault_id, meeting_id, revision, title, document, created_at, metadata FROM summary_versions").get()).toEqual({
          vault_id: vaultId, meeting_id: meetingId, revision: 7, title: "Old", document, created_at: 1234, metadata: null,
        });
        db.prepare("DELETE FROM meetings WHERE meeting_id = ?").run(meetingId);
        expect(db.prepare("SELECT * FROM summary_versions").all()).toEqual([]);
      } finally { db.close(); }
    } finally { await store.close?.(); }
  });

  it("reads persisted settings from the consolidated summary column", async () => {
    const { store, path } = await setup();
    try {
      await store.accountSettings.update(owner.userId, { outputLanguage: "en" });
      const database = new DatabaseSync(path);
      database.prepare("UPDATE account_settings SET summary = ? WHERE user_id = ?")
        .run(JSON.stringify({ ...DEFAULT_ACCOUNT_SETTINGS.summary, detail: "concise", methodSettings: {
          ...DEFAULT_ACCOUNT_SETTINGS.summary.methodSettings, transcript: { model: "existing-model", reasoningEffort: "high" },
        } }), owner.userId);
      database.close();
      expect(await store.accountSettings.get(owner.userId)).toMatchObject({ outputLanguage: "en", summary: {
        method: "transcript", detail: "concise", methodSettings: { transcript: { model: "existing-model", reasoningEffort: "high" } },
      } });
    } finally { await store.close?.(); }
  });

  it("fixes settings at start, keeps starts idempotent and saves through canonical delta and search", async () => {
    const { store, sync, method, service, vaultId, meetingId } = await setup();
    try {
      await store.accountSettings.update(owner.userId, { summary: { detail: "standard", methodSettings: { transcript: { model: "model1", reasoningEffort: "high" } } } });
      const id = uuidV7(); const job = await service.start(owner, vaultId, meetingId, { id, detail: "concise" });
      await store.accountSettings.update(owner.userId, { outputLanguage: "en", summary: { detail: "detailed", methodSettings: { transcript: { model: "model2", reasoningEffort: "low" } } } });
      expect(await service.start(owner, vaultId, meetingId, { id, detail: "concise" })).toEqual(job);
      expect(job.settings).toEqual({ model: "model1", reasoningEffort: "high", detail: "concise" });
      expect(job.outputLanguage).toBe("ja");
      await expect(service.start(owner, vaultId, meetingId, { id, detail: "detailed" })).rejects.toMatchObject({ status: 409 });
      await expect(service.start(owner, vaultId, meetingId, { id: uuidV7() })).rejects.toMatchObject({ status: 409 });
      const cursor = await sync.latestCursor(owner);
      expect(await new SummaryWorker(store.summaryJobs, [method], sync).processOne()).toBe(true);
      expect((await service.status(owner, vaultId, meetingId))?.status).toBe("succeeded");
      const meeting = await store.sync.withIdentity(owner, (scoped) => scoped.getMeeting(vaultId, meetingId));
      expect(JSON.parse(meeting!.summaryDocument!)).toMatchObject({ schemaVersion: 3, title: "Decisions", actionItems: [] });
      expect(meeting?.summaryRevision).toBe(1);
      expect(await sync.latestCursor(owner)).not.toBe(cursor);
      expect((await sync.searchText(owner, vaultId, "Ship", "meeting")).items).toMatchObject([{ meetingId }]);
    } finally { await store.close?.(); }
  });

  it.each(["input", "summary", "deleted"])("preserves canonical data after %s changes", async (change) => {
    const { store, sync, method, service, vaultId, meetingId } = await setup();
    try {
      await service.start(owner, vaultId, meetingId, { id: uuidV7() });
      method.generate = async () => {
        if (change === "input") method.version = async () => "version2";
        else await sync.commitTransaction(owner, { schemaVersion: 2, id: uuidV7(), vaultId, createdAt: new Date().toISOString(), operations: [{
          id: uuidV7(), entity: change === "deleted" ? "meeting" : "summary", action: change === "deleted" ? "delete" : "upsert", entityId: meetingId,
          baseRevision: change === "deleted" ? 1 : 0, data: change === "deleted" ? null : { title: "Manual", document: JSON.stringify({ ...doc(), title: "Manual" }), createdAt: new Date().toISOString() },
        }] });
        return doc();
      };
      await new SummaryWorker(store.summaryJobs, [method], sync).processOne();
      const meeting = await store.sync.withIdentity(owner, (scoped) => scoped.getMeeting(vaultId, meetingId));
      if (change === "deleted") expect(meeting).toBeNull();
      else { expect(meeting?.summaryTitle).toBe(change === "summary" ? "Manual" : null); expect((await service.status(owner, vaultId, meetingId))?.status).toBe("failed"); }
    } finally { await store.close?.(); }
  });

  it("recovers expired leases across restart, rejects stale claims and bounds attempts", async () => {
    const setupValue = await setup(); const { store, service, vaultId, meetingId, config, path, method } = setupValue;
    await service.start(owner, vaultId, meetingId, { id: uuidV7() });
    const stale = (await store.summaryJobs.claim())!; await store.close?.();
    const raw = new DatabaseSync(path); raw.exec("UPDATE summary_jobs SET lease_expires_at = 0"); raw.close();
    const reopened = createNodeApplicationStore(config); const sync = new MeetingSyncService(reopened.sync);
    try {
      const current = (await reopened.summaryJobs.claim())!;
      expect(current.attempts).toBe(2);
      expect(await sync.completeSummary(owner, stale, doc(), method)).toBe(false);
      await reopened.summaryJobs.fail(current, "temporary", true);
      const raw = new DatabaseSync(path); raw.exec("UPDATE summary_jobs SET available_at = 0"); raw.close();
      method.generate = async () => { throw new SummaryError("temporary", true); };
      await new SummaryWorker(reopened.summaryJobs, [method], sync).processOne();
      expect(await new SummaryService(reopened.sync, reopened.accountSettings, [method]).status(owner, vaultId, meetingId)).toMatchObject({ status: "failed", attempts: 3 });
      expect(await reopened.summaryJobs.claim()).toBeNull();
    } finally { await reopened.close?.(); }
  });

  it("authorizes API owners, rejects unknown methods and disables unsupported runtime capability", async () => {
    const { store, service, config, vaultId, meetingId } = await setup();
    try {
      const app = createApp({ config, authStore: store, summaryService: service });
      const headers = { "x-forwarded-email": "owner@example.com", "x-forwarded-user": "owner", "content-type": "application/json" };
      const path = `/api/v1/vaults/${vaultId}/meetings/${meetingId}/summary`;
      expect((await app.request(`${path}/job`)).status).toBe(401);
      expect((await app.request(`${path}/job`, { headers: { ...headers, "x-forwarded-user": "other", "x-forwarded-email": "other@example.com" } })).status).toBe(404);
      expect((await app.request(path, { method: "POST", headers: { ...headers, origin: "https://evil.example" }, body: JSON.stringify({ id: uuidV7() }) })).status).toBe(403);
      expect((await app.request(path, { method: "POST", headers, body: JSON.stringify({ id: uuidV7(), method: "gemini" }) })).status).toBe(400);
      expect(accountSettingsPatchSchema.safeParse({ summaryMethod: "gemini" }).success).toBe(false);
      expect(accountSettingsPatchSchema.parse({ outputLanguage: "en" })).toEqual({ outputLanguage: "en" });
      const body = JSON.stringify({ id: uuidV7() });
      const response = await app.request(path, { method: "POST", headers, body });
      expect(response.status).toBe(202);
      expect(response.headers.get("Location")).toBe(`${path}/job`);
      const result = await response.json();
      expect(result).toMatchObject({ job: { status: "pending" } });
      const status = await app.request(response.headers.get("Location")!, { headers });
      expect(status.status).toBe(200);
      expect(await status.json()).toEqual(result);
      const replay = await app.request(path, { method: "POST", headers, body });
      expect(replay.status).toBe(202);
      expect(replay.headers.get("Location")).toBe(`${path}/job`);
      expect(await replay.json()).toEqual(result);
      for (const method of ["GET", "POST"]) {
        expect((await app.request(`${path}-job`, { method, headers })).status).toBe(404);
      }
      const portable = createApp({ config, authStore: store });
      expect(await (await portable.request("/api/v1/capabilities", { headers })).json()).not.toHaveProperty("meetingSummaryGeneration");
      expect((await app.request("/api/v1/summary/methods", { headers })).status).toBe(404);
      expect(await (await app.request("/api/v1/capabilities", { headers })).json()).toMatchObject({ meetingSummaryGeneration: { version: 1, sources: ["transcript"] } });
      expect((await portable.request(path, { method: "POST", headers, body: "{}" })).status).toBe(503);
    } finally { await store.close?.(); }
  });

  it.each(["short", "qualified", "failure"])("shares model resolution and safe diagnostics (%s)", async (scenario) => {
    const withImages = scenario === "qualified";
    const { store, sync, vaultId, meetingId } = await setup();
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      await store.accountSettings.update(owner.userId, { summary: { methodSettings: { transcript: {
        model: withImages ? "catalog.ai.gpt-5-6-luna" : "gpt-5-6-luna", reasoningEffort: "medium",
      } } } });
      const patchId = uuidV7(); const hash = "a".repeat(64);
      await sync.putTranscriptChunk(owner, vaultId, meetingId, patchId, 0, hash, {
        segments: [{ segmentId: uuidV7(), startedAt: new Date().toISOString(), endedAt: null,
          text: "Ship next week < & > \" '", createdAt: null, audioSource: "mic", speakerLabel: "A&B" }], deletions: [],
      });
      await sync.commitTransaction(owner, { schemaVersion: 2, id: uuidV7(), vaultId, createdAt: new Date().toISOString(), operations: [{
        id: patchId, entity: "transcript", action: "patch", entityId: meetingId, baseRevision: 0,
        data: { transcript: { id: patchId, startedAt: null, endedAt: null, metadata: null }, mode: "replace", patchId, segmentCount: 1, deletionCount: 0, chunks: [{ index: 0, sha256: hash, segmentCount: 1, deletionCount: 0 }] },
      }] });
      const screenshots = Array.from({ length: withImages ? 25 : 0 }, () => ({ fileId: uuidV7(), screenshotId: uuidV7(), vaultId, meetingId,
        capturedAt: new Date(), contentType: "image/webp", storageKey: "unused", contentLength: 1, contentHash: "a".repeat(64),
        ocrText: "Important unsampled evidence", caption: "Excluded image description" }));
      const originalWithIdentity = store.sync.withIdentity.bind(store.sync);
      store.sync.withIdentity = (identity, action) => originalWithIdentity(identity, (scoped) => action({
        ...scoped, listScreenshots: async () => screenshots,
      }));
      vi.spyOn(sync, "readFileContent").mockImplementation(async () => ({
        file: {} as never, upstream: new Response(new Uint8Array([1])), contentType: "image/webp",
      }));
      const transport = vi.fn(async (url: RequestInfo | URL, init?: RequestInit) => {
        if (String(url).endsWith("/token")) return Response.json({ access_token: "app-token", expires_in: 3600 });
        const headers = new Headers(init?.headers);
        expect(headers.get("authorization")).toBe("Bearer app-token");
        expect(JSON.parse(headers.get("Databricks-Ai-Gateway-Request-Tags")!)).toEqual({ user_id: "owner" });
        expect(headers.has("X-Forwarded-Access-Token")).toBe(false);
        const body = JSON.parse(String(init?.body)) as { input: { content: { type: string; text?: string; image_url?: string }[] }[] };
        expect(body).toMatchObject({ model: "catalog.ai.gpt-5-6-luna", stream: false, store: false, text: { format: { strict: true, name: "meeting_summary" } } });
        const content = body.input[0]!.content;
        expect(content[0]!.text).toMatch(/^<context>[\s\S]*<\/context>$/);
        expect(content[1]!.text).toMatch(/^<transcript>[\s\S]*<\/transcript>$/);
        expect(content[1]!.text).toContain("Ship next week &lt; &amp; &gt; &quot; &apos;");
        expect(content[1]!.text).toContain("<speaker>A&amp;B</speaker>");
        if (withImages) {
          const selected = screenshots.filter((_, index) => index % 2 === 0);
          expect(content.filter((part) => part.type === "input_image")).toHaveLength(selected.length);
          selected.forEach((screenshot, index) => {
            expect(content[2 + index * 2]!.text).toBe(`<image><image_id>${screenshot.screenshotId}</image_id><captured_at>${screenshot.capturedAt.toISOString()}</captured_at></image>`);
            expect(content[3 + index * 2]).toEqual({ type: "input_image", image_url: "data:image/webp;base64,AQ==" });
          });
          expect(JSON.stringify(body)).not.toContain(screenshots[1]!.screenshotId);
        } else expect(content).toHaveLength(2);
        for (const excluded of ["ocr_text", "ocrText", "caption", "Important unsampled evidence", "Excluded image description"])
          expect(JSON.stringify(body)).not.toContain(excluded);
        if (scenario === "failure") return Response.json({ error: "sensitive upstream response" }, { status: 400, headers: { "x-databricks-request-id": "req-123" } });
        return Response.json({ ...(withImages ? { id: "resp-example", model: "actual-model", created_at: 123,
          reasoning: { effort: "medium" }, usage: { input_tokens: 100, output_tokens: 20, total_tokens: 120,
            input_tokens_details: { cached_tokens: 10 }, output_tokens_details: { reasoning_tokens: 5 } } } : {}), status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: JSON.stringify(output) }] }] });
      });
      const method = createTranscriptSummaryMethod(loadConfig({ DAHLIA_AUTH_TYPE: "header", DAHLIA_AI_BACKEND: "databricks",
        DATABRICKS_HOST: "https://workspace.example", DATABRICKS_CLIENT_ID: "client", DATABRICKS_CLIENT_SECRET: "secret", DATABRICKS_MODEL_SCHEMA: "catalog.ai" }), store.sync, sync, transport)!;
      const service = new SummaryService(store.sync, store.accountSettings, [method]);
      await service.start(owner, vaultId, meetingId, { id: uuidV7() });
      await new SummaryWorker(store.summaryJobs, [method], sync).processOne();
      if (scenario === "failure") {
        expect((await service.status(owner, vaultId, meetingId))).toMatchObject({ status: "failed", lastErrorCode: "summary_http_400" });
        const log: unknown = JSON.parse(String(warn.mock.calls[0]?.[0]));
        expect(log).toMatchObject({ event: "summary_job_failed", phase: "generate", code: "summary_http_400", requestId: "req-123", retryable: false, attempt: 1 });
        expect(JSON.stringify(warn.mock.calls)).not.toContain("sensitive upstream response");
        expect(JSON.stringify(warn.mock.calls)).not.toContain(meetingId);
        return;
      }
      expect((await service.status(owner, vaultId, meetingId))?.status).toBe("succeeded");
      expect(transport).toHaveBeenCalledTimes(2);
      const meeting = await store.sync.withIdentity(owner, (scoped) => scoped.getMeeting(vaultId, meetingId));
      expect(meeting).toMatchObject({ name: "Decisions", description: "Launch discussion" });
      const metadata = summaryMetadata(meeting!.summaryDocument!);
      expect(metadata).toMatchObject({ generatedBy: "server", request: { model: "catalog.ai.gpt-5-6-luna", reasoning: { effort: "medium" } } });
      if (withImages) expect(metadata?.response).toMatchObject({ id: "resp-example", model: "actual-model", usage: { total_tokens: 120, output_tokens_details: { reasoning_tokens: 5 } } });
      else expect(metadata?.response).toEqual({});
    } finally { await store.close?.(); }
  });

  it.each(["05:00", "01:05:00"])("rejects unresolvable transcript reference %s in content and list items", (reference) => {
    for (const type of ["paragraph", "checklist"]) {
      const block = { ...output.sections[0]!.blocks[0]!, type,
        ...(type === "paragraph" ? { content: { text: "Quote", transcript_ref: reference } }
          : { items: [{ text: "Quote", transcript_ref: reference, checked: false }] }) };
      expect(() => summaryDocument({ ...output, sections: [{ heading: "Topic", blocks: [block] }] }, new Set())).toThrow();
    }
    expect(doc().sections[0]!.blocks[0]).toMatchObject({ content: { transcript_ref: null } });
  });

  it("strictly validates output and rejects fabricated screenshot IDs", () => {
    expect(() => summaryDocument({ ...output, unknown: true }, new Set())).toThrow();
    expect(() => summaryDocument({ ...output, title: "" }, new Set())).toThrow();
    const image = { ...output, sections: [{ heading: "Slide", blocks: [{ ...output.sections[0]!.blocks[0]!, type: "image", image_id: uuidV7() }] }] };
    expect(() => summaryDocument(image, new Set())).toThrow("summary_invalid_image_reference");
    expect(createTranscriptSummaryMethod({} as AppConfig, {} as never, {} as never)).toBeUndefined();
  });
});

async function addRecording(value: Awaited<ReturnType<typeof setup>>, sources: Array<"mic" | "system"> = ["mic", "system"], seconds = 60) {
  const { sync, vaultId, meetingId } = value;
  const sessionId = uuidV7(); const now = new Date().toISOString();
  await sync.commitTransaction(owner, { schemaVersion: 2, id: uuidV7(), vaultId, createdAt: now,
    operations: ["recording_started", "recording_ended"].map((kind) => ({ id: uuidV7(), entity: "meeting_event", action: "create",
      entityId: uuidV7(), baseRevision: null, data: { meetingId, sessionId, kind, occurredAt: now } })) });
  const audio = new Uint8Array([0, 0, 0, 20, 102, 116, 121, 112, 77, 52, 65, 32, 0, 0, 0, 0, 77, 52, 65, 32]);
  for (const source of sources) {
    const uploaded = await sync.postRecording(owner, meetingId, new Request(
      `http://localhost:5173/api/v1/meetings/${meetingId}/recordings?sessionId=${sessionId}&source=${source}`, {
        method: "POST", headers: { "content-type": "audio/mp4", "content-length": String(audio.length) }, body: audio,
      }));
    await sync.commitTransaction(owner, { schemaVersion: 2, id: uuidV7(), vaultId, createdAt: now, operations: [{
      id: uuidV7(), entity: "recording", action: "upsert", entityId: sessionId, baseRevision: uploaded.record.revision,
      data: { source, checksum: uploaded.record.checksum, manifest: { sampleRate: 16000, frameCount: seconds * 16000,
        ranges: [{ startFrame: 0, frameCount: seconds * 16000, sessionOffsetSeconds: 3, localeIdentifier: "ja-JP" }] } },
    }] });
  }
  return audio;
}

function audioMethod(value: Awaited<ReturnType<typeof setup>>, result?: () => Response, models = ["gemini-3-8-flash"]) {
  const calls: Record<string, unknown>[] = [];
  const transport = vi.fn(async (url: RequestInfo | URL, init?: RequestInit) => {
    if (String(url).endsWith("/token")) return Response.json({ access_token: "app-token", expires_in: 3600 });
    if (String(url).includes("model-services?")) return Response.json({ model_services: models.map((id) => ({ name: `model-services/catalog.ai.${id}` })) });
    expect(String(url)).toBe("https://workspace.example/ai-gateway/mlflow/v1/chat/completions");
    const headers = new Headers(init?.headers);
    expect(headers.get("authorization")).toBe("Bearer app-token");
    expect(JSON.parse(headers.get("Databricks-Ai-Gateway-Request-Tags")!)).toEqual({ user_id: "owner" });
    expect(headers.has("X-Forwarded-Access-Token")).toBe(false);
    expect(init?.body).toBeInstanceOf(ReadableStream);
    const body = JSON.parse(await new Response(init?.body).text()) as Record<string, unknown>;
    calls.push(body);
    return result?.() ?? Response.json({ id: null, model: "actual-gemini", created: 123,
      usage: { prompt_tokens: 100, completion_tokens: 20, total_tokens: 125, reasoning_tokens: 5 },
      choices: [{ finish_reason: "stop", message: { content: [
        { type: "reasoning", summary: [{ type: "summary_text", text: "Do not persist this" }] },
        { type: "text", text: JSON.stringify(output), thoughtSignature: "do-not-persist" },
      ] } }] });
  });
  const config = loadConfig({ DAHLIA_AUTH_TYPE: "header", DAHLIA_AI_BACKEND: "databricks", DATABRICKS_HOST: "https://workspace.example",
    DATABRICKS_CLIENT_ID: "client", DATABRICKS_CLIENT_SECRET: "secret", DATABRICKS_MODEL_SCHEMA: "catalog.ai" });
  return { method: createAudioSummaryMethod(config, value.store.sync, value.sync, transport)!, calls, transport };
}

describe("audio summary jobs", () => {
  it.each([["mic"], ["system"], ["mic", "system"]] as Array<Array<"mic" | "system">>)("summarizes committed %j tracks with images and keeps source settings independent", async (...sources) => {
    const value = await setup(); const { store, sync, vaultId, meetingId } = value;
    try {
      const audio = await addRecording(value, sources);
      await addRecording(value, ["mic"]);
      const screenshotId = uuidV7(); const imageId = uuidV7();
      const original = store.sync.withIdentity.bind(store.sync);
      store.sync.withIdentity = (identity, action) => original(identity, (scoped) => action({ ...scoped,
        listTranscript: async () => { throw new Error("Audio summaries must not read transcript"); },
        listScreenshots: async () => [{ screenshotId, fileId: imageId, vaultId, meetingId, capturedAt: new Date(0),
          contentType: "image/webp", storageKey: "unused", contentLength: 1, contentHash: "a".repeat(64), ocrText: "slide evidence", caption: "Excluded audio image description" }],
      }));
      vi.spyOn(sync, "readFileContent").mockResolvedValue({ file: {} as never, upstream: new Response(new Uint8Array([1])), contentType: "image/webp" });
      await store.accountSettings.update(owner.userId, { summary: { method: "audio", detail: "standard", methodSettings: {
        audio: { model: "catalog.ai.gemini-3-8-flash" }, transcript: { model: "saved-transcript-model" },
      } } });
      const { method, calls } = audioMethod(value);
      const service = new SummaryService(store.sync, store.accountSettings, [method]);
      const id = uuidV7(); const job = await service.start(owner, vaultId, meetingId, { id, detail: "concise" });
      expect(await service.start(owner, vaultId, meetingId, { id, detail: "concise" })).toEqual(job);
      expect(job.settings.detail).toBe("concise");
      await store.accountSettings.update(owner.userId, { summary: { method: "transcript", detail: "detailed" } });
      expect(await store.accountSettings.get(owner.userId)).toMatchObject({ summary: { method: "transcript", detail: "detailed", methodSettings: {
        audio: { model: "catalog.ai.gemini-3-8-flash", reasoningEffort: "medium" },
        transcript: { model: "saved-transcript-model", reasoningEffort: "medium" },
      } } });
      // Transcript changes after enqueue do not invalidate an audio job.
      const db = new DatabaseSync(value.path); db.exec("UPDATE meetings SET transcript_revision = 10, revision = revision + 1"); db.close();
      await new SummaryWorker(store.summaryJobs, [method], sync).processOne();
      expect(await service.status(owner, vaultId, meetingId)).toMatchObject({ method: "audio", status: "succeeded" });
      expect(calls).toHaveLength(1);
      expect(calls[0]).not.toHaveProperty("store");
      expect(JSON.stringify(calls[0]!.response_format)).not.toContain("maxItems");
      const body = calls[0] as { messages: { content: string | { type: string; text?: string; audio_url?: { url: string } }[] }[] };
      expect(calls[0]).toMatchObject({ model: "catalog.ai.gemini-3-8-flash", reasoning_effort: "medium", response_format: { json_schema: { strict: true } } });
      const content = body.messages[1]!.content as { type: string; text?: string; audio_url?: { url: string } }[];
      const sentAudio = content.filter((part) => part.type === "audio_url");
      expect(sentAudio).toHaveLength(sources.length + 1);
      for (const part of sentAudio) expect(part.audio_url?.url).toBe(`data:audio/mp4;base64,${Buffer.from(audio).toString("base64")}`);
      expect(content.some((part) => part.type === "image_url")).toBe(true);
      expect(content[0]!.text).toMatch(/^<context>[\s\S]*<\/context>$/);
      expect(content[1]!.text).toBe(`<image><image_id>${screenshotId}</image_id><captured_at>1970-01-01T00:00:00.000Z</captured_at></image>`);
      expect(JSON.stringify(content)).not.toContain("<transcript>");
      for (const excluded of ["ocr_text", "ocrText", "caption", "slide evidence", "Excluded audio image description"])
        expect(JSON.stringify(body)).not.toContain(excluded);
      const audioMetadata = content.filter((part) => part.text?.startsWith("<audio>"));
      expect(audioMetadata).toHaveLength(sentAudio.length);
      const recordings = await store.sync.withIdentity(owner, (scoped) => scoped.listRecordings(meetingId, 0, 200));
      audioMetadata.forEach((part, index) => {
        const recording = recordings[index < sources.length ? 0 : 1]!;
        expect(part.text).toContain(`<start>${recording.startedAt.toISOString()}</start>`);
        expect(part.text).toContain(`<end>${recording.endedAt.toISOString()}</end>`);
        expect(part.text).toContain("<start_frame>0</start_frame><frame_count>960000</frame_count>");
        expect(part.text).toContain("<locale_identifier>ja-JP</locale_identifier>");
        expect(part.text).toContain(`<recording_number>${index < sources.length ? 1 : 2}</recording_number>`);
        expect(part.text).toContain(`<source>${sources[index] ?? "mic"}</source>`);
        expect(part.text).toContain("<sample_rate>16000</sample_rate>");
        expect(part.text).toContain("<session_offset_seconds>3</session_offset_seconds>");
        expect(content[content.indexOf(part) + 1]!.type).toBe("audio_url");
      });
      const saved = await sync.summaryVersion(owner, vaultId, meetingId, "1");
      expect(saved.document).not.toContain("Do not persist this");
      expect(saved.document).not.toContain("thoughtSignature");
      expect(saved.metadata).toMatchObject({ inputTypes: ["context", "audio", "image"], detailLevel: "concise",
        request: { model: "catalog.ai.gemini-3-8-flash" }, response: { id: null, model: "actual-gemini", created_at: 123,
          usage: { input_tokens: 100, output_tokens: 25, total_tokens: 125, output_tokens_details: { reasoning_tokens: 5 } } } });
    } finally { await store.close?.(); }
  });

  it("rejects missing audio, sums both tracks for 9.5 hours, and preserves owner authorization", async () => {
    const value = await setup(); const { store, vaultId, meetingId } = value;
    try {
      const { method, transport } = audioMethod(value);
      const service = new SummaryService(store.sync, store.accountSettings, [method]);
      await store.accountSettings.update(owner.userId, { summary: { method: "audio" } });
      await expect(service.start(owner, vaultId, meetingId, { id: uuidV7() })).rejects.toMatchObject({ status: 400, code: "summary_audio_empty" });
      await addRecording(value, ["mic"], 9.5 * 3600);
      expect(await service.start(owner, vaultId, meetingId, { id: uuidV7() })).toMatchObject({ method: "audio" });
      await addRecording(value, ["system"], 1);
      await expect(store.sync.withIdentity(owner, (scoped) => method.version(scoped, vaultId, meetingId))).rejects.toThrow("summary_audio_too_long");
      const other = { ...owner, userId: "other" };
      await store.ensureIdentityUser(other);
      await store.accountSettings.update(other.userId, { summary: { method: "audio" } });
      await expect(service.start(other, vaultId, meetingId, { id: uuidV7() })).rejects.toMatchObject({ status: 404 });
      await expect(store.sync.withIdentity({ ...owner, userId: "other" }, (scoped) => method.version(scoped, vaultId, meetingId))).rejects.toThrow("summary_meeting_unavailable");
      expect(transport).not.toHaveBeenCalled();
    } finally { await store.close?.(); }
  });

  it.each(["gpt-5-6-terra", "gemini-unavailable", "codex-auto-review"])("rejects unavailable/non-audio model %s without reading audio bytes", async (model) => {
    const value = await setup(); const { store, sync, vaultId, meetingId } = value;
    try {
      await addRecording(value, ["mic"]);
      const read = vi.spyOn(sync, "recordingContent");
      await store.accountSettings.update(owner.userId, { summary: { method: "audio", methodSettings: { audio: { model } } } });
      const { method, calls } = audioMethod(value, undefined, ["gemini-3-8-flash", "gpt-5-6-terra", "codex-auto-review"]);
      const service = new SummaryService(store.sync, store.accountSettings, [method]);
      await service.start(owner, vaultId, meetingId, { id: uuidV7() });
      await new SummaryWorker(store.summaryJobs, [method], sync).processOne();
      expect(await service.status(owner, vaultId, meetingId)).toMatchObject({ status: "failed", lastErrorCode: "summary_invalid_audio_model" });
      expect(read).not.toHaveBeenCalled(); expect(calls).toHaveLength(0);
    } finally { await store.close?.(); }
  });

  it.each(["size", "invalid", "truncated", "input_changed", "conflict"])("keeps the current summary on %s failure", async (scenario) => {
    const value = await setup(); const { store, sync, vaultId, meetingId } = value;
    try {
      await addRecording(value, ["mic"]);
      await sync.commitTransaction(owner, { schemaVersion: 2, id: uuidV7(), vaultId, createdAt: new Date().toISOString(), operations: [{
        id: uuidV7(), entity: "summary", action: "upsert", entityId: meetingId, baseRevision: 0,
        data: { title: "Manual", document: JSON.stringify({ ...doc(), title: "Manual" }), createdAt: new Date().toISOString() },
      }] });
      await store.accountSettings.update(owner.userId, { summary: { method: "audio" } });
      const { method } = audioMethod(value, () => {
        if (scenario === "size") return new Response(null, { status: 413 });
        if (scenario === "invalid") return Response.json({ choices: [{ finish_reason: "stop", message: { content: "not-json" } }] });
        if (scenario === "conflict") {
          const db = new DatabaseSync(value.path); db.exec("UPDATE meetings SET summary_revision = 2"); db.close();
        }
        return Response.json({ choices: [{ finish_reason: scenario === "truncated" ? "length" : "stop", message: { content: JSON.stringify(output) } }] });
      });
      const service = new SummaryService(store.sync, store.accountSettings, [method]);
      await service.start(owner, vaultId, meetingId, { id: uuidV7() });
      if (scenario === "input_changed") await addRecording(value, ["system"]);
      await new SummaryWorker(store.summaryJobs, [method], sync).processOne();
      expect(await service.status(owner, vaultId, meetingId)).toMatchObject({ status: "failed", lastErrorCode: {
        size: "summary_audio_request_too_large", invalid: "summary_invalid_response", truncated: "summary_invalid_response",
        input_changed: "summary_input_changed", conflict: "summary_conflict",
      }[scenario] });
      const versions = await sync.summaryVersions(owner, vaultId, meetingId);
      expect(versions.items).toHaveLength(1);
      expect((await sync.latestSummary(owner, vaultId, meetingId)).record?.title).toBe("Manual");
    } finally { await store.close?.(); }
  });

  it("migrates existing settings without changing transcript settings or jobs", async () => {
    for (const path of ["sqlite/20260908080352_zippy_aaron_stack/migration.sql", "d1/20260908080352_zippy_aaron_stack.sql"]) {
      const db = new DatabaseSync(":memory:");
      try {
        db.exec("CREATE TABLE account_settings (user_id TEXT PRIMARY KEY, summary_method TEXT, transcript_summary TEXT); INSERT INTO account_settings VALUES ('owner', 'transcript', '{\"model\":\"saved\"}'); CREATE TABLE summary_jobs (id TEXT, settings TEXT); INSERT INTO summary_jobs VALUES ('running', 'unchanged');");
        db.exec(readFileSync(new URL(`../drizzle/${path}`, import.meta.url), "utf8"));
        expect(db.prepare("SELECT summary_method, transcript_summary, audio_summary FROM account_settings").get()).toEqual({
          summary_method: "transcript", transcript_summary: '{"model":"saved"}', audio_summary: JSON.stringify({ ...DEFAULT_ACCOUNT_SETTINGS.summary.methodSettings.audio, detail: "detailed" }),
        });
        expect(db.prepare("SELECT * FROM summary_jobs").get()).toEqual({ id: "running", settings: "unchanged" });
      } finally { db.close(); }
    }
  });
});
