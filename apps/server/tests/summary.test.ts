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
import { createTranscriptSummaryMethod } from "../src/summary/transcript";
import { accountSettingsPatchSchema } from "../src/account-settings";
import { loadConfig } from "../src/config";
import { createApp } from "../src/app";
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
  const sync = new MeetingSyncService(store.sync); const vaultId = uuidV7(); const meetingId = uuidV7();
  await sync.commitTransaction(owner, { schemaVersion: 2, id: uuidV7(), vaultId, createdAt: new Date().toISOString(), operations: [
    { id: uuidV7(), entity: "vault", action: "create", entityId: vaultId, baseRevision: null, data: { name: "Vault", createdAt: new Date().toISOString() } },
    { id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
      data: { name: "Meeting", description: "", status: "READY", projectId: null, duration: 60, recordingStartedAt: new Date().toISOString(), createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } },
  ] });
  const method: SummaryMethod = { id: "transcript", captureSettings: (settings, detail) => ({ ...settings.summary.methodSettings.transcript, detail: detail ?? settings.summary.methodSettings.transcript.detail }), version: vi.fn(async () => "version1"), generate: vi.fn(async () => doc()) };
  const service = new SummaryService(store.sync, store.accountSettings, [method]);
  return { store, sync, method, service, vaultId, meetingId, config, path };
}

