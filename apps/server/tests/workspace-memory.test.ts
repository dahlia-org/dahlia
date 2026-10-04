import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { loadConfig, type AppConfig } from "../src/config";
import type { Identity } from "../src/auth/identity";
import { seedHeaderIdentity, testUserID, testOrganizationID } from "./public-test-client";
import { uuidV7 } from "@dahlia-ai/ui/model/id";
import { MeetingSyncService } from "../src/sync/service";
import { WorkspaceMemoryService } from "../src/memory/service";
import { HindsightClient, HindsightError } from "../src/memory/hindsight";
import { DatabricksTokenError } from "../src/databricks/token";
import { sharedMemorySchema } from "../src/memory/model";
import { createQueueJobs } from "../src/jobs/queues";
import { createApp } from "../src/app";
import { decodeId, encodeId } from "@dahlia-ai/ui/model/typeid";
import { compareMemoryIngestion } from "../scripts/evaluate-memory-ingestion";
import { contentHash, meetingDocument } from "../src/memory/sources";

const owner: Identity = { userId: testUserID("memory-owner"), source: "header" };
const viewer: Identity = { userId: testUserID("memory-viewer"), source: "header" };
const workspaceId = "019d4a00-0000-7000-8000-000000000100";
const directories: string[] = [];
afterEach(() => { vi.useRealTimers(); directories.splice(0).forEach((path) => rmSync(path, { recursive: true, force: true })); });
async function setup(images = false) {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-memory-")); directories.push(directory);
  const databasePath = join(directory, "test.sqlite");
  const config: AppConfig = { authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite", databaseUrl: `file:${databasePath}`,
    baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1024 * 1024,
    hindsight: { url: "https://memory.example/api", auth: "bearer", apiKey: "test-secret", ...(images ? { images: { model: "system.ai.gpt-6-luna", maxCount: 8, maxBytes: 8 * 1024 * 1024, longEdge: 1568 as const } } : {}) } };
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
  const metadata = new Map<string, Record<string, string>>();
  const attachments = new Map<string, Array<{ id: string; hash: string; kind: string; media_type: string; byte_size: number }>>();
  const counts = new Map<string, number>();
  const errorCodes = new Map<string, string>();
  let policy = "a".repeat(64);
  const models = new Map<string, boolean>();
  const failingItems = new Set<string>();
  const chunks = new Map<string, { bank_id: string; document_id: string; chunk_text: string }>();
  let recall: (() => unknown) | undefined;
  let reflection: (() => unknown) | undefined;
  const facts = new Map<string, unknown>();
  let loseAcknowledgement = false;
  const transport = vi.fn<typeof fetch>(async (url, init) => {
    expect(new Headers(init?.headers).get("authorization")).toBe("Bearer test-secret");
    expect(init?.redirect).toBe("error");
    const path = new URL(String(url)).pathname;
    const body = (init?.body ? JSON.parse(String(init.body)) : {}) as Record<string, unknown>;
    requests.push({ path, method: init?.method ?? "GET", body });
    if (path.endsWith("/config")) return Response.json({ bank_id: path.split("/banks/")[1]!.split("/")[0], dahlia_ingestion_policy: policy, dahlia_images: images ? { enabled: true, provider: "databricks", model: "system.ai.gpt-6-luna", max_count: 8, max_bytes: 8 * 1024 * 1024, max_per_chunk: 1, max_completion_tokens: 16000, timeout: 120, retries: 0 } : null });
    if (path.startsWith("/api/v1/default/chunks/")) {
      const chunk = chunks.get(decodeURIComponent(path.split("/").at(-1)!));
      return chunk ? Response.json({ chunk_id: path.split("/").at(-1), chunk_index: 0, created_at: "", ...chunk }) : new Response(null, { status: 404 });
    }
    if (path.endsWith("/reflect")) return Response.json(reflection?.() ?? { text: "Hypothesis", based_on: { memories: [], mental_models: [] } });
    if (path.endsWith("/memories") && init?.method === "POST") {
      const item = (body.items as Array<{ document_id: string; content: string; metadata: Record<string, string> }>)[0]!;
      metadata.set(item.document_id, { ...item.metadata, dahlia_ingestion_policy: policy });
      if (Array.isArray(item.content)) {
        let text = "", afterImage = false;
        const stored = [];
        for (const block of item.content as import("../src/memory/images").ImageContentBlock[]) {
          if (block.type === "text") { if (afterImage) text = `${text.replace(/\n+$/u, "")}\n\n`; text += block.text; afterImage = false; }
          else {
            const bytes = atob(block.source.data), hash = await contentHash(bytes);
            if (text) text = `${text.replace(/\n+$/u, "")}\n\n`;
            text += `⟦hs-att:${hash.slice(0, 12)}⟧`; afterImage = true;
            stored.push({ id: hash.slice(0, 12), hash, kind: "image", media_type: block.source.media_type, byte_size: bytes.length });
          }
        }
        attachments.set(item.document_id, stored); retained.set(item.document_id, text);
      } else { attachments.delete(item.document_id); retained.set(item.document_id, item.content); } operations.set(String(body.operation_id), failingItems.has(item.document_id) ? "failed" : "completed");
      if (loseAcknowledgement) { loseAcknowledgement = false; throw new Error("lost acknowledgement"); }
      return Response.json({ operation_id: body.operation_id });
    }
    if (path.includes("/operations/")) {
      if (path.endsWith("/retry")) { operations.set(path.split("/").at(-2)!, "pending"); return Response.json({}); }
      const id = path.split("/").at(-1)!;
      const status = operations.get(id) ?? "not_found";
      if (status === "pending") operations.set(id, "failed");
      return Response.json({ status, dahlia_error_code: errorCodes.get(id) });
    }
    if (path.endsWith("/mental-models") && init?.method === "GET") return Response.json({ items: [...models.keys()].map((id) => ({ id })) });
    if (path.endsWith("/mental-models") && init?.method === "POST") {
      models.set(String(body.id), true); const id = uuidV7(); operations.set(id, failingItems.has(String(body.id)) ? "cancelled" : "completed"); return Response.json({ operation_id: id });
    }
    if (path.endsWith("/refresh") && init?.method === "POST") {
      const id = uuidV7(); operations.set(id, failingItems.has(path.split("/").at(-2)!) ? "failed" : "completed"); return Response.json({ operation_id: id });
    }
    if (path.includes("/mental-models/") && init?.method === "PATCH") return Response.json({});
    if (path.includes("/mental-models/") && init?.method === "GET") return models.has(path.split("/").at(-1)!) ? Response.json({}) : new Response(null, { status: 404 });
    if (path.includes("/mental-models/") && init?.method === "DELETE") { models.delete(path.split("/").at(-1)!); return Response.json({}); }
    if (path.endsWith("/reprocess")) {
      if (!retained.has(path.split("/").at(-2)!)) return new Response(null, { status: 404 });
      const id = new URL(String(url)).searchParams.get("operation_id")!;
      operations.set(id, "completed");
      if (loseAcknowledgement) { loseAcknowledgement = false; throw new Error("lost acknowledgement"); }
      return Response.json({ operation_id: id });
    }
    if (path.includes("/documents/") && init?.method === "GET") {
      const id = path.split("/").at(-1)!;
      return retained.has(id) ? Response.json({ id, bank_id: path.split("/banks/")[1]!.split("/")[0], original_text: retained.get(id),
        attachments: attachments.get(id), memory_unit_count: counts.get(id) ?? 1, retain_params: { metadata: metadata.get(id) } }) : new Response(null, { status: 404 });
    }
    if (path.includes("/documents/") && init?.method === "DELETE") { retained.delete(path.split("/").at(-1)!); return Response.json({}); }
    if (path.endsWith("/memories/recall")) return Response.json(recall?.() ?? { results: [...retained.keys()].map((document_id) => ({ id: uuidV7(), document_id, text: "UNTRUSTED EXTRACTED CLAIM" })) });
    if (path.includes("/memories/")) {
      const fact = facts.get(decodeURIComponent(path.split("/").at(-1)!));
      return fact ? Response.json(fact) : new Response(null, { status: 404 });
    }
    if (init?.method === "DELETE") { retained.clear(); models.clear(); return Response.json({}); }
    throw new Error(`Unexpected mock route ${path}`);
  });
  const memory = new WorkspaceMemoryService(config, app.memory!, sync, app.sync, transport);
  const tick = async () => { db.exec("UPDATE jobs_queue SET available_at = 0 WHERE kind = 'workspace-memory'"); await memory.step(workspaceId, new AbortController().signal); };
  const ready = async (maxSteps = 80) => {
    for (let i = 0; i < maxSteps; i++) {
      await tick(); if (["ready", "partial"].includes((await memory.status(owner, workspaceId)).status)) return;
    }
    throw new Error(JSON.stringify(await memory.status(owner, workspaceId)));
  };
  const close = async () => { db.close(); await app.close?.(); };
  return { app, config, db, sync, memory, commit, tick, ready, close, requests, retained, operations, models, failingItems, chunks,
    metadata, attachments, counts, errorCodes, setPolicy: (value: string) => { policy = value; },
    transport, facts, setReflection: (response: () => unknown) => { reflection = response; },
    setRecall: (response: (() => unknown) | undefined) => { recall = response; },
    recallBodies: () => requests.filter((r) => r.path.endsWith("/memories/recall")).map((r) => r.body),
    loseNextAcknowledgement: () => { loseAcknowledgement = true; } };
}

async function screenshotFixture(f: Awaited<ReturnType<typeof setup>>) {
  const meetingId = uuidV7(), fileId = uuidV7(), screenshotId = uuidV7(), now = new Date();
  await f.commit([{ entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
    data: { projectId: null, name: "Synthetic", description: "", status: "READY", duration: 60,
      recordingStartedAt: now.toISOString(), createdAt: now.toISOString(), updatedAt: now.toISOString() } }]);
  const hash = await contentHash("synthetic-pixels");
  const shot = { screenshotId, fileId, meetingId, workspaceId, capturedAt: now, contentType: "image/webp", storageKey: "unused",
    contentLength: 16, contentHash: hash, ocrText: "OCR-MARKER", caption: "CAPTION-MARKER" };
  vi.spyOn(f.sync, "listScreenshots").mockResolvedValue({ items: [shot] });
  vi.spyOn(f.sync, "readFileContent").mockResolvedValue({ upstream: new Response("synthetic-pixels") } as never);
  // A new stream for every bounded worker read.
  f.sync.readFileContent = vi.fn().mockImplementation(async () => ({ upstream: new Response("synthetic-pixels") }));
  const withIdentity = f.app.sync.withIdentity.bind(f.app.sync);
  vi.spyOn(f.app.sync, "withIdentity").mockImplementation((identity, fn) => withIdentity(identity, (scoped) => fn({ ...scoped,
    listUninformativeScreenshots: async () => [], getScreenshot: async () => shot,
    getFile: async () => ({ fileId, workspaceId, checksum: `SHA-256:${hash}`, metadata: { source: "screenshot" } }) as never,
  })));
  return { meetingId, hash, shot };
}

