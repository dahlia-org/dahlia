import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { loadConfig, type AppConfig } from "../src/config";
import type { Identity } from "../src/auth/identity";
import { seedHeaderIdentity, testUserID, testOrganizationID } from "./public-test-client";
import { uuidV7 } from "../src/id";
import { MeetingSyncService } from "../src/sync/service";
import { WorkspaceMemoryService } from "../src/memory/service";
import { HindsightClient } from "../src/memory/hindsight";
import { sharedMemorySchema } from "../src/memory/model";
import { createQueueJobs } from "../src/jobs/queues";
import { createApp } from "../src/app";
import { encodeId } from "../src/typeid";
import { meetingDocument } from "../src/memory/sources";

const owner: Identity = { userId: testUserID("memory-owner"), source: "header" };
const viewer: Identity = { userId: testUserID("memory-viewer"), source: "header" };
const workspaceId = "019d4a00-0000-7000-8000-000000000100";
const directories: string[] = [];
afterEach(() => { vi.useRealTimers(); directories.splice(0).forEach((path) => rmSync(path, { recursive: true, force: true })); });
async function setup() {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-memory-")); directories.push(directory);
  const databasePath = join(directory, "test.sqlite");
  const config: AppConfig = { authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite", databaseUrl: `file:${databasePath}`,
    baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1024 * 1024,
    hindsight: { url: "https://memory.example/api", auth: "bearer", apiKey: "test-secret", bankPrefix: "test" } };
  const app = createNodeApplicationStore(config); await app.migrate();
  await seedHeaderIdentity(app, databasePath, owner); await seedHeaderIdentity(app, databasePath, viewer);
  const sync = new MeetingSyncService(app.sync);
  const commit = async (operations: Array<{ entity: string; action: string; entityId: string; baseRevision: number | null; data: unknown }>) =>
    sync.commitTransaction(owner, { schemaVersion: 3, workspaceId, id: uuidV7(), createdAt: new Date().toISOString(),
      operations: operations.map((operation) => ({ ...operation, id: uuidV7() })) });
  await commit([{ entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null,
    data: { organizationId: testOrganizationID, name: "Workspace", createdAt: new Date().toISOString() } }]);
  const db = new DatabaseSync(databasePath);
  db.prepare("INSERT INTO workspace_permissions (workspace_id, principal_type, principal_id, role, granted_by_user_id, created_at) VALUES (?, 'user', ?, 'viewer', ?, ?)")
    .run(workspaceId, viewer.userId, owner.userId, Date.now());
  const requests: Array<{ path: string; method: string; body: Record<string, unknown> }> = [];
  const retained = new Map<string, string>();
  const operations = new Map<string, string>();
  const models = new Map<string, boolean>();
  let loseAcknowledgement = false;
  const transport = vi.fn<typeof fetch>(async (url, init) => {
    expect(new Headers(init?.headers).get("authorization")).toBe("Bearer test-secret");
    expect(init?.redirect).toBe("error");
    const path = new URL(String(url)).pathname;
    const body = (init?.body ? JSON.parse(String(init.body)) : {}) as Record<string, unknown>;
    requests.push({ path, method: init?.method ?? "GET", body });
    if (path.endsWith("/config")) return Response.json({});
    if (path.endsWith("/memories") && init?.method === "POST") {
      const item = (body.items as Array<{ document_id: string; content: string }>)[0]!;
      retained.set(item.document_id, item.content); operations.set(String(body.operation_id), "completed");
      if (loseAcknowledgement) { loseAcknowledgement = false; throw new Error("lost acknowledgement"); }
      return Response.json({ operation_id: body.operation_id });
    }
    if (path.includes("/operations/")) return Response.json({ status: operations.get(path.split("/").at(-1)!) ?? "not_found" });
    if (path.endsWith("/mental-models") && init?.method === "GET") return Response.json({ items: [...models.keys()].map((id) => ({ id })) });
    if (path.endsWith("/mental-models") && init?.method === "POST") {
      models.set(String(body.id), true); const id = uuidV7(); operations.set(id, "completed"); return Response.json({ operation_id: id });
    }
    if (path.includes("/mental-models/") && init?.method === "GET") return models.has(path.split("/").at(-1)!) ? Response.json({}) : new Response(null, { status: 404 });
    if (path.includes("/mental-models/") && init?.method === "DELETE") { models.delete(path.split("/").at(-1)!); return Response.json({}); }
    if (path.includes("/documents/") && init?.method === "DELETE") { retained.delete(path.split("/").at(-1)!); return Response.json({}); }
    if (path.endsWith("/memories/recall")) return Response.json({ results: [...retained.keys()].map((document_id) => ({ id: uuidV7(), document_id, text: "UNTRUSTED EXTRACTED CLAIM" })) });
    if (init?.method === "DELETE") { retained.clear(); models.clear(); return Response.json({}); }
    throw new Error(`Unexpected mock route ${path}`);
  });
  const memory = new WorkspaceMemoryService(config, app.memory!, sync, app.sync, transport);
  const tick = async () => { db.exec("UPDATE workspace_memory_state SET available_at = 0"); await memory.step(workspaceId, new AbortController().signal); };
  const ready = async () => {
    for (let i = 0; i < 30; i++) {
      await tick(); if ((await memory.status(owner, workspaceId)).status === "ready") return;
    }
    throw new Error(JSON.stringify(await memory.status(owner, workspaceId)));
  };
  const close = async () => { db.close(); await app.close?.(); };
  return { app, config, db, sync, memory, commit, tick, ready, close, requests, retained,
    loseNextAcknowledgement: () => { loseAcknowledgement = true; } };
}

