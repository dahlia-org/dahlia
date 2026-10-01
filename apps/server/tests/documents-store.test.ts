import oldFixture from "./fixtures/documents-v1.json";
import { SyncEvents } from "../src/sync/events";
import { SyncNotifications } from "../src/client/sync-notifications";
import { z } from "zod";
import { afterEach, expect, it, vi } from "vitest";
import { BrowserDocument } from "../src/client/Documents";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import * as Y from "yjs";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { MeetingSyncService } from "../src/sync/service";
import { uuidV7 } from "../src/id";
import { seedHeaderIdentity, testOrganizationID, testUserID } from "./public-test-client";
import { DocumentCore } from "../src/documents/core";
import { blockMap } from "../src/documents/blocks";
import { firstText, deleteFirst } from "./fixtures/document-helpers";
import { encryptionConfig, encodeBase64 } from "../src/encryption/crypto";
import type { Identity } from "../src/auth/identity";
import type { DocumentStore } from "../src/documents/store";
import { SummaryService, summaryJobResponse } from "../src/summary/service";
import { createApp } from "../src/app";
import { encodeId } from "../src/typeid";
import { documentExchangeResultSchema, sharedDocumentSchema, documentRecoveryPageBytes, documentResponseLimit } from "../src/documents/model";

const owner: Identity = { userId: testUserID("document-owner"), source: "header" };
const outsider: Identity = { userId: testUserID("document-outsider"), source: "header" };
const cleanups: (() => Promise<void>)[] = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); });
async function setup(encrypted = false, documentDeletionGraceHours = 24) {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-document-")), path = join(directory, "db.sqlite");
  const config = { authProvider: "header" as const, authHeader: "X-Forwarded-Email", databaseType: "sqlite" as const, databaseUrl: `file:${path}`,
    baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1_048_576, documentDeletionGraceHours,
    encryption: encryptionConfig({ DAHLIA_ENCRYPTION_ACTIVE_KEY_ID: "1", DAHLIA_ENCRYPTION_MASTER_KEY_1: encodeBase64(new Uint8Array(32).fill(7)) }),
  };
  const store = createNodeApplicationStore(config);
  cleanups.push(async () => { await store.close?.(); rmSync(directory, { recursive: true, force: true }); });
  await store.migrate(); await seedHeaderIdentity(store, path, owner); await seedHeaderIdentity(store, path, outsider);
  const workspaceId = uuidV7(), meetingId = uuidV7(), documentId = uuidV7(), sync = new MeetingSyncService(store.sync);
  await sync.commitTransaction(owner, { id: uuidV7(), schemaVersion: 3, workspaceId, createdAt: new Date().toISOString(), operations: [
    { id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null, data: { organizationId: testOrganizationID, name: "Documents", encryption: encrypted ? "server" : "none", createdAt: new Date().toISOString() } },
    { id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: { name: "Meeting", projectId: null, description: "", status: "READY", duration: null, recordingStartedAt: null, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } },
  ] });
  const run = <T>(action: (store: DocumentStore) => Promise<T>, identity = owner) => store.sync.withIdentity(identity, action);
  return { store, sync, workspaceId, meetingId, documentId, run, path, config };
}

it.each([false, true])("pages retained recovery bodies without truncation (encrypted=%s)", async (encrypted) => {
  const f = await setup(encrypted);
  await f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId));
  const records = ["\u0001".repeat(1_100_000), ...Array<string>(6).fill("日本語".repeat(100))].map((text) => ({
    id: uuidV7(), reason: "concurrent_delete" as const, blocks: [{ id: uuidV7(), type: "paragraph", text }],
  })).sort((a, b) => a.id.localeCompare(b.id));
  for (const record of records) await f.run((s) => s.saveDocumentRecovery(f.workspaceId, f.documentId, record));
  const received = [];
  let after: string | undefined, pages = 0;
  do {
    const page = await f.run((s) => s.documentRecoveries(f.workspaceId, f.documentId, after));
    const bytes = new TextEncoder().encode(JSON.stringify(page)).length;
    expect(bytes).toBeLessThan(documentResponseLimit);
    expect(page.items.length === 1 || bytes <= documentRecoveryPageBytes).toBe(true);
    expect(page.nextCursor).not.toBe(after);
    received.push(...page.items.map(({ id, reason, blocks }) => ({ id, reason, blocks })));
    after = page.nextCursor ?? undefined;
    expect(++pages).toBeLessThanOrEqual(records.length);
  } while (after);
  expect(pages).toBeGreaterThan(1);
  expect(received).toEqual(records);
});

it("excludes a deleting parent Workspace from document discovery", async () => {
  const f = await setup();
  await f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId));
  expect((await f.run((s) => s.listDocuments(f.workspaceId))).items).toHaveLength(1);
  const db = new DatabaseSync(f.path);
  try {
    db.prepare("UPDATE workspaces SET deleting_at = ? WHERE workspace_id = ?").run(Date.now(), f.workspaceId);
    await expect(f.run((s) => s.listDocuments(f.workspaceId))).rejects.toThrow("document_unavailable");
    await expect(f.run((s) => s.getDocument(f.workspaceId, f.documentId))).rejects.toThrow("document_unavailable");
    db.prepare("UPDATE workspaces SET deleting_at = NULL WHERE workspace_id = ?").run(f.workspaceId);
    expect((await f.run((s) => s.listDocuments(f.workspaceId))).items).toHaveLength(1);
  } finally { db.close(); }
});