describe("Workspace memory", () => {
  it.each(["existing", "probe-failed", "creation-unacknowledged"])("does not delete an evaluation bank when %s", async (mode) => {
    const f = await setup(), requests: Array<{ bank: string; method: string }> = [];
    try {
      await f.memory.configure(owner, workspaceId, true);
      await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Synthetic evidence" });
      await f.ready();
      const transport: typeof fetch = async (url, init) => {
        const bank = new URL(String(url)).pathname.split("/banks/")[1]!.split("/")[0]!, method = init?.method ?? "GET";
        requests.push({ bank, method });
        if (!bank.startsWith("dahlia_eval_")) {
          expect(bank).toBe(f.memory.client.bank(workspaceId));
          expect(method).toBe("GET");
          return Response.json({ bank_id: bank, dahlia_ingestion_policy: "a".repeat(64), config: {} });
        }
        if (method === "GET") return mode === "existing" ? Response.json({ bank_id: bank })
          : new Response(null, { status: mode === "probe-failed" ? 503 : 404 });
        throw new Error("Synthetic acknowledgement loss");
      };
      await expect(compareMemoryIngestion({ config: f.config, store: f.app.memory!, sync: f.sync, syncStore: f.app.sync,
        identity: owner, scopeId: workspaceId, transport, signal: new AbortController().signal, questions: [] }))
        .rejects.toMatchObject({ code: mode === "existing" ? "memory_evaluation_bank_exists" : mode === "probe-failed" ? "memory_upstream_failed" : "memory_transport_failed" });
      expect(requests.filter((request) => request.method === "DELETE")).toEqual([]);
      expect(requests.filter((request) => request.method !== "GET")).toHaveLength(mode === "creation-unacknowledged" ? 1 : 0);
    } finally { await f.close(); }
  });

  it.each(["wrong-kind", "wrong-source", "raw-uuid", "malformed"])("rejects %s document references even with a matching saved content hash", async (variant) => {
    const f = await setup(), signal = new AbortController().signal;
    try {
      await f.memory.configure(owner, workspaceId, true);
      const note = await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Canonical evidence" });
      await f.ready();
      const documentId = encodeId("sharedMemory", note.id);
      const alias = variant === "wrong-kind" ? encodeId("meeting", note.id) : variant === "wrong-source"
        ? encodeId("sharedMemory", uuidV7()) : variant === "raw-uuid" ? note.id : "smem_invalid";
      f.db.prepare("INSERT INTO memory_documents (workspace_id, document_id, source, content_hash, ingestion_fingerprint, generation) SELECT workspace_id, ?, source, content_hash, ingestion_fingerprint, generation FROM memory_documents WHERE workspace_id = ? AND document_id = ?")
        .run(alias, workspaceId, documentId);
      f.setRecall(() => ({ results: [{ id: "fact", document_id: alias, text: "Untrusted" }] }));
      f.facts.set("fact", { state: "valid", document_id: alias });
      f.setReflection(() => ({ structured_output: { claims: [{ text: "Do not publish", factIds: ["fact"] }] }, based_on: { memories: [{ id: "fact", text: "Untrusted" }] } }));
      expect(await f.memory.search(owner, workspaceId, "evidence", true, signal)).toMatchObject({ sources: [], hypothesis: null, claims: [] });
      expect(await f.memory.canonicalSource(owner, workspaceId, documentId, signal)).toMatchObject({ id: documentId, source: { id: note.id } });
    } finally { await f.close(); }
  });

  it("does not send or retry a source job whose document TypeID names another source", async () => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      await f.ready();
      const note = await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Canonical evidence" });
      f.db.prepare("UPDATE memory_source_jobs SET document_id = ? WHERE workspace_id = ? AND source_id = ?")
        .run(encodeId("meeting", note.id), workspaceId, note.id);
      const before = f.requests.length;
      await f.tick();
      expect((await f.app.memory!.status(owner.userId, workspaceId))?.errorCode).toBe("memory_document_mismatch");
      expect(f.requests.slice(before).every((request) => request.method === "GET" && request.path.endsWith("/config"))).toBe(true);
      expect(f.retained.size).toBe(0);
    } finally { await f.close(); }
  });

  it("defaults images off, restricts enabling to admins, and preserves omitted image settings", async () => {
    const f = await setup(true);
    try {
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ imagesEnabled: false });
      await expect(f.memory.configure(viewer, workspaceId, true, true)).rejects.toMatchObject({ status: 404 });
      f.transport.mockResolvedValueOnce(new Response(null, { status: 404 }));
      await f.memory.configure(owner, workspaceId, true, true);
      expect(f.requests.some((request) => request.path.endsWith("/config") && request.method === "PATCH")).toBe(true);
      const enabled = await f.app.memory!.status(owner.userId, workspaceId);
      expect(enabled!.imagesEnabled).toBe(true);
      await f.memory.configure(owner, workspaceId, false);
      const paused = await f.app.memory!.status(owner.userId, workspaceId);
      expect(paused!.imagesEnabled).toBe(true);
      expect(paused!.generation).toBeGreaterThan(enabled!.generation);
      await f.memory.configure(owner, workspaceId, false, false);
      expect((await f.app.memory!.status(owner.userId, workspaceId))!.imagesEnabled).toBe(false);
    } finally { await f.close(); }
    const off = await setup();
    try { await expect(off.memory.configure(owner, workspaceId, true, true)).rejects.toMatchObject({ code: "memory_images_unconfigured" }); }
    finally { await off.close(); }
  });

  it("withdraws ready image results and reports an incompatible live VLM configuration", async () => {
    const f = await setup(true);
    try {
      await f.memory.configure(owner, workspaceId, true, true); await f.ready();
      const original = f.transport.getMockImplementation()!;
      f.transport.mockImplementation(async (url, init) => String(url).endsWith("/config") && init?.method === "GET"
        ? Response.json({ bank_id: `dahlia_${encodeId("workspace", workspaceId)}`, dahlia_ingestion_policy: "a".repeat(64), dahlia_images: { enabled: false } })
        : original(url, init));
      await f.tick();
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "error", errorCode: "memory_images_unconfigured" });
      await expect(f.memory.search(owner, workspaceId, "synthetic", false, new AbortController().signal)).rejects.toMatchObject({ code: "memory_images_unconfigured" });
    } finally { await f.close(); }
  });

  it.each(["checksum", "stream"])("recovers %s failures and publishes only completed current image manifests", async (failure) => {
    const f = await setup(true);
    try {
      const { meetingId, hash, shot } = await screenshotFixture(f);
      await f.memory.configure(owner, workspaceId, true, true); await f.ready();
      const documentId = encodeId("meeting", meetingId), stored = await f.app.memory!.document(workspaceId, documentId);
      expect(stored!.source.images!.entries).toHaveLength(1);
      expect(f.retained.get(documentId)).not.toContain("OCR-MARKER");
      expect(f.retained.get(documentId)).not.toContain("CAPTION-MARKER");
      const fact = { id: "image-fact", state: "valid", text: "Generated image claim", document_id: documentId,
        attachments: f.attachments.get(documentId), metadata: { ...f.metadata.get(documentId), dahlia_image_context: [hash.slice(0, 12)] } };
      f.facts.set(fact.id, fact); f.setRecall(() => ({ results: [fact] }));
      const result = await f.memory.search(owner, workspaceId, "diagram", false, new AbortController().signal);
      expect(result.sources[0]!.images).toHaveLength(1);
      expect(result.sources[0]!.canonicalExcerpt).toContain("OCR-MARKER");
      f.facts.set(fact.id, { ...fact, attachments: [] });
      expect((await f.memory.search(owner, workspaceId, "diagram", false, new AbortController().signal)).sources).toEqual([]);
      const readFileContent = f.sync.readFileContent.bind(f.sync);
      if (failure === "checksum") shot.contentHash = "0".repeat(64);
      else {
        shot.caption = "Updated canonical caption"; // A changed source requires image materialization again.
        f.sync.readFileContent = vi.fn().mockImplementation(async () => ({ upstream: new Response(new ReadableStream({
          pull(controller) { controller.error(new Error("SYNTHETIC_PRIVATE_STREAM_FAILURE")); },
        })) }));
      }
      await f.app.memory!.enqueue(workspaceId, "meeting", meetingId);
      await f.tick();
      expect(await f.memory.canonicalSource(owner, workspaceId, documentId, new AbortController().signal)).toBeNull();
      await f.ready();
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "partial",
        skippedSources: [{ source: documentId, code: failure === "checksum" ? "memory_image_changed" : "memory_image_unavailable" }] });
      expect(await f.app.memory!.document(workspaceId, documentId)).toBeUndefined();
      expect(f.retained.has(documentId)).toBe(false);
      shot.contentHash = hash;
      f.sync.readFileContent = readFileContent;
      await f.app.memory!.enqueue(workspaceId, "meeting", meetingId); await f.ready();
      expect((await f.app.memory!.document(workspaceId, documentId))!.source.images!.entries).toHaveLength(1);
      await f.memory.configure(owner, workspaceId, true, false);
      expect(await f.memory.canonicalSource(owner, workspaceId, documentId, new AbortController().signal)).toBeNull();
      await f.ready();
      expect((await f.app.memory!.document(workspaceId, documentId))!.source.images).toBeUndefined();
      expect(f.retained.get(documentId)).toContain("OCR-MARKER");
    } finally { await f.close(); }
  });

  it("reingests an image-only screenshot after its canonical capture time changes", async () => {
    const f = await setup(true);
    try {
      const { meetingId, shot } = await screenshotFixture(f);
      shot.ocrText = ""; shot.caption = "";
      await f.memory.configure(owner, workspaceId, true, true); await f.ready();
      const id = encodeId("meeting", meetingId), before = (await f.app.memory!.document(workspaceId, id))!;
      const text = f.retained.get(id), retains = f.requests.filter((request) => request.path.endsWith("/memories")).length;
      shot.capturedAt = new Date(shot.capturedAt.getTime() + 60_000);
      await f.app.memory!.enqueue(workspaceId, "meeting", meetingId);
      expect(await f.memory.canonicalSource(owner, workspaceId, id, new AbortController().signal)).toBeNull();
      await f.ready();
      const after = (await f.app.memory!.document(workspaceId, id))!;
      expect(after.contentHash).toBe(before.contentHash);
      expect(after.source.revision).toBe(before.source.revision);
      expect(after.ingestionFingerprint).not.toBe(before.ingestionFingerprint);
      expect(f.requests.filter((request) => request.path.endsWith("/memories"))).toHaveLength(retains + 1);
      expect(f.retained.get(id)).not.toBe(text);
      expect(f.retained.get(id)).toContain(shot.capturedAt.toISOString());
      expect((await f.memory.canonicalSource(owner, workspaceId, id, new AbortController().signal))?.source).toEqual(after.source);
    } finally { await f.close(); }
  });

  it.each([{ cancel: false, images: false }, { cancel: true, images: false }, { cancel: false, images: true }, { cancel: true, images: true }])("compares isolated image/text recipes without production writes (%o)", async ({ cancel, images }) => {
    const f = await setup(images);
    const controller = new AbortController();
    try {
      const scene = images ? await screenshotFixture(f) : undefined;
      await f.memory.configure(owner, workspaceId, true, images);
      const notes = [];
      for (let i = 0; i < 7; i++) notes.push(await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: `Synthetic evidence ${i}` }));
      await f.ready();
      // Failed extraction has no successful ledger; pending production ingestion must not limit the evaluation corpus either.
      await f.app.memory!.forgetDocument(workspaceId, encodeId("sharedMemory", notes[6]!.id));
      notes.push(await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Synthetic evidence 7" }));
      type Attachment = { id: string; hash: string; kind: string; media_type: string; byte_size: number };
      const before = await f.app.memory!.documents(workspaceId), banks = new Map<string, Map<string, { content: string; metadata: Record<string, unknown>; attachments: Attachment[] }>>();
      const modes = new Map<string, string>(), deleted: string[] = [];
      const capabilities = images ? { enabled: true, provider: "databricks", model: "system.ai.gpt-6-luna", max_count: 8, max_bytes: 8388608,
        max_per_chunk: 1, max_completion_tokens: 16000, timeout: 120, retries: 0 } : null;
      const transport: typeof fetch = async (url, init) => {
        const parsed = new URL(String(url)), bank = parsed.pathname.split("/banks/")[1]!.split("/")[0]!, path = parsed.pathname;
        expect(path).not.toMatch(/\/(clone|webhooks|directives)$/);
        if (!bank.startsWith("dahlia_eval_")) {
          expect(init?.method).toBe("GET");
          return path.endsWith("/config")
            ? Response.json({ bank_id: bank, dahlia_ingestion_policy: "a".repeat(64), config: { retain_extraction_mode: "concise" }, dahlia_images: capabilities })
            : f.transport(url, init);
        }
        if (path.includes("/operations/")) return Response.json({ status: "completed" });
        if (path.endsWith("/config") && init?.method === "GET" && !banks.has(bank)) return new Response(null, { status: 404 });
        if (path.endsWith("/config") && init?.method === "PATCH" && !banks.has(bank)) banks.set(bank, new Map());
        const docs = banks.get(bank)!, body = (init?.body ? JSON.parse(String(init.body)) : {}) as { updates: { retain_extraction_mode: string }; operation_id: string; items: Array<{ document_id: string; content: string | import("../src/memory/images").ImageContentBlock[]; metadata: Record<string, string> }> };
        const policy = (modes.get(bank) === "verbose" ? "c" : "b").repeat(64);
        if (path.endsWith("/config")) {
          if (init?.method === "PATCH") modes.set(bank, body.updates.retain_extraction_mode);
          return Response.json({ bank_id: bank, dahlia_ingestion_policy: policy, dahlia_images: capabilities });
        }
        if (path.endsWith("/operations")) return Response.json({ total: 0 });
        if (path.endsWith("/memories")) {
          const item = body.items[0]!, attachments: Attachment[] = [];
          let content = "", afterImage = false;
          for (const block of typeof item.content === "string" ? [{ type: "text" as const, text: item.content }] : item.content) {
            if (block.type === "text") { if (afterImage) content = `${content.replace(/\n+$/u, "")}\n\n`; content += block.text; afterImage = false; }
            else {
              const bytes = atob(block.source.data), hash = await contentHash(bytes);
              if (content) content = `${content.replace(/\n+$/u, "")}\n\n`;
              content += `⟦hs-att:${hash.slice(0, 12)}⟧`; afterImage = true;
              attachments.push({ id: hash.slice(0, 12), hash, kind: "image", media_type: "image/webp", byte_size: bytes.length });
            }
          }
          docs.set(item.document_id, { content, attachments, metadata: { ...item.metadata, dahlia_ingestion_policy: policy,
            ...(item.metadata.dahlia_images ? { dahlia_image_context: attachments.map((item) => item.id) } : {}) } });
          if (cancel && (!images || Array.isArray(item.content))) controller.abort();
          return Response.json({ operation_id: body.operation_id });
        }
        if (path.includes("/documents/")) {
          const id = path.split("/").at(-1)!, doc = docs.get(id)!;
          return Response.json({ id, bank_id: bank, original_text: doc.content, attachments: doc.attachments, memory_unit_count: 1, retain_params: { metadata: doc.metadata } });
        }
        if (path.endsWith("/memories/recall")) return Response.json({ results: [...docs.keys()].flatMap((id) => [{ id, document_id: id, text: "Synthetic" }, { id, document_id: id, text: "Duplicate" }]) });
        if (path.endsWith("/reflect")) return Response.json({ text: "Never publish this raw text", structured_output: { claims: [{ text: "Synthetic hypothesis", factIds: [[...docs.keys()][0]] }] }, based_on: { memories: [{ id: [...docs.keys()][0], text: "Synthetic" }], mental_models: [] } });
        if (path.includes("/memories/")) {
          const id = path.split("/").at(-1)!, doc = docs.get(id)!;
          return Response.json({ document_id: id, state: "valid", attachments: doc.attachments, metadata: doc.metadata });
        }
        if (init?.method === "DELETE") { deleted.push(bank); banks.delete(bank); return Response.json({}); }
        throw new Error("Unexpected evaluation request");
      };
      const evaluated = compareMemoryIngestion({ config: f.config, store: f.app.memory!, sync: f.sync, syncStore: f.app.sync,
        identity: owner, scopeId: workspaceId, transport, signal: controller.signal, reflect: true, strategies: ["synthetic-standard"],
        questions: [{ query: "PRIVATE SYNTHETIC QUERY", expected: [{ id: encodeId("sharedMemory", notes[0]!.id), excerpts: ["Synthetic evidence 0"] },
          ...(scene ? [{ id: encodeId("meeting", scene.meetingId), excerpts: [], screenshotIds: [encodeId("attachment", scene.shot.screenshotId)] }] : [])],
          requiredClaims: ["Synthetic hypothesis"], forbiddenClaims: ["Never publish this raw text"] }] });
      if (cancel) await expect(evaluated).rejects.toMatchObject({ name: "AbortError" });
      else {
        const result = await evaluated;
        expect(result.variants).toHaveLength(images ? 6 : 3);
        expect(result.documents).toBe(images ? 9 : 8);
        expect(result.variants.every((v) => v.errors === 0 && v.hitAt5 === 1 && v.claimExpectations.found === 1 && v.claimExpectations.forbidden === 0)).toBe(true);
        if (images) expect(result.variants.map((v) => v.imageReferenceRecall)).toEqual([0, 1, 0, 1, 0, 1]);
        expect(JSON.stringify(result)).not.toMatch(/PRIVATE|Synthetic evidence|synthetic-standard|Never publish/);
      }
      expect(await f.app.memory!.documents(workspaceId)).toEqual(before);
      expect(deleted).toHaveLength(cancel ? images ? 2 : 1 : images ? 6 : 3); expect(banks.size).toBe(0);
      expect(new Set(deleted).size).toBe(deleted.length);
      expect(deleted.every((bank) => /^dahlia_eval_[0-9a-f-]{36}$/.test(bank) && bank !== f.memory.client.bank(workspaceId))).toBe(true);
    } finally { await f.close(); }
  });

  it("reprocesses unchanged canonical content when settings change and skips unchanged recipes", async () => {
    const f = await setup(), signal = new AbortController().signal;
    try {
      await f.memory.configure(owner, workspaceId, true);
      const note = await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Canonical unchanged" });
      await f.ready();
      const id = encodeId("sharedMemory", note.id), before = (await f.app.memory!.document(workspaceId, id))!;
      const retained = f.requests.filter((r) => r.path.endsWith("/memories")).length;
      await f.memory.configure(owner, workspaceId, true); await f.ready();
      expect(f.requests.filter((r) => r.path.endsWith("/memories"))).toHaveLength(retained);
      f.setPolicy("b".repeat(64));
      expect(await f.memory.search(owner, workspaceId, "query", true, signal)).toMatchObject({ sources: [], hypothesis: null, coverage: "updating" });
      await f.ready();
      const after = (await f.app.memory!.document(workspaceId, id))!;
      expect(after.contentHash).toBe(before.contentHash);
      expect(after.ingestionFingerprint).not.toBe(before.ingestionFingerprint);
      expect(f.requests.filter((r) => r.path.endsWith("/reprocess"))).toHaveLength(1);
      expect((await f.memory.search(owner, workspaceId, "query", false, signal)).sources).toHaveLength(1);
    } finally { await f.close(); }
  });
  it.each([false, true])("recovers a lost reprocess acknowledgement after restart (upstream document lost: %s)", async (lost) => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Same content" });
      await f.ready(); f.setPolicy("b".repeat(64));
      for (let i = 0; i < 30; i++) {
        await f.tick();
        if ((await f.app.memory!.pending(workspaceId))?.operation?.stage === "retain") break;
      }
      f.loseNextAcknowledgement(); await f.tick();
      const pending = (await f.app.memory!.pending(workspaceId))!;
      expect(pending.operation?.stage).toBe("reprocess");
      expect((await f.memory.status(owner, workspaceId)).status).toBe("error");
      if (lost) { f.operations.delete(pending.operation!.id); f.retained.delete(pending.documentId); }
      // A new service instance has no in-memory operation state.
      const restarted = new WorkspaceMemoryService(f.config, f.app.memory!, f.sync, f.app.sync, f.transport);
      f.db.exec("UPDATE jobs_queue SET available_at = 0 WHERE kind = 'workspace-memory'");
      await restarted.step(workspaceId, new AbortController().signal);
      await f.ready();
      expect(f.requests.filter((r) => r.path.endsWith("/reprocess"))).toHaveLength(lost ? 2 : 1);
      if (lost) {
        const recreated = f.requests.filter((r) => r.path.endsWith("/memories")).at(-1)!;
        expect(recreated.body.operation_id).not.toBe(pending.operation!.id);
        expect(f.retained.has(pending.documentId)).toBe(true);
      }
      expect(await f.app.memory!.pending(workspaceId)).toBeUndefined();
      expect((await f.memory.status(owner, workspaceId)).status).toBe("ready");
    } finally { await f.close(); }
  });
  it("does not adopt an operation started under an older setting or a legacy fingerprint", async () => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      const note = await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Evidence" });
      for (let i = 0; i < 30; i++) { await f.tick(); if ((await f.app.memory!.pending(workspaceId))?.operation) break; }
      f.setPolicy("b".repeat(64)); await f.ready();
      expect(f.requests.filter((r) => r.path.endsWith("/reprocess"))).toHaveLength(1);
      f.db.prepare("UPDATE memory_documents SET ingestion_fingerprint = NULL").run();
      expect((await f.memory.search(owner, workspaceId, "query", false, new AbortController().signal)).sources).toEqual([]);
      await f.memory.configure(owner, workspaceId, true); await f.ready();
      expect((await f.app.memory!.document(workspaceId, encodeId("sharedMemory", note.id)))?.ingestionFingerprint).toMatch(/^[0-9a-f]{64}$/);
      expect(f.requests.filter((r) => r.path.endsWith("/reprocess"))).toHaveLength(2);
    } finally { await f.close(); }
  });
  it.each(["memory_policy_blocked", "memory_output_too_long", "memory_no_facts", "memory_document_mismatch"])("reports %s as partial and retries only after a rescan", async (code) => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      const note = await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Canonical source is preserved" });
      const id = encodeId("sharedMemory", note.id);
      if (code === "memory_no_facts") f.counts.set(id, 0);
      const readDocument = f.memory.client.document.bind(f.memory.client);
      const missingText = code === "memory_document_mismatch" ? vi.spyOn(f.memory.client, "document").mockImplementation(async (...args) => {
        const stored = await readDocument(...args);
        return stored ? { ...stored, original_text: null } : stored;
      }) : undefined;
      for (let i = 0; i < 30; i++) { await f.tick(); if ((await f.app.memory!.pending(workspaceId))?.operation) break; }
      if (code === "memory_policy_blocked" || code === "memory_output_too_long") {
        const operation = (await f.app.memory!.pending(workspaceId))!.operation!;
        f.operations.set(operation.id, "failed"); f.errorCodes.set(operation.id, code);
      }
      await f.ready();
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "partial", skippedSources: [{ source: id, code }] });
      const result = await f.memory.search(owner, workspaceId, "query", false, new AbortController().signal);
      expect(result).toMatchObject({ sources: [], coverage: "partial", skippedSources: [{ source: id, code }] });
      expect((await f.app.memory!.getNote(owner.userId, workspaceId, note.id))?.content).toBe("Canonical source is preserved");
      expect(f.requests.some((r) => r.path.endsWith("/retry"))).toBe(false);
      const count = f.requests.filter((r) => r.path.endsWith("/memories")).length; await f.tick();
      expect(f.requests.filter((r) => r.path.endsWith("/memories"))).toHaveLength(count);
      missingText?.mockRestore(); f.counts.clear(); await f.memory.configure(owner, workspaceId, true); await f.ready();
      expect((await f.memory.status(owner, workspaceId)).status).toBe("ready");
    } finally { await f.close(); }
  });
  it("checks the setting after external recall and never publishes old results", async () => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Evidence" }); await f.ready();
      f.setRecall(() => { f.setPolicy("b".repeat(64)); return { results: [...f.retained.keys()].map((id) => ({ id, document_id: id, text: "Synthetic" })) }; });
      expect(await f.memory.search(owner, workspaceId, "query", false, new AbortController().signal)).toMatchObject({ sources: [], coverage: "updating" });
    } finally { await f.close(); }
  });

  it("enforces the browser API contract, TypeIDs, explicit sharing and current permissions", async () => {
    const f = await setup();
    try {
      const app = createApp({ config: f.config, authStore: f.app, syncService: f.sync, workspaceMemory: f.memory });
      const path = `/api/v1/workspaces/${encodeId("workspace", workspaceId)}/memory`;
      const request = (url: string, method = "GET", body?: unknown, identity = owner) => app.request(url, { method,
        headers: { "x-forwarded-email": `${identity.userId}@example.com`, "content-type": "application/json", "x-dahlia-workspace-transfers": "1" },
        body: body ? JSON.stringify(body) : undefined });
      expect((await request(`${path}/analysis/settings`, "PATCH", { enabled: true }, viewer)).status).toBe(404);
      expect((await request(`${path}/analysis/settings`, "PATCH", { enabled: true })).status).toBe(200);
      expect((await request(`${path}/notes`, "POST", { id: encodeId("sharedMemory", crypto.randomUUID()),
        content: "Invalid entity ID", revision: 0, explicit: true })).status).toBe(400);
      const id = encodeId("sharedMemory", uuidV7());
      expect((await request(`${path}/notes`, "POST", { id, content: "User-confirmed claim", revision: 0 })).status).toBe(400);
      const saved = await request(`${path}/notes`, "POST", { id, content: "User-confirmed claim", revision: 0, explicit: true });
      expect(saved.status).toBe(200); expect(await saved.json()).toMatchObject({ memory: { id, revision: 1 } });
      expect(await (await request(`${path}/notes`)).json()).toMatchObject({ items: [{ id }] });
      expect((await request(`${path}/notes/${id}?revision=1&explicit=true`, "DELETE", undefined, viewer)).status).toBe(404);
      expect((await request(`${path}/notes/${id}?revision=1&explicit=true`, "DELETE")).status).toBe(200);
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
      expect(f.retained.get(encodeId("sharedMemory", note.id))).toContain(input.content);
      await f.app.memory!.purge(owner.userId, workspaceId);
      await expect(f.app.memory!.saveNote(owner.userId, workspaceId, { ...input, revision: 2 })).rejects.toMatchObject({ status: 409 });
    } finally { await f.close(); }
  });

  it("skips an oversized meeting, retains later sources, and recovers on retry", async () => {
    const f = await setup();
    try {
      const bad = uuidV7(), good = uuidV7();
      await f.commit([bad, good].map((id, i) => ({ entity: "meeting", action: "create", entityId: id, baseRevision: null,
        data: { projectId: null, name: i ? "Healthy meeting" : "Oversize", description: "Evidence", duration: 60, recordingStartedAt: `2026-09-${22 - i}T00:00:00Z`, createdAt: `2026-09-${22 - i}T00:00:00Z`, updatedAt: new Date().toISOString(), status: "READY" } })));
      const original = f.sync.listTranscript.bind(f.sync);
      const transcript = vi.spyOn(f.sync, "listTranscript").mockImplementation((identity, workspace, meeting, ...rest) => {
        if (meeting === bad) return Promise.resolve({ items: [{ segmentId: uuidV7(), startedAt: new Date(), text: "x".repeat(4 * 1024 * 1024 + 1) }] } as never);
        return original(identity, workspace, meeting, ...rest);
      });
      await f.memory.configure(owner, workspaceId, true);
      await f.ready();
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "partial", skippedCount: 1,
        skippedSources: [{ source: encodeId("meeting", bad), code: "memory_source_too_large" }] });
      expect(f.retained.has(encodeId("meeting", good))).toBe(true);
      expect((await f.memory.search(owner, workspaceId, "evidence", false, new AbortController().signal)).skippedCount).toBe(1);
      transcript.mockRestore();
      await f.memory.configure(owner, workspaceId, true); await f.ready();
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "ready", skippedCount: 0 });
      expect(f.retained.has(encodeId("meeting", bad))).toBe(true);
    } finally { await f.close(); }
  });

  it("bounds failed document/model retries across pending polls and removes failed projections before partial readiness", async () => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      const bad = uuidV7(), good = uuidV7();
      for (const id of [bad, good]) await f.app.memory!.saveNote(owner.userId, workspaceId, { id, revision: 0, content: `Note ${id}` });
      f.failingItems.add(encodeId("sharedMemory", bad)); f.failingItems.add("workspace-insights");
      const remove = vi.spyOn(f.memory.client, "deleteDocument");
      remove.mockRejectedValueOnce(new HindsightError("memory_unavailable"));
      for (let i = 0; i < 80 && !remove.mock.calls.length; i++) await f.tick();
      expect(remove).toHaveBeenCalled();
      const partial = await f.memory.search(owner, workspaceId, "note", false, new AbortController().signal);
      expect(partial.coverage).toBe("updating");
      expect(partial.sources.every((source) => source.id !== bad)).toBe(true);
      await f.ready();
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "partial", skippedCount: 2 });
      expect(f.requests.filter((r) => r.path.endsWith("/retry"))).toHaveLength(6);
      expect(f.retained.has(encodeId("sharedMemory", bad))).toBe(false);
      expect(f.retained.has(encodeId("sharedMemory", good))).toBe(true);
      expect(await f.app.memory!.document(workspaceId, encodeId("sharedMemory", bad))).toBeUndefined();
      expect((await f.memory.search(owner, workspaceId, "note", false, new AbortController().signal)).sources).toHaveLength(1);
      f.failingItems.clear();
      await f.memory.configure(owner, workspaceId, true); await f.ready();
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "ready", skippedCount: 0 });
      expect(f.retained.has(encodeId("sharedMemory", bad))).toBe(true);
    } finally { await f.close(); }
  });

  it.each(["retry", "resume"])("recreates failed models on %s without retaining unchanged documents", async (action) => {
    const f = await setup();
    try {
      const projectId = uuidV7(), meetingId = uuidV7(), now = new Date().toISOString();
      await f.commit([{ entity: "project", action: "create", entityId: projectId, baseRevision: null,
        data: { name: "Project", parentProjectId: null, projectType: null, createdAt: now } },
      { entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
        data: { projectId, name: "Meeting", description: "Evidence", status: "READY", duration: 60,
          recordingStartedAt: now, createdAt: now, updatedAt: now } }]);
      f.failingItems.add("workspace-insights"); f.failingItems.add(`project-${projectId}`);
      await f.memory.configure(owner, workspaceId, true); await f.ready();
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "partial", skippedCount: 2 });
      expect(f.models.size).toBe(0);
      const before = f.requests.length;
      f.failingItems.clear();
      if (action === "resume") await f.memory.configure(owner, workspaceId, false);
      await f.memory.configure(owner, workspaceId, true); await f.ready();
      expect(f.models.has("workspace-insights")).toBe(true);
      expect(f.models.has(`project-${projectId}`)).toBe(true);
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "ready", skippedCount: 0 });
      expect(f.requests.slice(before).filter((r) => r.path.endsWith("/memories") && r.method === "POST")).toEqual([]);
    } finally { await f.close(); }
  });
  it("clears every recovered failure beyond the diagnostic limit", async () => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      const ids = Array.from({ length: 21 }, () => uuidV7());
      for (const id of ids) {
        await f.app.memory!.saveNote(owner.userId, workspaceId, { id, revision: 0, content: "Original" });
        f.failingItems.add(encodeId("sharedMemory", id));
      }
      await f.ready(300);
      const partial = await f.memory.status(owner, workspaceId);
      expect(partial.skippedCount).toBe(21); expect(partial.skippedSources).toHaveLength(20);
      f.failingItems.clear();
      for (const id of ids) await f.app.memory!.saveNote(owner.userId, workspaceId, { id, revision: 1, content: "Corrected" });
      await f.ready();
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "ready", skippedCount: 0, skippedSources: [] });
      expect(f.retained.size).toBe(21);
    } finally { await f.close(); }
  }, 15_000);
  it("clears failed coverage when its canonical note is deleted", async () => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      const id = uuidV7();
      await f.app.memory!.saveNote(owner.userId, workspaceId, { id, revision: 0, content: "Failed" });
      f.failingItems.add(encodeId("sharedMemory", id));
      await f.ready();
      expect((await f.memory.status(owner, workspaceId)).skippedCount).toBe(1);
      await f.app.memory!.deleteNote(owner.userId, workspaceId, id, 1); await f.ready();
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "ready", skippedCount: 0, skippedSources: [] });
      expect((await f.memory.search(owner, workspaceId, "query", false, new AbortController().signal)).coverage).toBe("ready");
    } finally { await f.close(); }
  });

  it.each(["delete", "ineligible"])("clears oversized meeting failure after %s", async (action) => {
    const f = await setup();
    try {
      const id = uuidV7(), now = new Date().toISOString();
      const data = { projectId: null, name: "Meeting", description: "Evidence", status: "READY", duration: 60, recordingStartedAt: now, updatedAt: now };
      await f.commit([{ entity: "meeting", action: "create", entityId: id, baseRevision: null, data: { ...data, createdAt: now } }]);
      vi.spyOn(f.sync, "listTranscript").mockResolvedValue({ items: [{ segmentId: uuidV7(), startedAt: new Date(), text: "x".repeat(4 * 1024 * 1024 + 1) }] } as never);
      await f.memory.configure(owner, workspaceId, true); await f.ready();
      expect((await f.memory.status(owner, workspaceId)).skippedCount).toBe(1);
      const revision = (await f.sync.getMeeting(owner, workspaceId, id))!.revision!;
      await f.commit([{ entity: "meeting", action: action === "delete" ? "delete" : "update", entityId: id, baseRevision: revision,
        data: action === "delete" ? {} : { ...data, status: "PROCESSING_TRANSCRIPT" } }]);
      expect(await f.app.memory!.pending(workspaceId, encodeId("meeting", id))).toBeDefined();
      await f.ready();
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "ready", skippedCount: 0 });
    } finally { await f.close(); }
  });
  it.each(["edit", "delete", "unrelated", "continuous"])("fences final source validation during %s", async (action) => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      const ids = [uuidV7(), uuidV7(), uuidV7()];
      for (const id of ids) await f.app.memory!.saveNote(owner.userId, workspaceId, { id, revision: 0, content: `Original ${id}` });
      await f.ready();
      const [a, b, c] = [...f.retained.keys()].map((id) => decodeId("sharedMemory", id));
      const getNote = f.app.memory!.getNote.bind(f.app.memory!);
      let reads = 0, revision = 1;
      vi.spyOn(f.app.memory!, "getNote").mockImplementation(async (user, workspace, id) => {
        if (id === a && ++reads >= 2 && (reads === 2 || action === "continuous")) {
          if (action === "delete") await f.app.memory!.deleteNote(owner.userId, workspaceId, b!, 1);
          else await f.app.memory!.saveNote(owner.userId, workspaceId, { id: action === "edit" ? b! : c!, revision: revision++, content: `Changed ${revision}` });
        }
        return getNote(user, workspace, id);
      });
      const result = f.memory.search(owner, workspaceId, "query", false, new AbortController().signal);
      if (action === "continuous") await expect(result).rejects.toThrow("memory_source_changed");
      else {
        const found = (await result).sources.map((source) => source.id);
        expect(found).toContain(a);
        if (action === "unrelated") expect(found).toContain(b);
        else expect(found).not.toContain(b);
      }
      expect(reads).toBeLessThanOrEqual(4);
    } finally { await f.close(); }
  });

  it.each(["retain", "delete"])("persists recovered coverage before completing a %s job", async (action) => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      const id = uuidV7();
      await f.app.memory!.saveNote(owner.userId, workspaceId, { id, revision: 0, content: "Original" });
      f.failingItems.add(encodeId("sharedMemory", id));
      await f.ready();
      expect((await f.memory.status(owner, workspaceId)).skippedCount).toBe(1);
      f.failingItems.clear();
      if (action === "retain") await f.app.memory!.saveNote(owner.userId, workspaceId, { id, revision: 1, content: "Recovered" });
      else await f.app.memory!.deleteNote(owner.userId, workspaceId, id, 1);
      const finish = f.app.memory!.finishSource.bind(f.app.memory!);
      const interrupted = vi.spyOn(f.app.memory!, "finishSource").mockImplementationOnce(async (job) => {
        await finish(job);
        throw new Error("Worker stopped after durable job completion");
      });
      await f.tick();
      if (action === "retain") await f.tick();
      expect(interrupted).toHaveBeenCalledTimes(1);
      expect(await f.app.memory!.pending(workspaceId, encodeId("sharedMemory", id))).toBeUndefined();
      await f.ready();
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "ready", skippedCount: 0, skippedSources: [] });
    } finally { await f.close(); }
  });

  it("preserves paginated transcript and screenshot provenance and excludes active meetings", async () => {
    const now = new Date();
    const sync = { getMeeting: vi.fn().mockResolvedValue({ meetingId: workspaceId, name: "Customer", description: "", status: "READY", createdAt: now,
      projectId: workspaceId, summaryDocument: "Summary interpretation" }), getProject: vi.fn().mockResolvedValue({ projectId: workspaceId, name: "Customer project", description: "Context" }),
    listTranscript: vi.fn().mockResolvedValueOnce({ items: [{ segmentId: "one", startedAt: now, speakerLabel: "Speaker A", audioSource: "microphone", text: "Actual statement" }], nextCursor: "next" })
      .mockResolvedValueOnce({ items: [{ segmentId: "two", startedAt: now, text: "Counterexample" }] }),
    listScreenshots: vi.fn().mockResolvedValue({ items: [{ screenshotId: "shot", fileId: "file", capturedAt: now, ocrText: "Screen evidence\n\nSecond paragraph\n\nThird paragraph", caption: "Image interpretation" }] }) };
    const document = await meetingDocument(sync as unknown as MeetingSyncService, owner, workspaceId, workspaceId, new AbortController().signal);
    for (const text of ["Actual statement", "Counterexample", "Speaker A", "Screen evidence", "AI caption (interpretation)", "not independent corroboration", "Customer project"]) expect(document!.content).toContain(text);
    const screenshot = document!.blocks!.find((block) => block.marker === "Screenshot shot")!;
    expect(document!.content.slice(screenshot.start, screenshot.end)).toContain("Screen evidence\n\nSecond paragraph\n\nThird paragraph");
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
      await f.tick();
      expect(await f.memory.search(owner, workspaceId, "budget", false, new AbortController().signal)).toMatchObject({ coverage: "updating", sources: [] });
      f.loseNextAcknowledgement(); await f.ready();
      expect(f.requests.filter((r) => r.path.endsWith("/memories") && r.method === "POST")).toHaveLength(1);
      const result = await f.memory.search(viewer, workspaceId, "budget", false, new AbortController().signal);
      expect(result.sources[0]?.canonicalExcerpt).toContain(input.content);
      expect(JSON.stringify(result)).not.toContain("UNTRUSTED EXTRACTED CLAIM");
      const before = f.requests.length; await f.tick(); expect(f.requests.slice(before).map((r) => r.method)).toEqual(["GET", "GET"]); expect(f.requests.at(-1)!.path).toContain("/mental-models/");
      await f.app.memory!.deleteNote(owner.userId, workspaceId, input.id, 1);
      expect(await f.memory.search(owner, workspaceId, "budget", false, new AbortController().signal)).toMatchObject({ coverage: "updating", sources: [] });
      await f.ready(); expect(f.retained.size).toBe(0);
      expect((await f.memory.search(owner, workspaceId, "budget", false, new AbortController().signal)).sources).toEqual([]);
    } finally { await f.close(); }
  });
  it("applies the entity policy to existing ready banks before allowing reads", async () => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Existing evidence" });
      await f.ready();
      f.db.exec("UPDATE workspace_memory_state SET progress = json_remove(progress, '$.entityPolicy')");
      await expect(f.memory.search(owner, workspaceId, "evidence", false, new AbortController().signal)).rejects.toThrow("memory_not_ready");
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "indexing" });
      const initialize = vi.spyOn(f.memory.client, "initialize").mockRejectedValueOnce(new HindsightError("memory_unavailable"));
      await f.tick();
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "error", errorCode: "memory_unavailable", attempts: 1 });
      await expect(f.memory.search(owner, workspaceId, "evidence", false, new AbortController().signal)).rejects.toThrow("memory_not_ready");
      await f.tick();
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "ready", errorCode: null, attempts: 0 });
      await f.tick();
      expect(await f.memory.status(owner, workspaceId)).toMatchObject({ status: "ready", errorCode: null, attempts: 0 });
      expect(initialize).toHaveBeenCalledTimes(2);
      expect(f.requests.filter((r) => r.path.endsWith("/config") && r.method === "PATCH").at(-1)!.body).toMatchObject({ updates: {
        entities_allow_free_form: false, entity_labels: [], enable_graph_retrieval: false,
        reflect_default_options: { reflect_search_observations_include_entities: false },
      } });
      expect((await f.memory.search(owner, workspaceId, "evidence", false, new AbortController().signal)).sources).toHaveLength(1);
    } finally { await f.close(); }
  });
  it("backfills saved meetings and invalidates immediately on canonical correction and permission revocation", async () => {
    const f = await setup();
    try {
      const meetingId = uuidV7(); const now = new Date().toISOString();
      const data = { projectId: null, name: "Customer meeting", description: "Original constraint", status: "READY", duration: 60, recordingStartedAt: now, createdAt: now, updatedAt: now };
      await f.commit([{ entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data }]);
      await f.memory.configure(owner, workspaceId, true); await f.ready();
      expect(f.retained.get(encodeId("meeting", meetingId))).toContain("Original constraint");
      const meeting = await f.sync.getMeeting(owner, workspaceId, meetingId);
      const { createdAt: _createdAt, ...updated } = data;
      expect(_createdAt).toBe(now);
      await f.commit([{ entity: "meeting", action: "update", entityId: meetingId, baseRevision: meeting!.revision!, data: { ...updated, description: "Corrected constraint" } }]);
      expect(await f.memory.search(owner, workspaceId, "constraint", false, new AbortController().signal)).toMatchObject({ coverage: "updating", sources: [] });
      await f.ready(); expect(f.retained.get(encodeId("meeting", meetingId))).toContain("Corrected constraint");
      expect([...f.retained.keys()]).toEqual([encodeId("meeting", meetingId)]);
      expect(f.metadata.get(encodeId("meeting", meetingId))).toMatchObject({ source_kind: "meeting", source_id: meetingId });
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
  it("keeps unaffected sources searchable during edits, suppresses reflection, and retains only the changed document", async () => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      const a = await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Original A" });
      const b = await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Stable B" });
      await f.ready();
      const before = f.requests.length;
      const reflection = vi.spyOn(f.memory.client, "reflect");
      await f.app.memory!.saveNote(owner.userId, workspaceId, { id: a.id, revision: 1, content: "New A" });
      const result = await f.memory.search(owner, workspaceId, "evidence", true, new AbortController().signal);
      expect(result).toMatchObject({ coverage: "updating", hypothesis: null, sources: [{ id: b.id }] });
      expect(reflection).not.toHaveBeenCalled();
      await f.ready();
      const writes = f.requests.slice(before).filter((request) => request.path.endsWith("/memories") && request.method === "POST");
      expect(writes).toHaveLength(1);
      expect(writes[0]!.body).toMatchObject({ items: [{ document_id: encodeId("sharedMemory", a.id) }] });
      expect(JSON.stringify(writes[0]!.body)).toContain("New A");
      expect(f.requests.slice(before).filter((request) => request.method === "DELETE" && request.path.includes("mental-models"))).toEqual([]);
      expect((await f.memory.search(owner, workspaceId, "evidence", false, new AbortController().signal)).coverage).toBe("ready");
      const unchangedStart = f.requests.length;
      await f.app.memory!.saveNote(owner.userId, workspaceId, { id: a.id, revision: 2, content: "New A" });
      await f.ready();
      const unchanged = await f.memory.search(owner, workspaceId, "evidence", false, new AbortController().signal);
      expect(unchanged.sources.find((source) => source.id === a.id)?.revision).toBe("3");
      // The Workspace publication contract needs the revised provenance on retained facts, even for unchanged text.
      expect(f.requests.slice(unchangedStart).filter((request) => request.method === "POST" && request.path.endsWith("/memories"))).toHaveLength(1);

    } finally { await f.close(); }
  });
  it("does not rewind backfill while notes are edited and fences older retain completions", async () => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      const note = await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "First" });
      await f.tick();
      const phase = (await f.app.memory!.status(owner.userId, workspaceId))!.progress!.phase;
      await f.app.memory!.saveNote(owner.userId, workspaceId, { id: note.id, revision: 1, content: "Second" });
      await f.tick();
      expect((await f.app.memory!.status(owner.userId, workspaceId))!.progress!.phase).toBe(phase);
      for (let i = 0; i < 10 && !(await f.app.memory!.pending(workspaceId))?.operation; i++) await f.tick();
      const operation = (await f.app.memory!.pending(workspaceId))!.operation!;
      await f.app.memory!.saveNote(owner.userId, workspaceId, { id: note.id, revision: 2, content: "Third" });
      await f.tick();
      expect((await f.app.memory!.pending(workspaceId))!.generation).toBeGreaterThan(operation.generation);
      expect((await f.memory.search(owner, workspaceId, "q", false, new AbortController().signal)).sources).toEqual([]);
      await f.ready();
      expect(f.retained.get(encodeId("sharedMemory", note.id))).toContain("Third");
      expect(await f.app.memory!.pending(workspaceId)).toBeUndefined();
    } finally { await f.close(); }
  });
  it("waits for an in-flight retain before deleting its source or erasing the bank", async () => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      const note = await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Delete during retain" });
      for (let i = 0; i < 10 && !(await f.app.memory!.pending(workspaceId))?.operation; i++) await f.tick();
      const operation = (await f.app.memory!.pending(workspaceId))!.operation!;
      f.operations.set(operation.id, "processing");
      await f.app.memory!.deleteNote(owner.userId, workspaceId, note.id, 1);
      await f.tick();
      expect(f.retained.has(encodeId("sharedMemory", note.id))).toBe(true);
      expect((await f.memory.search(owner, workspaceId, "q", false, new AbortController().signal)).sources).toEqual([]);
      f.operations.set(operation.id, "completed");
      await f.ready();
      expect(f.retained.has(encodeId("sharedMemory", note.id))).toBe(false);
      const next = await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Erase during retain" });
      await f.tick();
      const erasing = (await f.app.memory!.pending(workspaceId))!.operation!;
      f.operations.set(erasing.id, "processing");
      await f.app.memory!.purge(owner.userId, workspaceId);
      await f.tick();
      expect(f.retained.has(encodeId("sharedMemory", next.id))).toBe(true);
      f.operations.set(erasing.id, "completed");
      await f.tick();
      expect(f.retained.size).toBe(0);
      expect(await f.app.memory!.pending(workspaceId)).toBeUndefined();
    } finally { await f.close(); }
  });
  it("ignores live recording sync while serving old meetings, then indexes the completed meeting", async () => {
    const f = await setup();
    try {
      const id = uuidV7(), sessionId = uuidV7(), now = new Date().toISOString();
      await f.commit([{ entity: "meeting", action: "create", entityId: id, baseRevision: null,
        data: { projectId: null, name: "Live", description: "", status: "READY", duration: null, recordingStartedAt: now, createdAt: now, updatedAt: now } },
      { entity: "meeting_event", action: "create", entityId: uuidV7(), baseRevision: null,
        data: { meetingId: id, sessionId, kind: "recording_started", occurredAt: now } }]);
      await f.memory.configure(owner, workspaceId, true);
      await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Past evidence" });
      await f.ready();
      const generation = (await f.app.memory!.status(owner.userId, workspaceId))!.generation;
      for (let i = 0; i < 3; i++) {
        const meeting = await f.sync.getMeeting(owner, workspaceId, id);
        await f.commit([{ entity: "meeting", action: "update", entityId: id, baseRevision: meeting!.revision!,
          data: { projectId: null, name: "Live", description: `update ${i}`, status: "READY", duration: null, recordingStartedAt: now, updatedAt: now } }]);
        expect((await f.app.memory!.status(owner.userId, workspaceId))!.generation).toBe(generation);
        expect((await f.memory.search(owner, workspaceId, "past", false, new AbortController().signal)).sources).toHaveLength(1);
      }
      await f.commit([{ entity: "meeting_event", action: "create", entityId: uuidV7(), baseRevision: null,
        data: { meetingId: id, sessionId, kind: "recording_ended", occurredAt: now } }]);
      await f.ready();
      expect(f.retained.get(encodeId("meeting", id))).toContain("update 2");
    } finally { await f.close(); }
  });
  it("updates only affected Project models and reindexes project context without touching unrelated meetings", async () => {
    const f = await setup();
    try {
      const [a, b, c] = [uuidV7(), uuidV7(), uuidV7()];
      const [moving, stable] = [uuidV7(), uuidV7()];
      const now = new Date().toISOString();
      for (const id of [a, b, c]) await f.commit([{ entity: "project", action: "create", entityId: id, baseRevision: null,
        data: { name: `Project-${id}`, parentProjectId: null, projectType: null, description: "Original project", createdAt: now } }]);
      const data = { name: "Meeting", description: "Evidence", status: "READY", duration: 60, recordingStartedAt: now, createdAt: now, updatedAt: now };
      for (const [id, projectId] of [[moving, a], [stable, c]]) await f.commit([{ entity: "meeting", action: "create", entityId: id!, baseRevision: null, data: { ...data, projectId } }]);
      await f.memory.configure(owner, workspaceId, true); await f.ready();
      const before = f.requests.length;
      const { createdAt: _createdAt, ...updated } = data; expect(_createdAt).toBe(now);
      await f.commit([{ entity: "meeting", action: "update", entityId: moving, baseRevision: (await f.sync.getMeeting(owner, workspaceId, moving))!.revision!, data: { ...updated, projectId: b } }]);
      await f.ready();
      const requests = f.requests.slice(before);
      expect(requests.filter((r) => r.path.endsWith("/memories") && r.method === "POST")).toHaveLength(1);
      expect(requests.filter((r) => r.path.endsWith(`/project-${c}/refresh`))).toHaveLength(0);
      expect(requests.some((r) => r.path.endsWith(`/project-${a}/refresh`))).toBe(true);
      expect(f.models.has(`project-${b}`)).toBe(true);
      const project = await f.sync.getProject(owner, workspaceId, b);
      const beforeRename = f.requests.length;
      await f.commit([{ entity: "project", action: "update", entityId: b, baseRevision: project!.revision,
        data: { name: "Renamed", parentProjectId: null, projectType: null, description: "New project context" } }]);
      await f.ready();
      expect(f.retained.get(encodeId("meeting", moving))).toContain("New project context");
      expect(f.requests.slice(beforeRename).filter((r) => r.path.endsWith("/memories") && r.method === "POST")).toHaveLength(1);
    } finally { await f.close(); }
  });
  it("dispatches memory work from the shared DB queue", async () => {
    const send = vi.fn(), step = vi.fn();
    const job = { id: "memory", kind: "workspace-memory", payload: { scopeId: workspaceId }, createdAt: new Date() };
    const queue = { claim: vi.fn().mockResolvedValueOnce({ ...job, batch: [job] }).mockResolvedValue(null),
      complete: vi.fn(), nextDelay: vi.fn().mockResolvedValue(5) };
    const jobs = createQueueJobs({ DAHLIA_JOB_QUEUE: { send, sendBatch: vi.fn() } }, { queue } as never,
      {} as never, {} as never, [], undefined, undefined, { step } as unknown as WorkspaceMemoryService);
    await jobs.consume({ action: "wake" }, new AbortController().signal);
    expect(step).toHaveBeenCalledWith(workspaceId, expect.any(AbortSignal), expect.objectContaining({ id: "memory" }));
    expect(send).toHaveBeenCalledWith({ action: "wake" }, { delaySeconds: 5 });
  });
});

