import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createNodeApplicationStore } from "../src/auth/node-store";
import type { AppConfig } from "../src/config";
import { seedHeaderIdentity, testOrganizationID } from "./public-test-client";
import { uuidV7 } from "../src/id";
import { encodeId } from "../src/typeid";
import { MeetingSyncService } from "../src/sync/service";
import { WorkspaceMemoryService } from "../src/memory/service";
import { DahliaMemory } from "../src/memory/dahlia";
import { createDahliaMemoryTools } from "../src/memory/dahlia-tools";
import { meetingRequestContext } from "../src/agent/tools";
import { standardModel } from "../src/memory/pages-model";
import { createApp } from "../src/app";
import { MemoryWorker } from "../src/memory/node-worker";
import { createQueueJobs } from "../src/jobs/queues";

const directories: string[] = [], signal = new AbortController().signal;
afterEach(() => { vi.restoreAllMocks(); directories.splice(0).forEach((path) => rmSync(path, { recursive: true, force: true })); });
type Fact = { id: string; text: string; type: string; state: string; document_id: string | null; updated_at: string; metadata: Record<string, string>; tags?: string[]; source_memory_ids?: string[] };
type Model = ReturnType<typeof standardModel> & { bank_id: string; content: string; last_refreshed_at: string; is_stale: boolean;
  reflect_response: { based_on: Record<string, Array<{ id: string; text: string }>>; dahlia_generation?: { cutoff: string; source_query: string; tags: string[]; trigger: ReturnType<typeof standardModel>["trigger"]; max_tokens: number } } };