it("reclaims departed editors' expired presence without removing live sessions or other Workspaces", async () => {
  const f = await setup(), other = { workspaceId: uuidV7(), meetingId: uuidV7(), documentId: uuidV7() };
  await f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId));
  const expired = uuidV7(), active = uuidV7();
  await f.run((s) => s.documentPresence(f.workspaceId, f.documentId, expired));
  await f.run((s) => s.documentPresence(f.workspaceId, f.documentId, active));
  const db = new DatabaseSync(f.path);
  try {
    // Same database: a separate Workspace is intentionally outside this cleanup boundary.
    await f.sync.commitTransaction(owner, { id: uuidV7(), schemaVersion: 3, workspaceId: other.workspaceId, createdAt: new Date().toISOString(), operations: [
      { id: uuidV7(), entity: "workspace", action: "create", entityId: other.workspaceId, baseRevision: null,
        data: { organizationId: testOrganizationID, name: "Other", encryption: "none", createdAt: new Date().toISOString() } },
      { id: uuidV7(), entity: "meeting", action: "create", entityId: other.meetingId, baseRevision: null,
        data: { name: "Other", projectId: null, description: "", status: "READY", duration: null, recordingStartedAt: null, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } },
    ] });
    await f.run((s) => s.initializeMeetingNotes(other.workspaceId, other.meetingId, other.documentId));
    const untouched = uuidV7();
    await f.run((s) => s.documentPresence(other.workspaceId, other.documentId, untouched));
    db.prepare("UPDATE document_presence SET expires_at = ? WHERE id IN (?, ?)").run(Date.now() - 1_000, expired, untouched);
    db.prepare("INSERT INTO workspace_permissions(workspace_id, principal_type, principal_id, role, granted_by_user_id) VALUES (?, 'user', ?, 'viewer', ?)").run(f.workspaceId, outsider.userId, owner.userId);
    expect(await f.run((s) => s.documentPresence(f.workspaceId, f.documentId), outsider)).toHaveLength(1);
    expect(db.prepare("SELECT id FROM document_presence ORDER BY id").all().map((row) => row.id)).toEqual([expired, active, untouched].sort());
    await expect(f.run((s) => s.documentPresence(f.workspaceId, f.documentId, uuidV7()), outsider)).rejects.toThrow("document_unavailable");
    db.prepare("UPDATE workspace_permissions SET role = 'editor' WHERE workspace_id = ? AND principal_id = ?").run(f.workspaceId, outsider.userId);
    const joined = uuidV7();
    expect(await f.run((s) => s.documentPresence(f.workspaceId, f.documentId, joined), outsider)).toHaveLength(2);
    expect(db.prepare("SELECT id FROM document_presence ORDER BY id").all().map((row) => row.id)).toEqual([active, joined, untouched].sort());
  } finally { db.close(); }
});

it("accepts a whole valid state through the dedicated HTTP budget", async () => {
  const f = await setup(), core = new DocumentCore();
  try {
    const text = Array<string>(4_000).fill("語".repeat(499)).join("\n");
    core.insertText(text, uuidV7);
    const update = core.checkpoint();
    expect(update.length).toBeGreaterThan(8 * 1024 * 1024);
    const document = await f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId));
    const app = createApp({ config: f.config, authStore: f.store });
    const response = await app.request(`/api/v1/workspaces/${encodeId("workspace", f.workspaceId)}/documents/${encodeId("document", f.documentId)}/sync`, {
      method: "POST", headers: { "content-type": "application/json", "X-Forwarded-Email": `${owner.userId}@example.com` },
      body: JSON.stringify({ generation: document.generation, vector: core.vector(), update }),
    });
    expect(response.status).toBe(200);
    const db = new DatabaseSync(f.path);
    try { expect(db.prepare("SELECT text FROM documents WHERE id = ?").get(f.documentId)?.text).toBe(text); }
    finally { db.close(); }
  } finally { core.destroy(); }
});

it.each(["initialize", "exchange"])("rejects v1 storage atomically (%s)", async (operation) => {
  const f = await setup(), core = new DocumentCore();
  try {
    const submitted = oldFixture.checkpoint, vector = core.vector();
    const initial = operation === "exchange" ? await f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId)) : null;
    const app = createApp({ config: f.config, authStore: f.store });
    const workspace = encodeId("workspace", f.workspaceId);
    const response = await app.request(operation === "initialize"
      ? `/api/v1/workspaces/${workspace}/meetings/${encodeId("meeting", f.meetingId)}/notes`
      : `/api/v1/workspaces/${workspace}/documents/${encodeId("document", f.documentId)}/sync`, {
      method: "POST", headers: { "content-type": "application/json", "X-Forwarded-Email": `${owner.userId}@example.com` },
      body: JSON.stringify(operation === "initialize" ? { id: encodeId("document", f.documentId), legacyUpdate: submitted }
        : { generation: initial!.generation, vector, update: submitted }),
    });
    expect(response.status).toBe(422);
    expect(await f.run((s) => s.getMeetingNotes(f.workspaceId, f.meetingId))).toEqual(initial);
    const db = new DatabaseSync(f.path);
    try { expect(db.prepare("SELECT count(*) AS n FROM document_updates").get()!.n).toBe(0); }
    finally { db.close(); }
  } finally { core.destroy(); }
});