describe("Workspace memory", () => {
  it("enforces the browser API contract, TypeIDs, explicit sharing and current permissions", async () => {
    const f = await setup();
    try {
      const app = createApp({ config: f.config, authStore: f.app, syncService: f.sync, workspaceMemory: f.memory });
      const path = `/api/v1/workspaces/${encodeId("workspace", workspaceId)}/memory`;
      const request = (url: string, method = "GET", body?: unknown, identity = owner) => app.request(url, { method,
        headers: { "x-forwarded-email": `${identity.userId}@example.com`, "content-type": "application/json", "x-dahlia-workspace-transfers": "1" },
        body: body ? JSON.stringify(body) : undefined });
      expect((await request(path, "PUT", { enabled: true }, viewer)).status).toBe(404);
      expect((await request(path, "PUT", { enabled: true })).status).toBe(204);
      expect((await request(`${path}/notes`, "PUT", { id: encodeId("sharedMemory", crypto.randomUUID()),
        content: "Invalid entity ID", revision: 0, confirmed: true })).status).toBe(400);
      const id = encodeId("sharedMemory", uuidV7());
      expect((await request(`${path}/notes`, "PUT", { id, content: "User-confirmed claim", revision: 0 })).status).toBe(400);
      const saved = await request(`${path}/notes`, "PUT", { id, content: "User-confirmed claim", revision: 0, confirmed: true });
      expect(saved.status).toBe(200); expect(await saved.json()).toMatchObject({ id, revision: 1 });
      expect(await (await request(`${path}/notes`)).json()).toMatchObject({ items: [{ id }] });
      expect((await request(`${path}/notes/${id}?revision=1`, "DELETE", undefined, viewer)).status).toBe(404);
      expect((await request(`${path}/notes/${id}?revision=1`, "DELETE")).status).toBe(204);
      const purge = await request(path, "DELETE"); expect(purge.status).toBe(202); expect(await purge.json()).toEqual({ status: "deleting" });
    } finally { await f.close(); }
  });
  it("permits revision-matched corrections while paused without publishing memory or new notes", async () => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      const note = await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Original" });
      await f.ready();
      await f.memory.configure(owner, workspaceId, false);
      const input = { id: note.id, revision: note.revision, content: "Corrected while paused" };
      await expect(f.app.memory!.saveNote(viewer.userId, workspaceId, input)).rejects.toMatchObject({ status: 404 });
      const corrected = await f.app.memory!.saveNote(owner.userId, workspaceId, input);
      expect(corrected.revision).toBe(2);
      expect(await f.app.memory!.saveNote(owner.userId, workspaceId, input)).toEqual(corrected);
      await expect(f.app.memory!.saveNote(owner.userId, workspaceId, { ...input, content: "Stale correction" })).rejects.toMatchObject({ status: 409 });
      await expect(f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "New" })).rejects.toMatchObject({ status: 409 });
      await expect(f.memory.search(owner, workspaceId, "query", false, new AbortController().signal)).rejects.toThrow("memory_not_ready");
      const count = f.requests.length;
      await f.tick();
      expect(f.requests).toHaveLength(count);
      await f.memory.configure(owner, workspaceId, true);
      await f.ready();
      expect(f.retained.get(`shared-${note.id}`)).toContain(input.content);
      await f.app.memory!.purge(owner.userId, workspaceId);
      await expect(f.app.memory!.saveNote(owner.userId, workspaceId, { ...input, revision: 2 })).rejects.toMatchObject({ status: 409 });
    } finally { await f.close(); }
  });

  it("preserves paginated transcript and screenshot provenance and excludes active meetings", async () => {
    const now = new Date();
    const sync = { getMeeting: vi.fn().mockResolvedValue({ meetingId: workspaceId, name: "Customer", description: "", status: "READY", createdAt: now,
      projectId: workspaceId, summaryDocument: "Summary interpretation" }), getProject: vi.fn().mockResolvedValue({ projectId: workspaceId, name: "Customer project", description: "Context" }),
    listTranscript: vi.fn().mockResolvedValueOnce({ items: [{ segmentId: "one", startedAt: now, speakerLabel: "Speaker A", audioSource: "microphone", text: "Actual statement" }], nextCursor: "next" })
      .mockResolvedValueOnce({ items: [{ segmentId: "two", startedAt: now, text: "Counterexample" }] }),
    listScreenshots: vi.fn().mockResolvedValue({ items: [{ screenshotId: "shot", fileId: "file", capturedAt: now, ocrText: "Screen evidence", caption: "Image interpretation" }] }) };
    const document = await meetingDocument(sync as unknown as MeetingSyncService, owner, workspaceId, workspaceId, new AbortController().signal);
    for (const text of ["Actual statement", "Counterexample", "Speaker A", "Screen evidence", "AI caption (interpretation)", "not independent corroboration", "Customer project"]) expect(document!.content).toContain(text);
    expect(sync.listTranscript.mock.calls[1]![3]).toBe("next");
    sync.getMeeting.mockResolvedValueOnce({ isRecording: true, status: "READY" });
    expect(await meetingDocument(sync as unknown as MeetingSyncService, owner, workspaceId, workspaceId, new AbortController().signal)).toBeNull();
  });
  it("requires explicit confirmation and keeps user and Workspace memory boundaries separate", () => {
    expect(sharedMemorySchema.safeParse({ id: uuidV7(), content: "private", revision: 0 }).success).toBe(false);
    expect(sharedMemorySchema.safeParse({ id: uuidV7(), content: "shared", revision: 0, confirmed: true, bankId: "another-user" }).success).toBe(false);
  });
  it("checks roles, persists first in Dahlia, survives a lost retain acknowledgement, and serves only canonical evidence", async () => {
    const f = await setup();
    try {
      await expect(f.memory.configure(viewer, workspaceId, true)).rejects.toMatchObject({ status: 404 });
      await f.memory.configure(owner, workspaceId, true);
      const input = { id: uuidV7(), revision: 0, content: "User registered: deployment is blocked by budget." };
      await expect(f.app.memory!.saveNote(viewer.userId, workspaceId, input)).rejects.toMatchObject({ status: 404 });
      await f.app.memory!.saveNote(owner.userId, workspaceId, input);
      expect(await f.app.memory!.saveNote(owner.userId, workspaceId, input)).toMatchObject({ revision: 1 });
      await expect(f.memory.search(owner, workspaceId, "budget", false, new AbortController().signal)).rejects.toThrow("memory_not_ready");
      f.loseNextAcknowledgement(); await f.ready();
      expect(f.requests.filter((r) => r.path.endsWith("/memories") && r.method === "POST")).toHaveLength(1);
      const result = await f.memory.search(viewer, workspaceId, "budget", false, new AbortController().signal);
      expect(result.sources[0]?.canonicalExcerpt).toContain(input.content);
      expect(JSON.stringify(result)).not.toContain("UNTRUSTED EXTRACTED CLAIM");
      const before = f.requests.length; await f.tick(); expect(f.requests).toHaveLength(before);
      await f.app.memory!.deleteNote(owner.userId, workspaceId, input.id, 1);
      await expect(f.memory.search(owner, workspaceId, "budget", false, new AbortController().signal)).rejects.toThrow("memory_not_ready");
      await f.ready(); expect(f.retained.size).toBe(0);
      expect((await f.memory.search(owner, workspaceId, "budget", false, new AbortController().signal)).sources).toEqual([]);
    } finally { await f.close(); }
  });
  it("backfills saved meetings and invalidates immediately on canonical correction and permission revocation", async () => {
    const f = await setup();
    try {
      const meetingId = uuidV7(); const now = new Date().toISOString();
      const data = { projectId: null, name: "Customer meeting", description: "Original constraint", status: "READY", duration: 60, recordingStartedAt: now, createdAt: now, updatedAt: now };
      await f.commit([{ entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data }]);
      await f.memory.configure(owner, workspaceId, true); await f.ready();
      expect(f.retained.get(`meeting-${meetingId}`)).toContain("Original constraint");
      const meeting = await f.sync.getMeeting(owner, workspaceId, meetingId);
      const { createdAt: _createdAt, ...updated } = data;
      expect(_createdAt).toBe(now);
      await f.commit([{ entity: "meeting", action: "update", entityId: meetingId, baseRevision: meeting!.revision!, data: { ...updated, description: "Corrected constraint" } }]);
      await expect(f.memory.search(owner, workspaceId, "constraint", false, new AbortController().signal)).rejects.toThrow("memory_not_ready");
      await f.ready(); expect(f.retained.get(`meeting-${meetingId}`)).toContain("Corrected constraint");
      f.db.prepare("DELETE FROM workspace_permissions WHERE workspace_id = ? AND principal_id = ?").run(workspaceId, viewer.userId);
      await expect(f.memory.search(viewer, workspaceId, "constraint", false, new AbortController().signal)).rejects.toMatchObject({ status: 404 });
      await f.app.memory!.purge(owner.userId, workspaceId); await f.tick();
      expect(f.retained.size).toBe(0); expect(await f.sync.getMeeting(owner, workspaceId, meetingId)).not.toBeNull();
    } finally { await f.close(); }
  });
  it("fences a worker completion against concurrent invalidation and retains cleanup after Workspace deletion", async () => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      const job = await f.app.memory!.claim(workspaceId);
      await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "New evidence" });
      await f.app.memory!.release(job!, { indexedGeneration: job!.generation, status: "ready" });
      expect((await f.memory.status(owner, workspaceId)).status).not.toBe("ready");
      await f.ready();
      f.db.prepare("DELETE FROM workspaces WHERE workspace_id = ?").run(workspaceId);
      await f.tick(); expect(f.retained.size).toBe(0);
      expect(f.db.prepare("SELECT * FROM workspace_memory_state").all()).toEqual([]);
    } finally { await f.close(); }
  });
  it("dispatches identifier-only Worker queue jobs and schedules pending work", async () => {
    const send = vi.fn(); const sendBatch = vi.fn(); const step = vi.fn();
    const memory = { step, store: { due: vi.fn().mockResolvedValue([workspaceId]), nextDelay: vi.fn().mockResolvedValue(5) } } as unknown as WorkspaceMemoryService;
    const jobs = createQueueJobs({ DAHLIA_MEMORY_QUEUE: { send, sendBatch } }, {} as never, {} as never, {} as never, [], undefined, undefined, memory);
    await jobs.schedule(); expect(send).toHaveBeenCalledWith({ action: "memory" });
    await jobs.consume({ action: "memory" }, new AbortController().signal);
    expect(sendBatch).toHaveBeenCalledWith([{ body: { action: "memory", workspaceId } }]);
    await jobs.consume({ action: "memory", workspaceId }, new AbortController().signal);
    expect(step).toHaveBeenCalled(); expect(send).toHaveBeenCalledWith({ action: "memory", workspaceId }, { delaySeconds: 5 });
  });
});