describe("Workspace memory recall", () => {
  const signal = new AbortController().signal;
  const long = async (f: Awaited<ReturnType<typeof setup>>, projectId: string | null = null) => {
    const meetingId = uuidV7(), now = new Date().toISOString();
    await f.commit([{ entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
      data: { projectId, name: "Long meeting", description: "Evidence", status: "READY", duration: 60, recordingStartedAt: now, createdAt: now, updatedAt: now } }]);
    return meetingId;
  };
  const segments = (count: number) => Array.from({ length: count }, (_, i) => ({ segmentId: `seg-${i}`, startedAt: new Date("2026-01-01T00:00:00Z"),
    speakerLabel: null, audioSource: "microphone", text: `Statement ${i} ${"x".repeat(900)}` }));

  it("follows observations to their source documents in recall order within the 30-candidate limit", async () => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      const [a, b] = [uuidV7(), uuidV7()];
      for (const id of [a, b]) await f.app.memory!.saveNote(owner.userId, workspaceId, { id, revision: 0, content: `Note ${id}` });
      await f.ready();
      const response = (unknown: number) => () => ({ results: [
        ...Array.from({ length: unknown }, (_, i) => ({ id: `w${i}`, text: "UNTRUSTED", type: "world", document_id: encodeId("sharedMemory", uuidV7()) })),
        { id: "o1", text: "UNTRUSTED OBSERVATION", type: "observation", source_fact_ids: ["cut", "f1", "f2"] },
        { id: "late", text: "UNTRUSTED", type: "experience", document_id: encodeId("sharedMemory", a) },
      ], source_facts: { f1: { id: "f1", text: "UNTRUSTED", document_id: encodeId("sharedMemory", b), chunk_id: "unneeded-short-document-chunk" }, f2: { id: "f2", text: "UNTRUSTED", document_id: encodeId("sharedMemory", a) } } });
      f.setRecall(response(28));
      const found = await f.memory.search(owner, workspaceId, "notes", false, signal);
      expect(found.sources.map((source) => source.id)).toEqual([b, a]);
      expect(JSON.stringify(found)).not.toContain("UNTRUSTED");
      expect(f.requests.some((r) => r.path.includes("/chunks/"))).toBe(false);
      const { query_timestamp: timestamp, ...body } = f.recallBodies().at(-1)!;
      expect(typeof timestamp).toBe("string");
      expect(body).toEqual({ query: "notes", types: ["world", "experience"], budget: "mid", max_tokens: 4096,
        include: { entities: null, chunks: { max_tokens: 8192 } } });
      f.setRecall(response(29));
      expect((await f.memory.search(owner, workspaceId, "notes", false, signal)).sources.map((source) => source.id)).toEqual([b]);
    } finally { await f.close(); }
  });

  it("cuts long canonical meetings around recalled markers and reads back missing chunks from the expected bank only", async () => {
    const f = await setup();
    try {
      const meetingId = await long(f);
      vi.spyOn(f.sync, "listTranscript").mockResolvedValue({ items: segments(40) } as never);
      await f.memory.configure(owner, workspaceId, true); await f.ready();
      const document = encodeId("meeting", meetingId), bank = `dahlia_${encodeId("workspace", workspaceId)}`;
      const marker = (i: number) => `claim [Transcript segment seg-${i}; 2026-01-01T00:00:00.000Z; speaker unknown; microphone] UNTRUSTED CHUNK`;
      f.chunks.set("missing", { bank_id: bank, document_id: document, chunk_text: marker(10) });
      f.chunks.set("cut", { bank_id: bank, document_id: document, chunk_text: marker(35) });
      f.chunks.set("foreign-bank", { bank_id: `dahlia_${encodeId("workspace", uuidV7())}`, document_id: document, chunk_text: marker(20) });
      f.chunks.set("foreign-document", { bank_id: bank, document_id: encodeId("meeting", uuidV7()), chunk_text: marker(25) });
      const fact = (chunk_id: string) => ({ id: chunk_id, text: "UNTRUSTED", type: "world", document_id: document, chunk_id });
      f.setRecall(() => ({ results: ["recalled", "missing", "cut", "foreign-document", "foreign-bank"].map(fact),
        chunks: { recalled: { id: "recalled", text: marker(30), chunk_index: 0 }, cut: { id: "cut", text: "[Transcript segment seg-", chunk_index: 1, truncated: true } } }));
      const before = f.requests.length;
      const [source] = (await f.memory.search(owner, workspaceId, "statement", false, signal)).sources;
      expect(source!.truncated).toBe(true);
      for (const i of [9, 10, 11, 29, 30, 31, 34, 35]) expect(source!.canonicalExcerpt).toContain(`Statement ${i} `);
      for (const i of [0, 20, 25]) expect(source!.canonicalExcerpt).not.toContain(`Statement ${i} `);
      expect(source!.canonicalExcerpt).toContain("\n\n…\n\n");
      expect(source!.canonicalExcerpt).not.toContain("UNTRUSTED");
      // The chunk route is not bank-scoped; at most three are read back per document.
      expect(f.requests.slice(before).filter((r) => r.path.includes("/chunks/")).map((r) => r.path))
        .toEqual(["missing", "cut", "foreign-document"].map((id) => `/api/v1/default/chunks/${id}`));
      // Reflect may cite a fact that the separate recall did not return.
      f.facts.set("reflection-fact", { state: "valid", document_id: document, chunk_id: "cut" });
      f.setReflection(() => ({ structured_output: { claims: [{ text: "Source-backed hypothesis", factIds: ["reflection-fact"] }] },
        based_on: { memories: [{ id: "reflection-fact" }] } }));
      f.setRecall(() => ({ results: [] }));
      const reflected = await f.memory.search(owner, workspaceId, "statement", true, signal);
      expect(reflected.reflectionStatus).toBe("ready");
      expect(reflected.sources[0]!.canonicalExcerpt).toContain("Statement 35 ");
      expect(reflected.sources[0]!.canonicalExcerpt).not.toContain("UNTRUSTED CHUNK");
      f.setRecall(() => ({ results: [{ id: "plain", text: "UNTRUSTED", type: "world", document_id: document }] }));
      const [head] = (await f.memory.search(owner, workspaceId, "statement", false, signal)).sources;
      expect(head!.canonicalExcerpt).toMatch(new RegExp(`^Meeting ${meetingId}; date`));
      expect(head).toMatchObject({ truncated: true });
      expect(head!.canonicalExcerpt).toHaveLength(16_000);
      f.setRecall(() => ({ results: [fact("missing")] }));
      const chunk = vi.spyOn(f.memory.client, "chunk").mockRejectedValue(new HindsightError("memory_upstream_failed", 500));
      expect((await f.memory.search(owner, workspaceId, "statement", false, signal)).sources).toEqual([head]);
      chunk.mockRejectedValue(new HindsightError("memory_upstream_failed", 403));
      await expect(f.memory.search(owner, workspaceId, "statement", false, signal)).rejects.toMatchObject({ status: 403 });
      const authError = new DatabricksTokenError("Databricks authentication failed");
      chunk.mockRejectedValue(authError);
      await expect(f.memory.search(owner, workspaceId, "statement", false, signal)).rejects.toBe(authError);
      chunk.mockRejectedValue(new DatabricksTokenError("Databricks authentication failed", true));
      expect((await f.memory.search(owner, workspaceId, "statement", false, signal)).sources).toEqual([head]);
      chunk.mockImplementation(async (_bank, _id, deadline) => {
        await new Promise<void>((resolve) => deadline.addEventListener("abort", () => resolve(), { once: true }));
        throw new HindsightError("memory_cancelled");
      });
      const pending = f.memory.search(owner, workspaceId, "statement", false, signal);
      expect((await pending).sources).toEqual([head]);
      const controller = new AbortController();
      chunk.mockImplementation(async () => { controller.abort(); throw new HindsightError("memory_cancelled"); });
      await expect(f.memory.search(owner, workspaceId, "statement", false, controller.signal)).rejects.toThrow();
    } finally { await f.close(); }
  });

  it("limits a Project search to its Workspace and canonical Project membership", async () => {
    const f = await setup();
    try {
      const projectId = uuidV7(), now = new Date().toISOString();
      await f.commit([{ entity: "project", action: "create", entityId: projectId, baseRevision: null,
        data: { name: "Launch", parentProjectId: null, projectType: null, description: "Context", createdAt: now } }]);
      const inside = await long(f, projectId), outside = await long(f);
      await f.memory.configure(owner, workspaceId, true); await f.ready();
      const found = await f.memory.search(viewer, workspaceId, "evidence", true, signal, { projectId });
      expect(found.sources.map((source) => source.id)).toEqual([inside]);
      expect(found.sources.map((source) => source.id)).not.toContain(outside);
      const scope = { tags: [`project:${projectId}`], tags_match: "all_strict" };
      expect(f.recallBodies().at(-1)).toMatchObject(scope);
      expect(f.requests.filter((r) => r.path.endsWith("/reflect")).at(-1)!.body).toMatchObject({ ...scope, budget: "low" });
      const otherWorkspace = uuidV7(), foreign = uuidV7();
      await f.sync.commitTransaction(owner, { schemaVersion: 3, workspaceId: otherWorkspace, id: uuidV7(), createdAt: now, operations: [
        { id: uuidV7(), entity: "workspace", action: "create", entityId: otherWorkspace, baseRevision: null, data: { organizationId: testOrganizationID, name: "Other", createdAt: now } },
        { id: uuidV7(), entity: "project", action: "create", entityId: foreign, baseRevision: null, data: { name: "Foreign", parentProjectId: null, projectType: null, description: "", createdAt: now } }] });
      const before = f.requests.length;
      for (const id of [foreign, uuidV7()]) {
        await expect(f.memory.search(owner, workspaceId, "evidence", false, signal, { projectId: id })).rejects.toMatchObject({ status: 404, code: "project_not_found" });
      }
      expect(f.requests).toHaveLength(before);
    } finally { await f.close(); }
  });

  it("maps periods to a ranking window and depth to the recall budget", async () => {
    const f = await setup();
    try {
      await f.memory.configure(owner, workspaceId, true);
      await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Dated note" });
      await f.ready();
      const search = (input: Parameters<typeof f.memory.search>[5]) => f.memory.search(owner, workspaceId, "note", false, signal, input);
      await search({ after: "2026-01-01T09:00:00+09:00", before: "2026-02-01T00:00:00Z", depth: "deep" });
      expect(f.recallBodies().at(-1)).toMatchObject({ budget: "high", temporal_window: { start: "2026-01-01T00:00:00.000Z", end: "2026-02-01T00:00:00.000Z" } });
      const started = Date.now();
      await search({ after: "2026-01-01T00:00:00Z", depth: "quick" });
      const window = f.recallBodies().at(-1)!.temporal_window as { start: string; end: string };
      expect(window.start).toBe("2026-01-01T00:00:00.000Z");
      expect(Date.parse(window.end)).toBeGreaterThanOrEqual(started);
      expect(f.recallBodies().at(-1)).toMatchObject({ budget: "low" });
      await search({ before: "2026-02-01T00:00:00Z", depth: "normal" });
      expect(f.recallBodies().at(-1)).toMatchObject({ budget: "mid", temporal_window: { start: "1970-01-01T00:00:00.000Z", end: "2026-02-01T00:00:00.000Z" } });
      await search({});
      expect(f.recallBodies().at(-1)).toMatchObject({ budget: "mid" });
      expect(f.recallBodies().at(-1)).not.toHaveProperty("temporal_window");
      const reflection = vi.spyOn(f.memory.client, "reflect");
      const temporal = await f.memory.search(owner, workspaceId, "note", true, signal, { after: "2026-01-01T00:00:00Z" });
      expect(reflection).not.toHaveBeenCalled();
      expect(temporal).toMatchObject({ hypothesis: null });
      expect(temporal.sources).toHaveLength(1);
      expect(temporal.instruction).toContain("recall sources only");
      await f.memory.search(owner, workspaceId, "note", true, signal);
      expect(reflection).toHaveBeenCalledOnce();
      const before = f.requests.length;
      for (const input of [{ after: "2026-02-01T00:00:00Z", before: "2026-01-01T00:00:00Z" }, { after: "2999-01-01T00:00:00Z" }]) {
        await expect(search(input)).rejects.toMatchObject({ status: 400, code: "memory_time_range_invalid" });
      }
      expect(f.requests).toHaveLength(before);
    } finally { await f.close(); }
  });
});