it("initializes once, merges pending edits, replays idempotently and survives compaction", async () => {
  const f = await setup(), seed = new DocumentCore(); seed.insertText("note", uuidV7);
  expect(await f.run((s) => s.getMeetingNotes(f.workspaceId, f.meetingId))).toBeNull();
  const doc = await f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId, seed.checkpoint()));
  expect((await f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId, seed.checkpoint()))).revision).toBe(doc.revision);
  const independent = new DocumentCore(); independent.insertText("note", uuidV7);
  await expect(f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId, independent.checkpoint()))).rejects.toThrow("document_already_initialized");
  const a = new DocumentCore(doc.checkpoint), b = new DocumentCore(doc.checkpoint);
  const edit = (core: DocumentCore, value: string) => firstText(core.document).insert(0, value);
  edit(a, "A"); edit(b, "B");
  const exchange = (core: DocumentCore) => f.run((s) => s.exchangeDocument(f.workspaceId, f.documentId, { generation: doc.generation, vector: core.vector(), update: core.checkpoint() }));
  await exchange(a); b.apply((await exchange(b)).update); a.apply((await exchange(a)).update);
  expect(a.projection()).toEqual(b.projection());
  const before = await exchange(a); expect((await exchange(a)).revision).toBe(before.revision);
  for (let i = 0; i < 35; i++) { edit(a, "x"); a.apply((await exchange(a)).update); }
  expect((await f.run((s) => s.getDocument(f.workspaceId, f.documentId)))?.text).toBe(a.projection().text);
  const db = new DatabaseSync(f.path);
  try { expect(Number(db.prepare("SELECT count(*) AS n FROM document_updates").get()!.n)).toBeLessThan(32); } finally { db.close(); }
});

it("records unsent text before canonical purge and distributes the purge", async () => {
  const f = await setup(false, 0), core = new DocumentCore(); core.insertText("before", uuidV7);
  const doc = await f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId, core.checkpoint()));
  firstText(core).insert(6, " UNSENT"); deleteFirst(core);
  const response = await f.run((s) => s.exchangeDocument(f.workspaceId, f.documentId, { generation: doc.generation, vector: core.vector(), update: core.checkpoint() }));
  core.apply(response.update);
  expect(blockMap(core.document).size).toBe(0);
  expect((await f.run((s) => s.documentRecoveries(f.workspaceId, f.documentId))).items[0]?.blocks[0]?.text).toBe("before UNSENT");
  core.destroy();
});

it.each(["append", "deletion"] as const)("rejects unresolved v1 %s without appending or advancing revision", async (kind) => {
  const f = await setup(), doc = await f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId));
  await expect(f.run((s) => s.exchangeDocument(f.workspaceId, f.documentId, { generation: doc.generation, vector: "AA==", update: oldFixture[kind] }))).rejects.toMatchObject({ status: 400, message: "invalid_document_update" });
  expect((await f.run((s) => s.getDocument(f.workspaceId, f.documentId)))?.revision).toBe(0);
});

it("requires explicit meeting restoration and a fresh generation before merging offline edits", async () => {
  const f = await setup(), core = new DocumentCore(); core.insertText("seed", uuidV7);
  try {
    const initial = await f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId, core.checkpoint()));
    firstText(core.document).insert(4, " offline");
    const request = { generation: initial.generation, vector: core.vector(), update: core.checkpoint() };
    const lifecycle = (action: "delete" | "restore", baseRevision: number) => f.sync.commitTransaction(owner, {
      id: uuidV7(), schemaVersion: 3, workspaceId: f.workspaceId, createdAt: new Date().toISOString(), operations: [
        { id: uuidV7(), entity: "meeting", action, entityId: f.meetingId, baseRevision, data: {} },
      ],
    });
    await lifecycle("delete", 1);
    await expect(f.run((s) => s.exchangeDocument(f.workspaceId, f.documentId, request))).rejects.toThrow("document_unavailable");
    await expect(f.run((s) => s.getDocument(f.workspaceId, f.documentId))).rejects.toThrow("document_unavailable");
    expect(await f.store.sync.withIdentity(owner, (s) => s.getMeeting(f.workspaceId, f.meetingId))).toBeNull();
    await lifecycle("restore", 2);
    await expect(f.run((s) => s.exchangeDocument(f.workspaceId, f.documentId, request))).rejects.toThrow("document_generation_changed");
    const restored = await f.run((s) => s.getDocument(f.workspaceId, f.documentId));
    expect(restored?.generation).not.toBe(initial.generation);
    expect(restored?.text).toBe("seed");
    await f.run((s) => s.exchangeDocument(f.workspaceId, f.documentId, { ...request, generation: restored!.generation }));
    expect((await f.run((s) => s.getDocument(f.workspaceId, f.documentId)))?.text).toBe("seed offline");
  } finally { core.destroy(); }
});