async function fixture(count = 6) {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-pages-")); directories.push(directory);
  const file = join(directory, "app.sqlite");
  const config: AppConfig = { authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite", databaseUrl: `file:${file}`,
    baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1024 * 1024,
    hindsight: { url: "https://memory.example", auth: "none" } };
  const app = createNodeApplicationStore(config); await app.migrate();
  const owner = { userId: uuidV7(), email: "pages-owner@example.com", source: "header" as const };
  const viewer = { userId: uuidV7(), email: "pages-viewer@example.com", source: "header" as const };
  await seedHeaderIdentity(app, file, owner); await seedHeaderIdentity(app, file, viewer);
  const sync = new MeetingSyncService(app.sync), workspace = uuidV7(), workspaceId = encodeId("workspace", workspace);
  const commit = (operations: Array<{ entity: string; action: string; entityId: string; baseRevision: number | null; data: unknown }>) =>
    sync.commitTransaction(owner, { schemaVersion: 3, workspaceId: workspace, id: uuidV7(), createdAt: new Date().toISOString(), operations: operations.map((o) => ({ ...o, id: uuidV7() })) });
  await commit([{ entity: "workspace", action: "create", entityId: workspace, baseRevision: null,
    data: { organizationId: testOrganizationID, name: "Team", createdAt: new Date().toISOString() } }]);
  const db = new DatabaseSync(file);
  db.prepare("INSERT INTO workspace_permissions (workspace_id, principal_type, principal_id, role, granted_by_user_id, created_at) VALUES (?, 'user', ?, 'viewer', ?, ?)").run(workspace, viewer.userId, owner.userId, Date.now());
  const facts = new Map<string, Fact>(), models = new Map<string, Model>(), operations = new Map<string, string>();
  const documents = new Map<string, { content: string; metadata: Record<string, string> }>();
  let policy = "a".repeat(64);
  const calls: Array<{ path: string; method: string }> = [];
  let intercept: ((path: string, method: string) => void | Promise<void>) | undefined;
  const generate = (definition: ReturnType<typeof standardModel>) => {
    const evidence = [...facts.values()].filter((fact) => fact.state === "valid" && definition.tags.every((tag) => fact.tags?.includes(tag)));
    const cutoff = new Date().toISOString();
    const model: Model = { ...definition, bank_id: `dahlia_${encodeId("workspace", workspace)}`, content: "Synthetic generated hypothesis", last_refreshed_at: cutoff, is_stale: false,
      reflect_response: { based_on: { world: evidence.filter((f) => f.type === "world").map(({ id, text }) => ({ id, text })) },
        dahlia_generation: { cutoff, source_query: definition.source_query, tags: definition.tags, trigger: definition.trigger, max_tokens: definition.max_tokens } } };
    models.set(definition.id, model); return model;
  };
  const operation = () => { const id = uuidV7(); operations.set(id, "completed"); return Response.json({ operation_id: id }); };
  const transport = vi.fn<typeof fetch>(async (url, init) => {
    const path = new URL(String(url)).pathname, method = init?.method ?? "GET";
    calls.push({ path, method }); await intercept?.(path, method);
    const body = init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : {};
    if (path.endsWith("/config")) return Response.json({ bank_id: `dahlia_${encodeId("workspace", workspace)}`, dahlia_ingestion_policy: policy });
    if (path.endsWith("/memories") && method === "POST") {
      const item = (body.items as Array<{ content: string; document_id: string; metadata: Record<string, string>; tags: string[] }>)[0]!;
      item.metadata = { ...item.metadata, dahlia_ingestion_policy: policy };
      documents.set(item.document_id, item);
      for (const [id, fact] of facts) if (fact.document_id === item.document_id) facts.delete(id);
      const id = uuidV7(); facts.set(id, { id, text: item.content, document_id: item.document_id, metadata: item.metadata, tags: item.tags, updated_at: new Date().toISOString(), state: "valid", type: "world" });
      operations.set(String(body.operation_id), "completed"); return Response.json({ operation_id: body.operation_id });
    }
    if (path.includes("/operations/")) {
      if (path.endsWith("/retry")) { operations.set(path.split("/").at(-2)!, "completed"); return Response.json({}); }
      return Response.json({ status: operations.get(path.split("/").at(-1)!) ?? "not_found" });
    }
    if (path.endsWith("/mental-models")) {
      if (method === "POST") { generate(body as unknown as ReturnType<typeof standardModel>); return operation(); }
      return Response.json({ items: [...models.keys()].map((id) => ({ id })) });
    }
    if (path.endsWith("/refresh")) { const model = models.get(path.split("/").at(-2)!)!; generate(model); return operation(); }
    if (path.includes("/mental-models/")) {
      const id = path.split("/").at(-1)!, model = models.get(id);
      if (method === "PATCH") { Object.assign(model!, body); return Response.json(model); }
      if (method === "DELETE") { models.delete(id); return Response.json({}); }
      return model ? Response.json(model) : new Response(null, { status: 404 });
    }
    if (path.includes("/memories/")) { const fact = facts.get(path.split("/").at(-1)!); return fact ? Response.json(fact) : new Response(null, { status: 404 }); }
    if (path.endsWith("/reprocess")) {
      const id = new URL(String(url)).searchParams.get("operation_id")!; operations.set(id, "completed"); return Response.json({ operation_id: id });
    }
    if (path.includes("/documents/") && method === "GET") {
      const id = path.split("/").at(-1)!, document = documents.get(id);
      return document ? Response.json({ id, bank_id: `dahlia_${encodeId("workspace", workspace)}`, original_text: document.content, memory_unit_count: 1,
        retain_params: { metadata: document.metadata } }) : new Response(null, { status: 404 });
    }
    if (path.includes("/documents/") && method === "DELETE") { for (const [id, fact] of facts) if (fact.document_id === path.split("/").at(-1)) facts.delete(id); return Response.json({}); }
    throw new Error("Unexpected synthetic upstream route");
  });
  const engine = new WorkspaceMemoryService(config, app.memory!, sync, app.sync, transport);
  const memory = new DahliaMemory({ personal: app.personalMemory!, workspace: app.memory! }, sync, { workspace: engine });
  const tick = async () => { db.exec("UPDATE workspace_memory_state SET available_at = 0"); await engine.step(workspace, signal); };
  await engine.configure(owner, workspace, true);
  const notes = [];
  for (let i = 0; i < count; i++) notes.push(await app.memory!.saveNote(owner.userId, workspace, { id: uuidV7(), content: `Canonical source ${i + 1}`, revision: 0 }));
  const ready = async () => {
    for (let i = 0; i < 100; i++) {
      await tick();
      const page = await app.memory!.page(owner.userId, workspace, "workspace-insights");
      if (page?.snapshot && page.generation === (await app.memory!.status(owner.userId, workspace))?.generation) return;
    }
    throw new Error(`Publication not ready: ${JSON.stringify(await app.memory!.page(owner.userId, workspace, "workspace-insights"))}`);
  };
  if (count) await ready();
  const input = { workspaceId, pageId: "workspace-insights" };
  const get = () => memory.pages.get(owner, input, signal);
  const http = createApp({ config, authStore: app, syncService: sync, workspaceMemory: engine });
  const request = (suffix = "/workspace-insights", method = "GET", identity = owner) => http.request(`/api/v1/workspaces/${workspaceId}/memory/pages${suffix}`, { method,
    headers: { "x-forwarded-email": identity.email, "x-dahlia-workspace-transfers": "1" } });
  return { app, db, sync, config, engine, memory, owner, viewer, workspace, workspaceId, input, get, request, notes, facts, models, calls, operations, tick, ready, commit, generate,
    setPolicy: (value: string) => { policy = value; },
    intercept: (callback?: typeof intercept) => { intercept = callback; }, close: async () => { db.close(); await app.close?.(); } };
}