describe("Hindsight authentication", () => {
  const env = { DAHLIA_AUTH_TYPE: "header", DAHLIA_AUTH_SECRET: "test-only-better-auth-secret-value", DAHLIA_HINDSIGHT_URL: "https://memory.example/api" };
  it("cancels a chunk's token wait without cancelling another request sharing the refresh", async () => {
    let respond!: (response: Response) => void;
    const fetcher = vi.fn<typeof fetch>(async (url) => String(url).endsWith("/oidc/v1/token")
      ? new Promise<Response>((resolve) => { respond = resolve; })
      : Response.json({ bank_id: "bank", document_id: "meeting", chunk_text: "hint" }));
    const client = new HindsightClient({ url: "https://memory.example/api", auth: "databricks" },
      { host: "https://workspace.example", tokenUrl: "https://workspace.example/oidc/v1/token", clientId: "app", clientSecret: "secret" }, fetcher);
    const controller = new AbortController();
    let cancelled: unknown;
    const first = client.chunk("bank", "first", controller.signal).catch((error: unknown) => { cancelled = error; });
    const second = client.chunk("bank", "second", new AbortController().signal);
    controller.abort();
    try {
      await vi.waitFor(() => expect(cancelled).toMatchObject({ name: "AbortError" }), { timeout: 100 });
      expect(fetcher).toHaveBeenCalledOnce();
    } finally {
      respond(Response.json({ access_token: "token", expires_in: 3600 }));
      await first;
      await second;
    }
    expect(await second).toEqual({ documentId: "meeting", text: "hint" });
    expect(fetcher).toHaveBeenCalledTimes(2);
    await expect(client.chunk("bank", "cancelled", AbortSignal.abort())).rejects.toMatchObject({ name: "AbortError" });
    expect(fetcher).toHaveBeenCalledTimes(2);
  });
  it("keeps image processing opt-in with bounded server settings", () => {
    const base = { ...env, DAHLIA_HINDSIGHT_AUTH: "none" };
    expect(loadConfig(base).hindsight?.images).toBeUndefined();
    const configured = { ...base, DAHLIA_MEMORY_IMAGE_MODEL: "system.ai.gpt-6-luna" };
    expect(loadConfig(configured).hindsight?.images).toEqual({ model: "system.ai.gpt-6-luna", maxCount: 8, maxBytes: 8388608, longEdge: 1568 });
    expect(() => loadConfig({ ...configured, DAHLIA_MEMORY_IMAGE_MAX_COUNT: "0" })).toThrow();
    expect(() => loadConfig({ ...configured, DAHLIA_MEMORY_IMAGE_MAX_BYTES: "33554433" })).toThrow();
    expect(() => loadConfig({ ...configured, DAHLIA_MEMORY_IMAGE_LONG_EDGE: "4096" })).toThrow();
  });
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
      expect(String(url)).toContain("/api/v1/default/banks/dahlia_ws_");
      expect(init?.redirect).toBe("error");
      return new Response(null, { status: 403 });
    });
    const client = new HindsightClient({ url: "https://memory.example/api", auth: "databricks" },
      { host: "https://workspace.example", tokenUrl: "https://workspace.example/oidc/v1/token", clientId: "app", clientSecret: "secret" }, fetcher);
    await Promise.all([1, 2].map(() => expect(client.recall(client.bank(workspaceId), "q", new AbortController().signal)).rejects.toMatchObject({ status: 403 })));
    expect(count).toBe(1);
    vi.advanceTimersByTime(61_000);
    await expect(client.recall(client.bank(workspaceId), "q", new AbortController().signal)).rejects.toMatchObject({ status: 403 });
    expect(count).toBe(2);
  });
});