it("authorizes all document paths and encrypts checkpoints, updates, recovery and snapshots", async () => {
  const f = await setup(true), core = new DocumentCore(); core.insertText("PRIVATE_NOTE", uuidV7);
  const doc = await f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId, core.checkpoint()));
  await expect(f.run((s) => s.getDocument(f.workspaceId, f.documentId), outsider)).rejects.toThrow("document_unavailable");
  const service = new SummaryService(f.store.sync, [{ id: "transcript", captureSettings: () => ({ model: "test", reasoningEffort: "medium", detail: "medium" }),
    version: async () => "v1", generate: async () => { throw new Error("unused"); } }]);
  const job = await service.start(owner, f.workspaceId, f.meetingId, { id: uuidV7() });
  expect(job.notesSnapshot).toMatchObject({ documentId: f.documentId, text: "PRIVATE_NOTE", revision: 1 });
  expect(JSON.stringify(summaryJobResponse(job))).not.toContain("PRIVATE_NOTE");
  deleteFirst(core.document);
  await f.run((s) => s.exchangeDocument(f.workspaceId, f.documentId, { generation: doc.generation, vector: core.vector(), update: core.checkpoint() }));
  expect((await f.run((s) => s.documentRecoveries(f.workspaceId, f.documentId))).items[0]?.blocks[0]?.text).toBe("PRIVATE_NOTE");
  const saved = await f.store.sync.withIdentity(owner, (s) => s.getSummaryJob(f.workspaceId, f.meetingId, job.id));
  expect(saved?.notesSnapshot?.text).toBe("PRIVATE_NOTE");
  const db = new DatabaseSync(f.path);
  try {
    for (const table of ["documents", "document_updates", "document_recoveries", "jobs_summary"]) {
      const rows = db.prepare(`SELECT * FROM ${table}`).all();
      expect(rows.length).toBeGreaterThan(0); expect(JSON.stringify(rows)).not.toContain("PRIVATE_NOTE");
      expect(rows[0]!.encrypted_payload).toBeTruthy();
    }
  } finally { db.close(); }
});

it("converges simultaneous Notes proposals onto one independent document ID", async () => {
  const f = await setup(), proposals = [uuidV7(), uuidV7()];
  expect(await f.run((s) => s.getMeetingNotes(f.workspaceId, f.meetingId))).toBeNull();
  const rows = await Promise.all(proposals.map((id) => f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, id))));
  expect(rows[0]!.id).toBe(rows[1]!.id);
  expect(proposals).toContain(rows[0]!.id);
  expect(rows[0]!.id).not.toBe(f.meetingId);
  expect((await f.run((s) => s.getMeetingNotes(f.workspaceId, f.meetingId)))?.id).toBe(rows[0]!.id);
  expect((await f.run((s) => s.listDocuments(f.workspaceId))).items).toHaveLength(1);
});

it("keeps unattached documents and multiple meeting summaries independent from Notes", async () => {
  const f = await setup(true), core = new DocumentCore(); core.insertText("GENERAL_PRIVATE", uuidV7);
  try {
    const general = await f.run((s) => s.initializeDocument(f.workspaceId, uuidV7(), { meetingId: null, kind: "general", title: "PRIVATE_TITLE", legacyUpdate: core.checkpoint() }));
    const summary = await f.run((s) => s.initializeDocument(f.workspaceId, uuidV7(), { meetingId: f.meetingId, kind: "summary", title: "Summary", legacyUpdate: core.checkpoint() }));
    const second = await f.run((s) => s.initializeDocument(f.workspaceId, uuidV7(), { meetingId: f.meetingId, kind: "summary", title: "Other" }));
    expect((await f.run((s) => s.getDocument(f.workspaceId, general.id)))?.title).toBe("PRIVATE_TITLE");
    expect((await f.run((s) => s.listDocuments(f.workspaceId))).items.map((d) => d.id).sort()).toEqual([general.id, summary.id, second.id].sort());
    await expect(f.run((s) => s.getDocument(f.workspaceId, general.id), outsider)).rejects.toThrow("document_unavailable");
    await expect(f.run((s) => s.initializeDocument(f.workspaceId, uuidV7(), { meetingId: null, kind: "notes", title: "" }))).rejects.toThrow("document_notes_require_meeting");
    const service = new SummaryService(f.store.sync, [{ id: "transcript", captureSettings: () => ({ model: "test", reasoningEffort: "medium", detail: "medium" }), version: async () => "v1", generate: async () => { throw new Error("unused"); } }]);
    expect((await service.start(owner, f.workspaceId, f.meetingId, { id: uuidV7() })).notesSnapshot).toBeNull();
    const raw = new DatabaseSync(f.path);
    try { expect(JSON.stringify(raw.prepare("SELECT * FROM documents").all())).not.toContain("PRIVATE_TITLE"); } finally { raw.close(); }
    await f.sync.commitTransaction(owner, { id: uuidV7(), schemaVersion: 3, workspaceId: f.workspaceId, createdAt: new Date().toISOString(), operations: [
      { id: uuidV7(), entity: "meeting", action: "delete", entityId: f.meetingId, baseRevision: 1, data: {} },
    ] });
    expect((await f.run((s) => s.listDocuments(f.workspaceId))).items.map((d) => d.id)).toEqual([general.id]);
    expect((await f.run((s) => s.getDocument(f.workspaceId, general.id)))?.text).toBe("GENERAL_PRIVATE");
    await expect(f.run((s) => s.getDocument(f.workspaceId, summary.id))).rejects.toThrow("document_unavailable");
  } finally { core.destroy(); }
});