describe("Knowledge Pages publication", () => {
  it("withholds body, snippet, export and tool output during ingestion settings migration", async () => {
    const f = await fixture(2);
    try {
      f.setPolicy("b".repeat(64));
      expect(await f.get()).toMatchObject({ status: "stale", body: null, snippet: null });
      expect((await f.request("/workspace-insights/export")).status).toBe(409);
      expect(await f.memory.pages.list(f.owner, { workspaceId: f.workspaceId }, signal)).toMatchObject({ items: [{ status: "stale", snippet: null }] });
      const tools = createDahliaMemoryTools(f.memory, true);
      expect(await tools.get_knowledge_page.execute!(f.input, { requestContext: meetingRequestContext(f.owner), abortSignal: signal } as never))
        .toMatchObject({ body: null, snippet: null });
      await f.ready();
      expect(await f.get()).toMatchObject({ status: "ready", body: "Synthetic generated hypothesis" });
    } finally { await f.close(); }
  });

  it("publishes all six sources through Web API, export and AI; invalidates the sixth everywhere", async () => {
    const f = await fixture();
    try {
      expect(await f.get()).toMatchObject({ status: "ready", body: "Synthetic generated hypothesis", coverage: "ready" });
      expect((await f.get()).sources).toHaveLength(6);
      const page = await f.request(); expect(page.status).toBe(200); expect(page.headers.get("cache-control")).toBe("no-store");
      expect(await (await f.request("/workspace-insights/export")).text()).toContain("Synthetic generated hypothesis");
      const tools = createDahliaMemoryTools(f.memory, true);
      expect(Object.keys(tools).filter((id) => id.includes("knowledge_page")).sort()).toEqual(["get_knowledge_page", "list_knowledge_pages"]);
      const context = { requestContext: meetingRequestContext(f.owner), abortSignal: signal } as never;
      expect(await tools.get_knowledge_page.execute!(f.input, context)).toMatchObject({ status: "ready" });
      f.facts.get([...f.facts.keys()][5]!)!.state = "invalidated";
      for (const result of [await f.get(), await (await f.request()).json(), await tools.get_knowledge_page.execute!(f.input, context)])
        expect(result).toMatchObject({ status: "source_invalid", body: null, snippet: null, sources: [] });
      expect((await f.request("/workspace-insights/export")).status).toBe(409);
      expect(await f.memory.pages.list(f.owner, { workspaceId: f.workspaceId, query: "Synthetic" }, signal)).toEqual({ items: [], nextCursor: null });
      expect(await tools.list_knowledge_pages.execute!({ workspaceId: f.workspaceId }, context)).toMatchObject({ items: [{ status: "source_invalid", snippet: null }] });
      expect(f.calls.every((call) => !call.path.includes("knowledge-base"))).toBe(true);
    } finally { await f.close(); }
  });
  it.each(["missing", "other-bank", "cycle", "page", "empty", "revision", "mutated-after-generation"])("fails closed for %s lineage", async (mode) => {
    const f = await fixture();
    try {
      const fact = [...f.facts.values()][5]!, model = f.models.get("workspace-insights")!;
      if (mode === "missing" || mode === "other-bank") f.facts.delete(fact.id); // Bank-scoped route cannot resolve another bank's ID.
      if (mode === "cycle") { fact.type = "observation"; fact.document_id = null; fact.source_memory_ids = [fact.id]; model.reflect_response.based_on = { observation: [{ id: fact.id, text: fact.text }] }; }
      if (mode === "page") model.reflect_response.based_on["mental-models"] = [{ id: "project-fake", text: "Page" }];
      if (mode === "empty") model.reflect_response.based_on = {};
      if (mode === "revision") fact.metadata.source_revision = "old-revision";
      if (mode === "mutated-after-generation") fact.updated_at = "2099-01-01T00:00:00Z";
      // Adoption itself must fail, not only reads against an older fingerprint.
      f.db.exec("UPDATE knowledge_pages SET snapshot = NULL");
      await f.tick(); await f.tick();
      expect(await f.get()).toMatchObject({ body: null, snippet: null, sources: [] });
      expect((await f.get()).status).not.toBe("ready");
      expect((await f.request("/workspace-insights/export")).status).toBe(409);
    } finally { await f.close(); }
  });
  it("expands observations without the conversation search limits", async () => {
    const f = await fixture(31);
    try {
      const id = uuidV7(), model = f.models.get("workspace-insights")!;
      f.facts.set(id, { id, text: "Consolidated synthetic fact", type: "observation", document_id: null, source_memory_ids: [...f.facts.keys()], state: "valid", metadata: {}, updated_at: model.reflect_response.dahlia_generation!.cutoff });
      model.reflect_response.based_on = { observation: [{ id, text: "Consolidated synthetic fact" }] };
      await f.tick(); await f.tick();
      expect((await f.get()).sources).toHaveLength(31);
      f.facts.get([...f.facts.keys()][5]!)!.state = "invalidated";
      expect(await f.get()).toMatchObject({ status: "source_invalid", body: null });
    } finally { await f.close(); }
  });
  it.each(["update", "delete"])("hides old content after canonical %s without waiting for analysis", async (mode) => {
    const f = await fixture();
    try {
      const note = f.notes[5]!;
      if (mode === "update") await f.app.memory!.saveNote(f.owner.userId, f.workspace, { id: note.id, revision: 1, content: "Corrected" });
      else await f.app.memory!.deleteNote(f.owner.userId, f.workspace, note.id, 1);
      expect(await f.get()).toMatchObject({ body: null, snippet: null, sources: [] });
      expect((await f.request("/workspace-insights/export")).status).toBe(409);
    } finally { await f.close(); }
  });
  it("rejects revoked authorization after remote I/O and propagates cancellation", async () => {
    const f = await fixture();
    try {
      f.intercept((path) => { if (path.includes("/mental-models/")) f.db.prepare("DELETE FROM workspace_permissions WHERE principal_id = ?").run(f.viewer.userId); });
      await expect(f.memory.pages.get(f.viewer, f.input, signal)).rejects.toMatchObject({ status: 404 });
      f.intercept(); const controller = new AbortController(); controller.abort();
      await expect(f.memory.pages.get(f.owner, f.input, controller.signal)).rejects.toThrow();
    } finally { await f.close(); }
  });
  it("distinguishes partial, paused, unconfigured and failed upstream without leaking cached prose", async () => {
    const f = await fixture();
    try {
      f.db.exec(`UPDATE workspace_memory_state SET progress = json_set(progress, '$.failures.example', 'source_too_large')`);
      expect(await f.get()).toMatchObject({ status: "ready", coverage: "partial", skippedCount: 1 });
      f.intercept(() => { throw new Error("synthetic transport failure"); });
      expect(await f.get()).toMatchObject({ status: "error", body: null, sources: [] });
      f.intercept(); expect((await f.get()).status).toBe("ready");
      await f.engine.configure(f.owner, f.workspace, false);
      expect(await f.get()).toMatchObject({ status: "paused", body: null });
      const unconfigured = new DahliaMemory(f.memory.stores, f.sync, {});
      expect(await unconfigured.pages.get(f.owner, f.input, signal)).toMatchObject({ status: "unavailable", body: null });
    } finally { await f.close(); }
  });
  it("queues admin regeneration without remote calls; old generations and lost leases cannot publish", async () => {
    const f = await fixture();
    try {
      const count = f.calls.length;
      expect((await f.request("/workspace-insights/refresh", "POST", f.viewer)).status).toBe(404);
      expect((await f.request("/workspace-insights/refresh", "POST")).status).toBe(202);
      expect((await f.request("/workspace-insights/refresh", "POST")).status).toBe(202);
      expect(f.calls).toHaveLength(count);
      const row = (await f.app.memory!.page(f.owner.userId, f.workspace, "workspace-insights"))!;
      expect(row.requestVersion).toBe(1);
      expect(await f.get()).toMatchObject({ status: "generating", body: null });
      f.db.exec("UPDATE workspace_memory_state SET available_at = 0");
      const job = (await f.app.memory!.claim(f.workspace))!;
      expect(await f.app.memory!.savePage(f.owner.userId, { ...job, generation: job.generation - 1 }, row, { status: "ready" })).toBe(false);
      expect(await f.app.memory!.savePage(f.owner.userId, { ...job, lease: uuidV7() }, row, { status: "ready" })).toBe(false);
      await f.app.memory!.release(job, { availableAt: new Date(0) });
      for (let i = 0; i < 10; i++) await f.tick();
      expect((await f.get()).status).toBe("ready");
      const send = vi.fn(), sendBatch = vi.fn();
      const queue = createQueueJobs({ DAHLIA_MEMORY_QUEUE: { send, sendBatch } }, {} as never, f.app.sync, f.sync, [], undefined, undefined, f.engine);
      f.models.get("workspace-insights")!.content = "Automatic refresh";
      f.db.exec("UPDATE workspace_memory_state SET available_at = 0, progress = json_remove(progress, '$.pageAfter')");
      await queue.consume({ action: "memory", workspaceId: f.workspace }, signal);
      expect((await f.get()).body).toBe("Automatic refresh");
      expect(send).toHaveBeenCalledWith({ action: "memory", workspaceId: f.workspace }, { delaySeconds: 5 });
    } finally { await f.close(); }
  });
  it("reconciles canonical Project membership and filters Project pages", async () => {
    const f = await fixture(0);
    try {
      const projectId = uuidV7(), meetingId = uuidV7(), now = new Date().toISOString();
      const meeting = { projectId, name: "Meeting", description: "Evidence", status: "READY", duration: 60, recordingStartedAt: now, createdAt: now, updatedAt: now };
      await f.commit([{ entity: "project", action: "create", entityId: projectId, baseRevision: null,
        data: { name: "Project", parentProjectId: null, projectType: null, createdAt: now } },
      { entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: meeting }]);
      await f.ready();
      const input = { workspaceId: f.workspaceId, pageId: `project-${projectId}` };
      for (let i = 0; i < 5; i++) await f.tick();
      expect(await f.memory.pages.get(f.owner, input, signal)).toMatchObject({ status: "ready", sources: [{ id: encodeId("meeting", meetingId), href: `/o/${encodeId("meeting", meetingId)}` }] });
      expect((await f.memory.pages.list(f.owner, { workspaceId: f.workspaceId, projectId: encodeId("project", projectId) }, signal)).items.map((page) => page.id)).toEqual([input.pageId]);
      await f.commit([{ entity: "meeting", action: "update", entityId: meetingId, baseRevision: 1, data: { projectId: null, name: meeting.name, description: meeting.description, status: "READY", duration: 60, recordingStartedAt: now, updatedAt: now } }]);
      expect(await f.memory.pages.get(f.owner, input, signal)).toMatchObject({ body: null, snippet: null, sources: [] });
      await expect(f.memory.pages.list(f.owner, { workspaceId: f.workspaceId, projectId: encodeId("project", uuidV7()) }, signal)).rejects.toMatchObject({ status: 404 });
    } finally { await f.close(); }
  });
  it.each(["invalidated", "edited", "deleted"])("withholds list and search snippets when an earlier page's fact is %s during later validation", async (mode) => {
    const f = await fixture(0);
    try {
      const projectId = uuidV7(), meetingId = uuidV7(), now = new Date().toISOString();
      await f.commit([{ entity: "project", action: "create", entityId: projectId, baseRevision: null,
        data: { name: "Project", parentProjectId: null, projectType: null, createdAt: now } },
      { entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
        data: { projectId, name: "Meeting", description: "Evidence", status: "READY", duration: 60, recordingStartedAt: now, createdAt: now, updatedAt: now } }]);
      await f.ready();
      for (let i = 0; i < 5; i++) await f.tick();
      const fact = structuredClone([...f.facts.values()][0]!);
      const tools = createDahliaMemoryTools(f.memory, true);
      for (const surface of ["api-list", "tool-search"]) {
        expect((await f.memory.pages.list(f.owner, { workspaceId: f.workspaceId }, signal)).items.every((page) => page.status === "ready")).toBe(true);
        f.intercept((path) => {
          if (!path.endsWith("/mental-models/workspace-insights")) return;
          if (mode === "deleted") f.facts.delete(fact.id);
          else if (mode === "invalidated") f.facts.get(fact.id)!.state = "invalidated";
          else f.facts.get(fact.id)!.text = "Changed fact";
        });
        const result = surface === "api-list" ? await (await f.request("")).json() : await tools.list_knowledge_pages.execute!(
          { workspaceId: f.workspaceId, query: "Synthetic" }, { requestContext: meetingRequestContext(f.owner), abortSignal: signal } as never);
        expect(JSON.stringify(result)).not.toContain("Synthetic generated hypothesis");
        if (surface === "api-list") expect(result).toMatchObject({ items: [
          { id: `project-${projectId}`, status: "source_invalid", snippet: null },
          { id: "workspace-insights", status: "source_invalid", snippet: null },
        ] });
        else expect(result).toEqual({ items: [], nextCursor: null });
        f.intercept(); f.facts.set(fact.id, structuredClone(fact));
        expect((await f.memory.pages.list(f.owner, { workspaceId: f.workspaceId }, signal)).items.every((page) => page.status === "ready")).toBe(true);
      }
    } finally { await f.close(); }
  });
  it("adopts automatic refresh through the Node worker and rejects sub-millisecond fact mutations", async () => {
    const f = await fixture();
    const worker = new MemoryWorker(f.engine);
    try {
      f.models.get("workspace-insights")!.content = "Node automatic update";
      expect((await f.get()).status).toBe("stale");
      f.db.exec("UPDATE workspace_memory_state SET available_at = 0, progress = json_remove(progress, '$.pageAfter')");
      worker.start();
      await vi.waitFor(async () => expect((await f.get()).body).toBe("Node automatic update"));
      await worker.stop();
      f.models.get("workspace-insights")!.reflect_response.dahlia_generation!.cutoff = "2026-09-28T00:00:00.123001Z";
      for (const fact of f.facts.values()) fact.updated_at = "2026-09-28T00:00:00.123002Z";
      await f.tick(); await f.tick();
      expect((await f.get()).status).toBe("source_invalid");
    } finally { await worker.stop(); await f.close(); }
  });
  it("retries failed page operations and recovers an unchanged-text canonical revision", async () => {
    const f = await fixture();
    try {
      await f.app.memory!.saveNote(f.owner.userId, f.workspace, { id: f.notes[0]!.id, revision: 1, content: f.notes[0]!.content });
      await f.ready();
      expect((await f.get()).sources.find((source) => source.id === encodeId("sharedMemory", f.notes[0]!.id))?.revision).toBe("2");
      await f.memory.pages.refresh(f.owner, f.input);
      f.db.exec("UPDATE workspace_memory_state SET progress = json_remove(progress, '$.pageAfter')");
      await f.tick();
      const operation = (await f.app.memory!.page(f.owner.userId, f.workspace, f.input.pageId))!.operation!;
      f.operations.set(operation.id, "failed");
      for (let i = 0; i < 6; i++) await f.tick();
      expect(f.calls.some((call) => call.path.endsWith(`/operations/${operation.id}/retry`))).toBe(true);
      expect((await f.get()).status).toBe("ready");
    } finally { await f.close(); }
  });

  it.each(["policy", "exhausted"])("does not restart a first page's terminal %s failure without a change", async (mode) => {
    const f = await fixture(1);
    try {
      const model = f.models.get("workspace-insights")!;
      model.content = ""; delete model.reflect_response.dahlia_generation;
      const id = uuidV7(); f.operations.set(id, "failed");
      f.db.prepare("UPDATE knowledge_pages SET snapshot = NULL, status = 'generating', operation = ?")
        .run(JSON.stringify({ id, version: 0, attempts: 0 }));
      const detail = vi.spyOn(f.engine.client, "operationDetail").mockResolvedValue({ status: "failed",
        ...(mode === "policy" ? { dahlia_error_code: "memory_policy_blocked" as const } : {}) });
      const before = f.calls.length;
      for (let i = 0; i < 24; i++) await f.tick();
      expect(f.calls.slice(before).filter((call) => call.path.endsWith("/refresh"))).toHaveLength(0);
      expect(f.calls.slice(before).filter((call) => call.path.endsWith("/retry"))).toHaveLength(mode === "policy" ? 0 : 3);
      expect(await f.app.memory!.page(f.owner.userId, f.workspace, f.input.pageId))
        .toMatchObject({ status: "error", snapshot: null, operation: { id, attempts: 3 } });
      expect((await f.get()).body).toBeNull();
      detail.mockRestore();
      if (mode === "policy") await f.memory.pages.refresh(f.owner, f.input);
      else f.generate(standardModel(null));
      await f.ready();
      expect((await f.get()).status).toBe("ready");
    } finally { await f.close(); }
  });

  it("never replaces a newer publication with an old operation's late completion", async () => {
    const f = await fixture();
    try {
      const old = structuredClone(f.models.get("workspace-insights")!);
      const updated = f.models.get("workspace-insights")!;
      updated.content = "New publication";
      updated.reflect_response.dahlia_generation!.cutoff = new Date(Date.now() + 1000).toISOString();
      await f.tick(); await f.tick();
      expect((await f.get()).body).toBe("New publication");
      f.models.set("workspace-insights", old);
      await f.tick(); await f.tick();
      expect(await f.get()).toMatchObject({ status: "stale", body: null });
      expect((await f.app.memory!.page(f.owner.userId, f.workspace, "workspace-insights"))!.snapshot!.body).toBe("New publication");
    } finally { await f.close(); }
  });
  it.each(["deleted", "reconfigured", "missing-marker"])("repairs a %s standard model without a manual request", async (mode) => {
    const f = await fixture();
    try {
      if (mode === "deleted") f.models.delete("workspace-insights");
      else if (mode === "missing-marker") delete f.models.get("workspace-insights")!.reflect_response.dahlia_generation;
      else f.models.get("workspace-insights")!.source_query = "Nonstandard query";
      expect((await f.get()).body).toBeNull();
      for (let i = 0; i < 10; i++) await f.tick();
      expect(await f.get()).toMatchObject({ status: "ready", body: "Synthetic generated hypothesis" });
      expect(f.models.get("workspace-insights")!.source_query).toBe(standardModel(null).source_query);
    } finally { await f.close(); }
  });
  it.each(["detail-refresh", "list-refresh", "detail-invalidated", "list-invalidated"])("fences %s at the last local publication read", async (mode) => {
    const f = await fixture();
    try {
      const publications = f.app.memory!.publications.bind(f.app.memory!);
      let reads = 0;
      vi.spyOn(f.app.memory!, "publications").mockImplementation(async (...args) => {
        if (++reads === (mode.startsWith("list") ? 2 : 1)) {
          if (mode.endsWith("refresh")) await f.memory.pages.refresh(f.owner, f.input);
          else f.db.exec("UPDATE knowledge_pages SET status = 'source_invalid'");
        }
        return publications(...args);
      });
      const result = mode.startsWith("list") ? await f.memory.pages.list(f.owner, { workspaceId: f.workspaceId, query: "Synthetic" }, signal) : await f.get();
      expect(JSON.stringify(result)).not.toContain("Synthetic generated hypothesis");
      if ("items" in result) expect(result.items).toEqual([]);
      else expect(result).toMatchObject({ status: "stale", body: null, snippet: null, sources: [] });
    } finally { await f.close(); }
  });
  it.each(["canonical-edit", "automatic-refresh", "old-pending"])("supersedes an old operation after %s", async (mode) => {
    const f = await fixture();
    try {
      const id = uuidV7(), pending = mode === "old-pending";
      f.operations.set(id, pending ? "pending" : "failed");
      f.db.prepare("UPDATE knowledge_pages SET status = ?, operation = ?").run(pending ? "generating" : "error", JSON.stringify({ id, version: 0, attempts: pending ? 0 : 3 }));
      await f.tick(); await f.tick();
      expect((await f.app.memory!.page(f.owner.userId, f.workspace, "workspace-insights"))!.operation?.id).toBe(id);
      if (mode === "automatic-refresh") f.generate(standardModel(null)).content = "Automatic recovery";
      else await f.app.memory!.saveNote(f.owner.userId, f.workspace, { id: f.notes[0]!.id, revision: 1, content: "Updated canonical source" });
      for (let i = 0; i < 30; i++) await f.tick();
      expect((await f.get()).status).toBe("ready");
      expect((await f.app.memory!.page(f.owner.userId, f.workspace, "workspace-insights"))!.operation).toBeNull();
      expect(f.calls.filter((call) => call.path.endsWith(`/operations/${id}/retry`))).toHaveLength(0);
    } finally { await f.close(); }
  });
  it("recovers a lost refresh response and cancels during upstream validation", async () => {
    const f = await fixture();
    try {
      await f.memory.pages.refresh(f.owner, f.input);
      f.db.exec("UPDATE workspace_memory_state SET progress = json_remove(progress, '$.pageAfter')");
      const create = f.engine.client.createModel.bind(f.engine.client);
      const spy = vi.spyOn(f.engine.client, "createModel").mockImplementationOnce(async (...args) => { await create(...args); throw new Error("Lost acknowledgement"); });
      await f.tick();
      expect(await f.get()).toMatchObject({ status: "error", body: null });
      for (let i = 0; i < 8; i++) await f.tick();
      expect((await f.get()).status).toBe("ready");
      spy.mockRestore();
      const controller = new AbortController();
      f.intercept((path) => { if (path.includes("/memories/")) controller.abort(); });
      await expect(f.memory.pages.get(f.owner, f.input, controller.signal)).rejects.toThrow();
    } finally { await f.close(); }
  });
  it("distinguishes empty evidence and paginates only standard currently authorized pages", async () => {
    const f = await fixture(0);
    try {
      for (let i = 0; i < 12; i++) await f.tick();
      expect(await f.get()).toMatchObject({ status: "no_sources", body: null, sources: [] });
      const projects = Array.from({ length: 21 }, () => uuidV7());
      await f.commit(projects.map((id) => ({ entity: "project", action: "create", entityId: id, baseRevision: null,
        data: { name: "Synthetic project", parentProjectId: null, projectType: null, createdAt: new Date().toISOString() } })));
      await f.app.memory!.ensurePages(f.owner.userId, f.workspace);
      await f.engine.configure(f.owner, f.workspace, false);
      const first = await f.memory.pages.list(f.viewer, { workspaceId: f.workspaceId }, signal);
      expect(first.items).toHaveLength(20); expect(first.items.every((page) => page.status === "paused" && page.body === null)).toBe(true);
      const next = await f.memory.pages.list(f.viewer, { workspaceId: f.workspaceId, after: first.nextCursor! }, signal);
      expect(next.items).toHaveLength(2); expect(next.nextCursor).toBeNull();
      expect(new Set([...first.items, ...next.items].map((page) => page.id)).size).toBe(22);
    } finally { await f.close(); }
  });

});