describe("Pinned Hindsight response contracts", () => {
  it("resolves observation lineage to documents and rejects invalidated evidence", async () => {
    let invalidated = false;
    const client = new HindsightClient({ url: "http://localhost:8888", auth: "none" }, undefined, async (url) => {
      const path = new URL(String(url)).pathname;
      if (path.endsWith("observation")) return Response.json({ state: "valid", document_id: null, source_memory_ids: ["source"] });
      return Response.json({ state: invalidated ? "invalidated" : "valid", document_id: encodeId("meeting", workspaceId) });
    });
    expect(await client.factDocuments("bank", "observation", new AbortController().signal)).toEqual([encodeId("meeting", workspaceId)]);
    invalidated = true;
    expect(await client.factDocuments("bank", "observation", new AbortController().signal)).toEqual([]);
  });
  it("reads chunks outside the bank path and accepts only the expected bank", async () => {
    const paths: string[] = [];
    const client = new HindsightClient({ url: "http://localhost:8888", auth: "none" }, undefined, async (url) => {
      const path = new URL(String(url)).pathname; paths.push(path);
      if (path.endsWith("gone")) return new Response(null, { status: 404 });
      return Response.json({ chunk_id: "c", bank_id: path.endsWith("mine") ? "bank" : "other", document_id: encodeId("meeting", workspaceId), chunk_index: 0, chunk_text: "text", created_at: "" });
    });
    // Upstream chunk IDs remain opaque, even when they resemble older document names.
    expect(await client.chunk("bank", "bank_meeting-1_mine", new AbortController().signal)).toEqual({ documentId: encodeId("meeting", workspaceId), text: "text" });
    expect(await client.chunk("bank", "other_meeting-1_theirs", new AbortController().signal)).toBeNull();
    expect(await client.chunk("bank", "gone", new AbortController().signal)).toBeNull();
    expect(paths).toEqual(["/v1/default/chunks/bank_meeting-1_mine", "/v1/default/chunks/other_meeting-1_theirs", "/v1/default/chunks/gone"]);
  });
  it("recovers a mental-model creation whose acknowledgement was lost", async () => {
    let created = false; const methods: string[] = [];
    const client = new HindsightClient({ url: "http://localhost:8888", auth: "none" }, undefined, async (url, init) => {
      methods.push(`${init?.method} ${new URL(String(url)).pathname.split("/").at(-1)}`);
      if (init?.method === "GET") return created ? Response.json({ id: "workspace-insights" }) : new Response(null, { status: 404 });
      if (!created) { created = true; throw new Error("lost response"); }
      return Response.json({ operation_id: "refresh-operation" });
    });
    await expect(client.createModel("bank", null, new AbortController().signal)).rejects.toThrow("memory_transport_failed");
    expect(await client.createModel("bank", null, new AbortController().signal)).toBe("refresh-operation");
    expect(methods).toEqual(["GET workspace-insights", "POST mental-models", "GET workspace-insights", "PATCH workspace-insights", "POST refresh"]);
  });
});