it("enforces meeting/workspace ownership and the Notes-only unique key in SQLite", async () => {
  const f = await setup(), other = uuidV7();
  await f.sync.commitTransaction(owner, { id: uuidV7(), schemaVersion: 3, workspaceId: other, createdAt: new Date().toISOString(), operations: [
    { id: uuidV7(), entity: "workspace", action: "create", entityId: other, baseRevision: null, data: { organizationId: testOrganizationID, name: "Other", encryption: "none", createdAt: new Date().toISOString() } },
  ] });
  await expect(f.run((s) => s.initializeDocument(other, uuidV7(), { meetingId: f.meetingId, kind: "general", title: "" }))).rejects.toThrow("document_unavailable");
  const document = await f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId));
  const raw = new DatabaseSync(f.path);
  try {
    raw.exec("PRAGMA foreign_keys = ON");
    const duplicate = raw.prepare("INSERT INTO documents (id, workspace_id, meeting_id, kind, title, generation, checkpoint, text, created_at, updated_at) SELECT ?, ?, meeting_id, kind, title, generation, checkpoint, text, created_at, updated_at FROM documents WHERE id = ?");
    expect(() => duplicate.run(uuidV7(), other, document.id)).toThrow();
    expect(() => duplicate.run(uuidV7(), f.workspaceId, document.id)).toThrow();
    expect(() => raw.prepare("UPDATE documents SET workspace_id = ? WHERE id = ?").run(other, document.id)).toThrow();
  } finally { raw.close(); }
});

it("exposes independent document metadata through the Notes resolver and public TypeIDs", async () => {
  const f = await setup(), app = createApp({ config: f.config, authStore: f.store });
  const workspace = encodeId("workspace", f.workspaceId), meeting = encodeId("meeting", f.meetingId), proposed = encodeId("document", f.documentId);
  const path = `/api/v1/workspaces/${workspace}/meetings/${meeting}/notes`;
  const headers = { "X-Forwarded-Email": `${owner.userId}@example.com`, "content-type": "application/json" };
  expect(await (await app.request(path, { headers })).json()).toEqual({ document: null });
  const created = await app.request(path, { method: "POST", headers, body: JSON.stringify({ id: proposed }) });
  expect(created.status).toBe(200);
  const body = await created.json();
  expect(body).toMatchObject({ document: { id: proposed, workspaceId: workspace, meetingId: meeting, kind: "notes", title: "" } });
  const raced = await app.request(path, { method: "POST", headers, body: JSON.stringify({ id: encodeId("document", uuidV7()) }) });
  expect(await raced.json()).toMatchObject({ document: { id: proposed } });
});

it("treats standalone documents as Workspace resources and clears their dependent records on reset", async () => {
  const f = await setup(), workspaceId = uuidV7(), core = new DocumentCore();
  core.insertText("Standalone", uuidV7);
  try {
    await f.sync.commitTransaction(owner, { id: uuidV7(), schemaVersion: 3, workspaceId, createdAt: new Date().toISOString(), operations: [
      { id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null, data: { organizationId: testOrganizationID, name: "Standalone", createdAt: new Date().toISOString() } },
    ] });
    const document = await f.run((s) => s.initializeDocument(workspaceId, uuidV7(), { meetingId: null, kind: "general", title: "Owned", legacyUpdate: core.checkpoint() }));
    await f.run((s) => s.saveDocumentRecovery(workspaceId, document.id, { id: uuidV7(), reason: "deleted", blocks: core.projection().blocks }));
    await f.run((s) => s.documentPresence(workspaceId, document.id, uuidV7()));
    firstText(core.document).insert(10, " edit");
    await f.run((s) => s.exchangeDocument(workspaceId, document.id, { generation: document.generation, vector: core.vector(), update: core.checkpoint() }));
    expect(await f.store.sync.withIdentity(owner, (s) => s.getWorkspace(workspaceId))).toMatchObject({ hasResources: true });
    const reset = (preservePermissions: boolean) => f.sync.commitTransaction(owner, { id: uuidV7(), schemaVersion: 3, workspaceId, createdAt: new Date().toISOString(), operations: [
      { id: uuidV7(), entity: "workspace", action: "reset", entityId: workspaceId, baseRevision: 1, data: { preservePermissions } },
    ] });
    await expect(reset(false)).rejects.toThrow("workspace_not_empty");
    await reset(true);
    expect(await f.store.sync.withIdentity(owner, (s) => s.getWorkspace(workspaceId))).toMatchObject({ hasResources: false });
    expect((await f.run((s) => s.listDocuments(workspaceId))).items).toEqual([]);
    const raw = new DatabaseSync(f.path);
    try {
      for (const table of ["documents", "document_updates", "document_recoveries", "document_presence"]) {
        expect(raw.prepare(`SELECT count(*) AS count FROM ${table} WHERE workspace_id = ?`).get(workspaceId)).toEqual({ count: 0 });
      }
    } finally { raw.close(); }
  } finally { core.destroy(); }
});