describe("server summary jobs", () => {
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
      expect(manifest.sha256).toBe((await sync.textContent(owner, vaultId, "summary", meetingId, "2")).sha256);
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
    try {
      await sync.commitTransaction(owner, { schemaVersion: 2, id: uuidV7(), vaultId, createdAt: new Date().toISOString(), operations: [{
        id: uuidV7(), entity: "summary", action: "upsert", entityId: meetingId, baseRevision: 0,
        data: { title: "Saved", document: JSON.stringify(doc()), createdAt: new Date().toISOString() },
      }] });
      const app = createApp({ config, authStore: store });
      const headers = { "x-forwarded-email": "reader@example.com", "x-forwarded-user": "reader" };
      const base = `/api/v1/vaults/${vaultId}/meetings/${meetingId}/summary`;
      const routes = ["latest", "versions", "versions/1"];
      for (const route of routes) {
        expect((await app.request(`${base}/${route}`)).status).toBe(401);
        expect((await app.request(`${base}/${route}`, { headers })).status).toBe(404);
      }
      const db = new DatabaseSync(path);
      try {
        db.prepare("INSERT INTO vault_permissions(vault_id, principal_type, principal_id, role, granted_by_user_id, created_at) VALUES (?, 'user', 'reader', 'member', 'owner', ?)").run(vaultId, Date.now());
        for (const route of routes) {
          const response = await app.request(`${base}/${route}`, { headers });
          expect(response.status).toBe(200);
          expect(response.headers.get("cache-control")).toBe("no-store");
        }
        expect((await app.request(`${base}/latest?manifest=invalid`, { headers })).status).toBe(400);
        expect((await app.request(`${base}/versions?limit=101`, { headers })).status).toBe(400);
        expect((await app.request(`${base}/versions/999999999999`, { headers })).status).toBe(400);
        db.prepare("DELETE FROM vault_permissions WHERE principal_id = 'reader'").run();
        for (const route of routes) expect((await app.request(`${base}/${route}`, { headers })).status).toBe(404);
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

  it("reads persisted settings from unchanged database columns", async () => {
    const { store, path } = await setup();
    try {
      await store.accountSettings.update(owner.userId, { outputLanguage: "en" });
      const database = new DatabaseSync(path);
      database.prepare("UPDATE account_settings SET summary_method = ?, transcript_summary = ? WHERE user_id = ?")
        .run("transcript", JSON.stringify({ model: "existing-model", reasoningEffort: "high", detail: "concise" }), owner.userId);
      database.close();
      expect(await store.accountSettings.get(owner.userId)).toMatchObject({ outputLanguage: "en", summary: {
        method: "transcript", methodSettings: { transcript: { model: "existing-model", reasoningEffort: "high", detail: "concise" } },
      } });
    } finally { await store.close?.(); }
  });

  it("fixes settings at start, keeps starts idempotent and saves through canonical delta and search", async () => {
    const { store, sync, method, service, vaultId, meetingId } = await setup();
    try {
      await store.accountSettings.update(owner.userId, { summary: { methodSettings: { transcript: { model: "model1", reasoningEffort: "high", detail: "standard" } } } });
      const id = uuidV7(); const job = await service.start(owner, vaultId, meetingId, { id, detail: "concise" });
      await store.accountSettings.update(owner.userId, { outputLanguage: "en", summary: { methodSettings: { transcript: { model: "model2", reasoningEffort: "low", detail: "detailed" } } } });
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
      expect(await (await portable.request("/api/v1/capabilities", { headers })).json()).toMatchObject({ summaryGeneration: { version: 0, methods: [] } });
      expect((await app.request("/api/v1/summary/methods", { headers })).status).toBe(404);
      expect(await (await app.request("/api/v1/capabilities", { headers })).json()).toMatchObject({ summaryGeneration: { version: 1, methods: ["transcript"] } });
      expect((await portable.request(path, { method: "POST", headers, body: "{}" })).status).toBe(503);
    } finally { await store.close?.(); }
  });

  it.each(["short", "qualified", "failure"])("shares model resolution and safe diagnostics (%s)", async (scenario) => {
    const withImages = scenario === "qualified";
    const { store, sync, vaultId, meetingId } = await setup();
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      await store.accountSettings.update(owner.userId, { summary: { methodSettings: { transcript: {
        model: withImages ? "catalog.ai.gpt-5-6-luna" : "gpt-5-6-luna", reasoningEffort: "medium", detail: "detailed",
      } } } });
      const patchId = uuidV7(); const hash = "a".repeat(64);
      await sync.putTranscriptChunk(owner, vaultId, meetingId, patchId, 0, hash, {
        segments: [{ segmentId: uuidV7(), startTime: new Date().toISOString(), endTime: null,
          text: "Ship next week", isConfirmed: true, audioSource: "mic", speakerLabel: null }], deletions: [],
      });
      await sync.commitTransaction(owner, { schemaVersion: 2, id: uuidV7(), vaultId, createdAt: new Date().toISOString(), operations: [{
        id: patchId, entity: "transcript", action: "patch", entityId: meetingId, baseRevision: 0,
        data: { patchId, segmentCount: 1, deletionCount: 0, chunks: [{ index: 0, sha256: hash, segmentCount: 1, deletionCount: 0 }] },
      }] });
      const screenshots = Array.from({ length: withImages ? 25 : 0 }, () => ({ fileId: uuidV7(), screenshotId: uuidV7(), vaultId, meetingId,
        capturedAt: new Date(), contentType: "image/webp", storageKey: "unused", contentLength: 1, contentHash: "a".repeat(64),
        ocrText: "Important unsampled evidence", caption: null }));
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
        const body = JSON.parse(String(init?.body)) as { input: { content: { text: string }[] }[] };
        expect(body).toMatchObject({ model: "catalog.ai.gpt-5-6-luna", stream: false, store: false, text: { format: { strict: true, name: "meeting_summary" } } });
        expect(body.input[0]!.content[0]!.text).toContain("Ship next week");
        if (withImages) {
          const evidence = JSON.parse(body.input[0]!.content[0]!.text) as { images: { image_id: string | null; ocrText: string }[] };
          expect(evidence.images[0]!.image_id).toBe(screenshots[0]!.screenshotId);
          expect(evidence.images[1]).toMatchObject({ image_id: null, ocrText: "Important unsampled evidence" });
          expect(JSON.stringify(body)).not.toContain(screenshots[1]!.screenshotId);
        }
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