describe("Hindsight authentication", () => {
  const env = { DAHLIA_AUTH_TYPE: "header", DAHLIA_AUTH_SECRET: "test-only-better-auth-secret-value", DAHLIA_HINDSIGHT_URL: "https://memory.example/api", DAHLIA_HINDSIGHT_BANK_PREFIX: "test" };
  it("validates independent authentication settings", () => {
    expect(() => loadConfig(env)).toThrow();
    expect(() => loadConfig({ ...env, DAHLIA_HINDSIGHT_AUTH: "bearer" })).toThrow();
    expect(() => loadConfig({ ...env, DAHLIA_HINDSIGHT_AUTH: "bearer", DAHLIA_HINDSIGHT_API_KEY: "key", DAHLIA_HINDSIGHT_URL: "http://memory.example" })).toThrow();
    const config = loadConfig({ ...env, DAHLIA_HINDSIGHT_AUTH: "databricks", DATABRICKS_HOST: "https://workspace.example", DATABRICKS_CLIENT_ID: "app", DATABRICKS_CLIENT_SECRET: "secret" });
    expect(config.databricksWorkspace?.clientId).toBe("app"); expect(config.hindsight?.auth).toBe("databricks");
  });
  it("uses cached short-lived service credentials, refreshes them and rejects upstream failures without fallback", async () => {
    vi.useFakeTimers();
    let count = 0;
    const fetcher = vi.fn<typeof fetch>(async (url, init) => {
      if (String(url).endsWith("/oidc/v1/token")) { count++; return Response.json({ access_token: `token-${count}`, expires_in: 120 }); }
      expect(new Headers(init?.headers).get("authorization")).toBe(`Bearer token-${count}`);
      expect(String(url)).toContain("/api/v1/default/banks/test-workspace-");
      expect(init?.redirect).toBe("error");
      return new Response(null, { status: 403 });
    });
    const client = new HindsightClient({ url: "https://memory.example/api", auth: "databricks", bankPrefix: "test" },
      { host: "https://workspace.example", tokenUrl: "https://workspace.example/oidc/v1/token", clientId: "app", clientSecret: "secret" }, fetcher);
    await Promise.all([1, 2].map(() => expect(client.recall(client.bank(workspaceId), "q", new AbortController().signal)).rejects.toMatchObject({ status: 403 })));
    expect(count).toBe(1);
    vi.advanceTimersByTime(61_000);
    await expect(client.recall(client.bank(workspaceId), "q", new AbortController().signal)).rejects.toMatchObject({ status: 403 });
    expect(count).toBe(2);
  });
});