it("rejects a switched browser identity before document reads and writes", async () => {
  const f = await setup(), app = createApp({ config: f.config, authStore: f.store });
  const workspace = encodeId("workspace", f.workspaceId), meeting = encodeId("meeting", f.meetingId);
  const headers = { "X-Forwarded-Email": `${owner.userId}@example.com`, "content-type": "application/json",
    "X-Dahlia-Document-User": encodeId("user", outsider.userId) };
  const path = `/api/v1/workspaces/${workspace}/meetings/${meeting}/notes`;
  const rejected = await app.request(path, { method: "POST", headers, body: JSON.stringify({ id: encodeId("document", f.documentId) }) });
  expect(rejected.status).toBe(409);
  expect(await rejected.json()).toMatchObject({ code: "document_account_changed" });
  expect(await f.run((s) => s.getMeetingNotes(f.workspaceId, f.meetingId))).toBeNull();
  expect((await app.request(path, { headers })).status).toBe(409);
  const accepted = await app.request(path, { method: "POST", headers: { ...headers, "X-Dahlia-Document-User": encodeId("user", owner.userId) }, body: JSON.stringify({ id: encodeId("document", f.documentId) }) });
  expect(accepted.status).toBe(200);
});

it.each([false, true])("delivers committed revisions over SSE across application instances (separate=%s)", async (separate) => {
  const f = await setup(), writer = createApp({ config: f.config, authStore: f.store });
  const second = separate ? createNodeApplicationStore(f.config) : undefined;
  if (second) cleanups.push(async () => { await second.close?.(); });
  const readerApp = second ? createApp({ config: f.config, authStore: second }) : writer;
  const document = await f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId));
  const path = `/api/v1/workspaces/${encodeId("workspace", f.workspaceId)}/documents/${encodeId("document", f.documentId)}`;
  const headers = { "X-Forwarded-Email": `${owner.userId}@example.com`, "content-type": "application/json" };
  const response = await readerApp.request(`${path}/events`, { headers });
  const reader = response.body!.getReader(), decoder = new TextDecoder(), core = new DocumentCore(document.checkpoint);
  const frame = async () => { const next = await reader.read(); expect(next.done).toBe(false); return decoder.decode(next.value); };
  try {
    expect(await frame()).toContain(`id: ${document.generation}:0`);
    core.insertText("committed", uuidV7);
    const update = await writer.request(`${path}/sync`, { method: "POST", headers,
      body: JSON.stringify({ generation: document.generation, vector: core.vector(), update: core.checkpoint() }) });
    expect(update.status).toBe(200);
    const committed = documentExchangeResultSchema.parse(await update.json());
    expect(await frame()).toContain(`id: ${committed.generation}:${committed.revision}`);
    expect((await f.run((s) => s.getDocument(f.workspaceId, f.documentId)))?.text).toBe("committed");
    const invalid = await writer.request(`${path}/sync`, { method: "POST", headers,
      body: JSON.stringify({ generation: uuidV7(), vector: core.vector(), update: core.checkpoint() }) });
    expect(invalid.status).toBe(409);
    expect((await f.run((s) => s.documentHead(f.workspaceId, f.documentId)))?.revision).toBe(committed.revision);
  } finally { await reader.cancel(); core.destroy(); }
});