describe("Structured reflection publication", () => {
  async function indexed() {
    const f = await setup();
    await f.memory.configure(owner, workspaceId, true);
    const note = await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: "Canonical evidence" });
    await f.ready();
    // Derive the actual document identity from ingestion, including its source-kind prefix.
    f.facts.set("fact", { state: "valid", document_id: [...f.retained.keys()][0] });
    const response = (claims: Array<{ text: string; factIds: string[] }>, ids = ["fact"]) => ({
      text: "RAW ANSWER MUST NEVER BE PUBLISHED", structured_output: { claims },
      based_on: { memories: ids.map((id) => ({ id, text: "LLM QUOTE MUST NEVER BE PUBLISHED" })) },
    });
    const search = (identity = owner) => f.memory.search(identity, workspaceId, "evidence", true, new AbortController().signal);
    return { ...f, note, response, search };
  }
  it("publishes only independently verified claims and keeps canonical citations across the public API", async () => {
    const f = await indexed();
    try {
      f.setReflection(() => f.response([{ text: "Supported hypothesis", factIds: ["fact", "fact"] }, { text: "Fabricated", factIds: ["invented"] }, { text: "Missing refs", factIds: [] }]));
      const result = await f.search();
      expect(result).toMatchObject({ hypothesis: "Supported hypothesis", reflectionStatus: "partial",
        claims: [{ text: "Supported hypothesis", citations: [{ factId: "fact", sourceIndexes: [0] }] }],
      });
      expect(result.sources[0]?.canonicalExcerpt).toContain("Canonical evidence");
      expect(JSON.stringify(result)).not.toMatch(/RAW ANSWER|LLM QUOTE|Fabricated/);
      expect(f.requests.some((r) => r.path.endsWith("/invented"))).toBe(false);
      expect(f.requests.find((r) => r.path.endsWith("/reflect"))!.body).toMatchObject({
        exclude_mental_models: true, response_schema: { properties: { claims: { type: "array" } } },
      });
      const app = createApp({ config: f.config, authStore: f.app, syncService: f.sync, workspaceMemory: f.memory });
      const response = await app.request(`/api/v1/workspaces/${encodeId("workspace", workspaceId)}/memory/reflect`, {
        method: "POST", headers: { "x-forwarded-email": `${owner.userId}@example.com`, "content-type": "application/json" }, body: JSON.stringify({ query: "evidence" }),
      });
      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({ results: [{ result: { claims: result.claims, reflectionStatus: "partial" } }] });
    } finally { await f.close(); }
  });
  it.each([
    [{}, "missing_output"],
    [{ structured_output_error: "SECRET provider failure" }, "structured_error"],
    [{ structured_output: { claims: [] } }, "empty"],
    [{ structured_output: { claims: [{ text: "missing references" }] } }, "invalid_output"],
  ])("distinguishes structured failures without publishing raw output: %j", async (fields, status) => {
    const f = await indexed();
    try {
      f.setReflection(() => ({ text: "SECRET raw answer", based_on: { memories: [{ id: "fact" }] }, ...fields }));
      const result = await f.search();
      expect(result).toMatchObject({ hypothesis: null, claims: [], reflectionStatus: status });
      expect(JSON.stringify(result)).not.toContain("SECRET");
      expect(result.sources).toHaveLength(1);
    } finally { await f.close(); }
  });
  it("rejects missing, invalidated, cross-bank and incomplete observation lineage", async () => {
    const f = await indexed();
    try {
      f.setReflection(() => f.response([{ text: "Unsafe", factIds: ["observation"] }], ["observation"]));
      for (const fact of [
        { state: "invalidated", document_id: [...f.retained.keys()][0] },
        { state: "valid", source_memory_ids: ["fact", "other-bank-fact"] },
        { state: "valid", source_memory_ids: [] },
        { state: "valid", source_memory_ids: Array.from({ length: 21 }, () => "fact") },
      ]) {
        f.facts.set("observation", fact);
        expect(await f.search()).toMatchObject({ hypothesis: null, claims: [], reflectionStatus: "invalid_references" });
      }
      expect(f.requests.filter((r) => r.path.includes("/memories/") && r.method === "GET").every((r) => r.path.includes(`/banks/dahlia_${encodeId("workspace", workspaceId)}/`))).toBe(true);
    } finally { await f.close(); }
  });
  it("drops an entire claim when all its documents cannot fit in the five-source result", async () => {
    const f = await indexed();
    try {
      for (let i = 0; i < 5; i++) await f.app.memory!.saveNote(owner.userId, workspaceId, { id: uuidV7(), revision: 0, content: `Evidence ${i}` });
      await f.ready();
      const ids = [...f.retained.keys()].map((document_id, i) => { const id = `source-${i}`; f.facts.set(id, { document_id, state: "valid" }); return id; });
      f.facts.set("observation", { state: "valid", source_memory_ids: ids });
      f.setReflection(() => f.response([{ text: "Needs six sources", factIds: ["observation"] }], ["observation"]));
      expect(await f.search()).toMatchObject({ hypothesis: null, claims: [], reflectionStatus: "invalid_references" });
      f.setReflection(() => f.response([
        { text: "Needs six sources", factIds: ["observation"] },
        { text: "Fits independently", factIds: [ids[5]!] },
      ], ["observation", ids[5]!]));
      const result = await f.search();
      expect(result).toMatchObject({ hypothesis: "Fits independently", reflectionStatus: "partial",
        claims: [{ text: "Fits independently", citations: [{ factId: ids[5], sourceIndexes: [0] }] }],
      });
      expect(result.sources).toHaveLength(5);
      expect(encodeId("sharedMemory", result.sources[0]!.id)).toBe([...f.retained.keys()][5]);
      f.setReflection(() => f.response([
        { text: "First four", factIds: ids.slice(0, 4) },
        { text: "Two cannot fit", factIds: ids.slice(4) },
        { text: "Last one fits", factIds: [ids[5]!] },
      ], ids));
      const packed = await f.search();
      expect(packed.claims.map((claim) => claim.text)).toEqual(["First four", "Last one fits"]);
      expect(packed.reflectionStatus).toBe("partial");
      expect(packed.sources).toHaveLength(5);
    } finally { await f.close(); }
  });
  it.each(["update", "delete", "revoke", "pause", "cancel"])("rechecks canonical state after external work: %s", async (change) => {
    const f = await indexed();
    const controller = new AbortController();
    try {
      f.setReflection(() => f.response([{ text: "Old hypothesis", factIds: ["fact"] }]));
      const read = f.memory.client.factDocuments.bind(f.memory.client);
      vi.spyOn(f.memory.client, "factDocuments").mockImplementationOnce(async (...args) => {
        const result = await read(...args);
        if (change === "update") await f.app.memory!.saveNote(owner.userId, workspaceId, { id: f.note.id, revision: 1, content: "Changed" });
        if (change === "delete") await f.app.memory!.deleteNote(owner.userId, workspaceId, f.note.id, 1);
        if (change === "revoke") f.db.prepare("DELETE FROM workspace_permissions WHERE principal_id = ?").run(viewer.userId);
        if (change === "pause") await f.memory.configure(owner, workspaceId, false);
        if (change === "cancel") controller.abort();
        return result;
      });
      const result = f.memory.search(viewer, workspaceId, "evidence", true, controller.signal);
      if (["revoke", "pause", "cancel"].includes(change)) await expect(result).rejects.toBeDefined();
      else expect(await result).toMatchObject({ claims: [], hypothesis: null, reflectionStatus: "updating", sources: [] });
    } finally { await f.close(); }
  });
  it("applies the new mission to an existing bank without a destructive rebuild", async () => {
    const f = await indexed();
    try {
      f.db.exec("UPDATE workspace_memory_state SET progress = json_remove(progress, '$.reflectionPolicy')");
      await expect(f.search()).rejects.toThrow("memory_not_ready");
      f.requests.length = 0;
      await f.tick(); await f.tick();
      expect(f.requests.filter((request) => request.method !== "GET")).toHaveLength(1);
      expect(f.requests[0]?.method).toBe("PATCH");
      expect((f.requests[0]?.body.updates as { reflect_mission: string }).reflect_mission).toContain("exact supporting memory or observation fact IDs");
      expect(f.retained.size).toBe(1);
    } finally { await f.close(); }
  });
});