describe("Pinned Hindsight response contracts", () => {
  it("resolves mental-model and observation lineage to documents and rejects invalidated evidence", async () => {
    let invalidated = false;
    const client = new HindsightClient({ url: "http://localhost:8888", auth: "none", bankPrefix: "test" }, undefined, async (url) => {
      const path = new URL(String(url)).pathname;
      if (path.includes("mental-models")) return Response.json({ reflect_response: { based_on: { world: [{ id: "source" }], observation: [{ id: "observation" }] } } });
      if (path.endsWith("observation")) return Response.json({ state: "valid", document_id: null, source_memory_ids: ["source"] });
      return Response.json({ state: invalidated ? "invalidated" : "valid", document_id: "meeting-canonical" });
    });
    expect(await client.modelDocuments("bank", "model", new AbortController().signal)).toEqual(["meeting-canonical"]);
    invalidated = true;
    expect(await client.modelDocuments("bank", "model", new AbortController().signal)).toEqual([]);
  });
  it("recovers a mental-model creation whose acknowledgement was lost", async () => {
    let created = false; const methods: string[] = [];
    const client = new HindsightClient({ url: "http://localhost:8888", auth: "none", bankPrefix: "test" }, undefined, async (url, init) => {
      methods.push(`${init?.method} ${new URL(String(url)).pathname.split("/").at(-1)}`);
      if (init?.method === "GET") return created ? Response.json({ id: "workspace-insights" }) : new Response(null, { status: 404 });
      if (!created) { created = true; throw new Error("lost response"); }
      return Response.json({ operation_id: "refresh-operation" });
    });
    await expect(client.createModel("bank", null, new AbortController().signal)).rejects.toThrow("memory_transport_failed");
    expect(await client.createModel("bank", null, new AbortController().signal)).toBe("refresh-operation");
    expect(methods).toEqual(["GET workspace-insights", "POST mental-models", "GET workspace-insights", "POST refresh"]);
  });
});