it("measures edit-to-reader latency through two browser controllers, HTTP handlers and separate SSE instances", async () => {
  const f = await setup();
  const apps = [createApp({ config: f.config, authStore: { ...f.store, syncEvents: new SyncEvents() } }), createApp({ config: f.config, authStore: { ...f.store, syncEvents: new SyncEvents() } })];
  const seed = new DocumentCore(); seed.insertText("seed", uuidV7);
  await f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId, seed.checkpoint())); seed.destroy();
  const path = `/api/v1/workspaces/${encodeId("workspace", f.workspaceId)}/documents/${encodeId("document", f.documentId)}`;
  const headers = { "X-Forwarded-Email": `${owner.userId}@example.com` };
  const initial = z.object({ document: sharedDocumentSchema.extend({
    id: z.string(), workspaceId: z.string(), meetingId: z.string().nullable(),
  }) }).parse(await (await apps[0]!.request(path, { headers })).json()).document;
  const deferred = () => {
    let resolve!: () => void, reject!: (error: unknown) => void;
    const promise = new Promise<void>((done, fail) => { resolve = done; reject = fail; });
    return { promise, resolve, reject };
  };
  const ready = deferred(); let connections = 0, opened = 0;
  const failures: unknown[] = [];
  class LocalEventSource extends EventTarget {
    private reader?: ReadableStreamDefaultReader<Uint8Array>;
    private closed = false;
    constructor(url: string) {
      super();
      const app = apps[connections++ % 2]!;
      void (async () => {
        const response = await app.request(url, { headers }); if (!response.ok) throw new Error(`SSE HTTP ${response.status}`); this.reader = response.body!.getReader();
        if (this.closed) { await this.reader.cancel(); return; }
        this.dispatchEvent(new Event("open"));
        const decoder = new TextDecoder(); let buffer = "";
        while (!this.closed) {
          const result = await this.reader.read(); if (result.done) break;
          buffer += decoder.decode(result.value, { stream: true });
          let end: number;
          while ((end = buffer.indexOf("\n\n")) >= 0) {
            const frame = buffer.slice(0, end); buffer = buffer.slice(end + 2);
            const id = /^id: ?(.*)$/m.exec(frame)?.[1] ?? "";
            const event = /^event: ?(.*)$/m.exec(frame)?.[1] ?? "message";
            const data = /^data: ?(.*)$/m.exec(frame)?.[1] ?? "";
            this.dispatchEvent(new MessageEvent(event, { lastEventId: id, data }));
            if (event === "document" && ++opened === 2) ready.resolve();
          }
        }
      })().catch((error: unknown) => { if (!this.closed) { failures.push(error); ready.reject(error); } });
    }
    close() { this.closed = true; void this.reader?.cancel(); }
  }
  vi.stubGlobal("window", new EventTarget()); vi.stubGlobal("EventSource", LocalEventSource);
  vi.stubGlobal("fetch", (request: Request) => {
    const bound = new Request(request); bound.headers.set("X-Forwarded-Email", headers["X-Forwarded-Email"]);
    return apps[0]!.fetch(bound);
  });
  const within = async (pending: Promise<void>, phase: string) => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try { await Promise.race([pending, new Promise<void>((_, reject) => { timer = setTimeout(() => reject(new Error(phase)), 2_000); })]); }
    finally { clearTimeout(timer); }
  };
  const controllers = [0, 1].map(() => new BrowserDocument(encodeId("user", owner.userId), initial.workspaceId, encodeId("meeting", f.meetingId), initial, true, new SyncNotifications()));
  const releases = controllers.map((controller) => controller.retainView());
  try {
    await within(ready.promise, "SSE initial revision");
    const durations: number[] = []; let expected = "seed";
    for (let sample = 0; sample < 20; sample++) {
      const complete = deferred(); expected += "x";
      const listener = () => { if (controllers[1]!.copyText() === expected) complete.resolve(); };
      controllers[1]!.listeners.add(listener);
      const started = performance.now();
      const doc = controllers[0]!.editorDocument, vector = Y.encodeStateVector(doc);
      const text = firstText(doc);
      text.insert(text.length, "x"); await controllers[0]!.editFromEditor(Y.encodeStateAsUpdate(doc, vector));
      await within(complete.promise, `sample ${sample}: ${controllers.map((c) => c.error).join(" / ")}`); durations.push(performance.now() - started);
      controllers[1]!.listeners.delete(listener);
    }
    durations.sort((a, b) => a - b);
    process.stdout.write(`document_latency_local_http_sqlite ${JSON.stringify({ samples: durations.length, p50: durations[9], p95: durations[18], max: durations[19] })}\n`);
    expect(failures).toEqual([]); expect(controllers[1]!.copyText()).toBe(expected);
    await controllers[0]!.flush();
  } finally { releases.forEach((release) => release()); controllers.forEach((controller) => controller.stop()); vi.unstubAllGlobals(); }
}, 15_000);

function notificationURL(userId: string, targets: { workspaceId: string; meetingId: string }[], tab = uuidV7()) {
  return `/api/v1/events?${new URLSearchParams({ user: encodeId("user", userId), tab: tab.replaceAll("-", ""),
    notes: JSON.stringify(targets.map((target) => ({ workspaceId: encodeId("workspace", target.workspaceId), meetingId: encodeId("meeting", target.meetingId) }))) })}`;
}
function notificationReader(response: Response) {
  expect(response.status).toBe(200);
  const reader = response.body!.getReader(), decoder = new TextDecoder();
  let buffer = "";
  const next = async (kind: string): Promise<string> => {
    while (true) {
      const boundary = buffer.indexOf("\n\n");
      if (boundary >= 0) {
        const frame = buffer.slice(0, boundary); buffer = buffer.slice(boundary + 2);
        if (frame.includes(`event: ${kind}\n`)) return frame;
        continue;
      }
      const result = await reader.read();
      if (result.done) throw new Error("stream closed before expected hint");
      buffer += decoder.decode(result.value, { stream: true });
    }
  };
  return { next: async (kind: string) => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try { return await Promise.race([next(kind), new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error(`missing ${kind} hint`)), 2_000); })]); }
    finally { clearTimeout(timer); }
  }, close: () => reader.cancel() };
}

it("combines domain and Notes hints, detects first creation across instances, and replaces only its own subscription", async () => {
  const f = await setup(), second = createNodeApplicationStore(f.config);
  cleanups.push(async () => { await second.close?.(); });
  const readerApp = createApp({ config: f.config, authStore: second });
  const target = { workspaceId: f.workspaceId, meetingId: f.meetingId };
  const headers = { "X-Forwarded-Email": `${owner.userId}@example.com` };
  const tab = uuidV7();
  const first = notificationReader(await readerApp.request(notificationURL(owner.userId, [target], tab), { headers }));
  let replacement: ReturnType<typeof notificationReader> | undefined;
  try {
    expect(await first.next("invalidation")).toContain('"cursor"');
    expect(await first.next("document")).toContain('"cursor":"absent"');
    expect(await f.run((s) => s.getMeetingNotes(f.workspaceId, f.meetingId))).toBeNull();
    // Another instance writes without a process-local notification.
    const document = await f.run((s) => s.initializeMeetingNotes(f.workspaceId, f.meetingId, f.documentId));
    expect(await first.next("document")).toContain(`${document.generation}:0`);
    await first.close();
    const core = new DocumentCore(document.checkpoint); core.insertText("during reconnect", uuidV7);
    await f.run((s) => s.exchangeDocument(f.workspaceId, f.documentId, { generation: document.generation, vector: core.vector(), update: core.checkpoint() })); core.destroy();
    replacement = notificationReader(await readerApp.request(notificationURL(owner.userId, [target], tab), { headers }));
    expect(await replacement.next("document")).toContain(`${document.generation}:1`);
    // Empty replacement has no authority to change another tab's live subscription.
    const closed = notificationReader(await readerApp.request(notificationURL(owner.userId, [], uuidV7()), { headers }));
    expect(await closed.next("invalidation")).toContain('"cursor"'); await closed.close();
    const next = new DocumentCore(); next.insertText("second change", uuidV7);
    await f.run((s) => s.exchangeDocument(f.workspaceId, f.documentId, { generation: document.generation, vector: next.vector(), update: next.checkpoint() })); next.destroy();
    expect(await replacement.next("document")).toContain(`${document.generation}:2`);
  } finally { await first.close(); await replacement?.close(); }
});

it("binds subscriptions to the authenticated user, rejects malformed targets and stops after permission revocation", async () => {
  const f = await setup(), app = createApp({ config: f.config, authStore: f.store });
  const headers = { "X-Forwarded-Email": `${outsider.userId}@example.com` }, target = { workspaceId: f.workspaceId, meetingId: f.meetingId };
  expect((await app.request(notificationURL(owner.userId, [target]), { headers })).status).toBe(409);
  const malformed = `/api/v1/events?${new URLSearchParams({ user: encodeId("user", outsider.userId), tab: uuidV7().replaceAll("-", ""), notes: '[{"workspaceId":"invalid","meetingId":"invalid"}]' })}`;
  expect((await app.request(malformed, { headers })).status).toBe(400);
  const denied = notificationReader(await app.request(notificationURL(outsider.userId, [target]), { headers }));
  expect(await denied.next("document")).toContain('"unavailable":true'); await denied.close();
  const db = new DatabaseSync(f.path);
  db.prepare("INSERT INTO workspace_permissions(workspace_id, principal_type, principal_id, role, granted_by_user_id) VALUES (?, 'user', ?, 'viewer', ?)").run(f.workspaceId, outsider.userId, owner.userId);
  const allowed = notificationReader(await app.request(notificationURL(outsider.userId, [target]), { headers }));
  try {
    expect(await allowed.next("document")).toContain('"cursor":"absent"');
    db.prepare("DELETE FROM workspace_permissions WHERE workspace_id = ? AND principal_id = ?").run(f.workspaceId, outsider.userId);
    expect(await allowed.next("document")).toContain('"unavailable":true');
  } finally { await allowed.close(); db.close(); }
});

it("publishes domain hints only after successful commits, never after rolled-back transactions", async () => {
  const f = await setup(), published = vi.spyOn(f.store.syncEvents!, "publish");
  await expect(f.sync.commitTransaction(owner, { id: uuidV7(), schemaVersion: 3, workspaceId: f.workspaceId, createdAt: new Date().toISOString(), operations: [
    { id: uuidV7(), entity: "meeting", action: "update", entityId: f.meetingId, baseRevision: 1, data: { name: "rolled back", projectId: null, status: "READY", duration: null, recordingStartedAt: null, updatedAt: new Date().toISOString() } },
    { id: uuidV7(), entity: "meeting", action: "update", entityId: uuidV7(), baseRevision: 1, data: { name: "missing", projectId: null, status: "READY", duration: null, recordingStartedAt: null, updatedAt: new Date().toISOString() } },
  ] })).rejects.toThrow();
  expect(published).not.toHaveBeenCalled();
  await f.sync.commitTransaction(owner, { id: uuidV7(), schemaVersion: 3, workspaceId: f.workspaceId, createdAt: new Date().toISOString(), operations: [
    { id: uuidV7(), entity: "meeting", action: "update", entityId: f.meetingId, baseRevision: 1, data: { name: "committed", projectId: null, status: "READY", duration: null, recordingStartedAt: null, updatedAt: new Date().toISOString() } },
  ] });
  expect(published).toHaveBeenCalledWith("domain");
  const db = new DatabaseSync(f.path);
  try { expect(db.prepare("SELECT name FROM meetings WHERE meeting_id = ?").get(f.meetingId)?.name).toBe("committed"); }
  finally { db.close(); published.mockRestore(); }
});
