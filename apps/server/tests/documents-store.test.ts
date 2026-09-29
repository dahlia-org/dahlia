import { afterEach, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import * as Y from "yjs";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { MeetingSyncService } from "../src/sync/service";
import { uuidV7 } from "../src/id";
import { seedHeaderIdentity, testOrganizationID, testUserID } from "./public-test-client";
import { DocumentCore, documentFragment } from "../src/documents/core";
import { encryptionConfig, encodeBase64 } from "../src/encryption/crypto";
import type { Identity } from "../src/auth/identity";
import type { DocumentStore } from "../src/documents/store";
import { SummaryService, summaryJobResponse } from "../src/summary/service";
import { createApp } from "../src/app";
import { encodeId } from "../src/typeid";
import { documentRecoveryPageBytes, documentResponseLimit } from "../src/documents/model";

const owner: Identity = { userId: testUserID("document-owner"), source: "header" };
const outsider: Identity = { userId: testUserID("document-outsider"), source: "header" };
const cleanups: (() => Promise<void>)[] = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); });
async function setup(encrypted = false) {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-document-")), path = join(directory, "db.sqlite");
  const config = { authProvider: "header" as const, authHeader: "X-Forwarded-Email", databaseType: "sqlite" as const, databaseUrl: `file:${path}`,
    baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1_048_576,
    encryption: encryptionConfig({ DAHLIA_ENCRYPTION_ACTIVE_KEY_ID: "1", DAHLIA_ENCRYPTION_MASTER_KEY_1: encodeBase64(new Uint8Array(32).fill(7)) }),
  };
  const store = createNodeApplicationStore(config);
  cleanups.push(async () => { await store.close?.(); rmSync(directory, { recursive: true, force: true }); });
  await store.migrate(); await seedHeaderIdentity(store, path, owner); await seedHeaderIdentity(store, path, outsider);
  const workspaceId = uuidV7(), meetingId = uuidV7(), sync = new MeetingSyncService(store.sync);
  await sync.commitTransaction(owner, { id: uuidV7(), schemaVersion: 3, workspaceId, createdAt: new Date().toISOString(), operations: [
    { id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null, data: { organizationId: testOrganizationID, name: "Documents", encryption: encrypted ? "server" : "none", createdAt: new Date().toISOString() } },
    { id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: { name: "Meeting", projectId: null, description: "", status: "READY", duration: null, recordingStartedAt: null, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } },
  ] });
  const run = <T>(action: (store: DocumentStore) => Promise<T>, identity = owner) => store.sync.withIdentity(identity, action);
  return { store, sync, workspaceId, meetingId, run, path, config };
}

it.each([false, true])("pages retained recovery bodies without truncation (encrypted=%s)", async (encrypted) => {
  const f = await setup(encrypted);
  await f.run((s) => s.initializeDocument(f.workspaceId, f.meetingId));
  const records = ["\u0001".repeat(1_100_000), ...Array<string>(6).fill("日本語".repeat(100))].map((text) => ({
    id: uuidV7(), reason: "concurrent_delete" as const, blocks: [{ id: uuidV7(), type: "paragraph", text }],
  })).sort((a, b) => a.id.localeCompare(b.id));
  for (const record of records) await f.run((s) => s.saveDocumentRecovery(f.workspaceId, f.meetingId, record));
  const received = [];
  let after: string | undefined, pages = 0;
  do {
    const page = await f.run((s) => s.documentRecoveries(f.workspaceId, f.meetingId, after));
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
  await f.run((s) => s.initializeDocument(f.workspaceId, f.meetingId));
  expect((await f.run((s) => s.listDocuments(f.workspaceId))).items).toHaveLength(1);
  const db = new DatabaseSync(f.path);
  try {
    db.prepare("UPDATE workspaces SET deleting_at = ? WHERE workspace_id = ?").run(Date.now(), f.workspaceId);
    expect((await f.run((s) => s.listDocuments(f.workspaceId))).items).toEqual([]);
    await expect(f.run((s) => s.getDocument(f.workspaceId, f.meetingId))).rejects.toThrow("document_unavailable");
    db.prepare("UPDATE workspaces SET deleting_at = NULL WHERE workspace_id = ?").run(f.workspaceId);
    expect((await f.run((s) => s.listDocuments(f.workspaceId))).items).toHaveLength(1);
  } finally { db.close(); }
});

it("reclaims departed editors' expired presence without removing live sessions or other Workspaces", async () => {
  const f = await setup(), other = { workspaceId: uuidV7(), meetingId: uuidV7() };
  await f.run((s) => s.initializeDocument(f.workspaceId, f.meetingId));
  const expired = uuidV7(), active = uuidV7();
  await f.run((s) => s.documentPresence(f.workspaceId, f.meetingId, expired));
  await f.run((s) => s.documentPresence(f.workspaceId, f.meetingId, active));
  const db = new DatabaseSync(f.path);
  try {
    // Same database: a separate Workspace is intentionally outside this cleanup boundary.
    await f.sync.commitTransaction(owner, { id: uuidV7(), schemaVersion: 3, workspaceId: other.workspaceId, createdAt: new Date().toISOString(), operations: [
      { id: uuidV7(), entity: "workspace", action: "create", entityId: other.workspaceId, baseRevision: null,
        data: { organizationId: testOrganizationID, name: "Other", encryption: "none", createdAt: new Date().toISOString() } },
      { id: uuidV7(), entity: "meeting", action: "create", entityId: other.meetingId, baseRevision: null,
        data: { name: "Other", projectId: null, description: "", status: "READY", duration: null, recordingStartedAt: null, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } },
    ] });
    await f.run((s) => s.initializeDocument(other.workspaceId, other.meetingId));
    const untouched = uuidV7();
    await f.run((s) => s.documentPresence(other.workspaceId, other.meetingId, untouched));
    db.prepare("UPDATE document_presence SET expires_at = ? WHERE id IN (?, ?)").run(Date.now() - 1_000, expired, untouched);
    db.prepare("INSERT INTO workspace_permissions(workspace_id, principal_type, principal_id, role, granted_by_user_id) VALUES (?, 'user', ?, 'editor', ?)").run(f.workspaceId, outsider.userId, owner.userId);
    expect(await f.run((s) => s.documentPresence(f.workspaceId, f.meetingId), outsider)).toHaveLength(1);
    expect(db.prepare("SELECT id FROM document_presence ORDER BY id").all().map((row) => row.id)).toEqual([active, untouched].sort());
  } finally { db.close(); }
});

it("accepts a whole valid state through the dedicated HTTP budget", async () => {
  const f = await setup(), core = new DocumentCore();
  try {
    const text = Array<string>(4_000).fill("語".repeat(499)).join("\n");
    core.insertText(text, uuidV7);
    const update = core.checkpoint();
    expect(update.length).toBeGreaterThan(8 * 1024 * 1024);
    const document = await f.run((s) => s.initializeDocument(f.workspaceId, f.meetingId));
    const app = createApp({ config: f.config, authStore: f.store });
    const response = await app.request(`/api/v1/workspaces/${encodeId("workspace", f.workspaceId)}/documents/${encodeId("document", f.meetingId)}/sync`, {
      method: "POST", headers: { "content-type": "application/json", "X-Forwarded-Email": `${owner.userId}@example.com` },
      body: JSON.stringify({ generation: document.generation, vector: core.vector(), update }),
    });
    expect(response.status).toBe(200);
    const db = new DatabaseSync(f.path);
    try { expect(db.prepare("SELECT text FROM documents WHERE id = ?").get(f.meetingId)?.text).toBe(text); }
    finally { db.close(); }
  } finally { core.destroy(); }
});

it("initializes once, merges pending edits, replays idempotently and survives compaction", async () => {
  const f = await setup(), seed = new DocumentCore(); seed.insertText("note", uuidV7);
  expect(await f.run((s) => s.getDocument(f.workspaceId, f.meetingId))).toBeNull();
  const doc = await f.run((s) => s.initializeDocument(f.workspaceId, f.meetingId, seed.checkpoint()));
  expect((await f.run((s) => s.initializeDocument(f.workspaceId, f.meetingId, seed.checkpoint()))).revision).toBe(doc.revision);
  const independent = new DocumentCore(); independent.insertText("note", uuidV7);
  await expect(f.run((s) => s.initializeDocument(f.workspaceId, f.meetingId, independent.checkpoint()))).rejects.toThrow("document_already_initialized");
  const a = new DocumentCore(doc.checkpoint), b = new DocumentCore(doc.checkpoint);
  const edit = (core: DocumentCore, value: string) => ((core.document.getXmlFragment(documentFragment).get(0) as Y.XmlElement).get(0) as Y.XmlText).insert(0, value);
  edit(a, "A"); edit(b, "B");
  const exchange = (core: DocumentCore) => f.run((s) => s.exchangeDocument(f.workspaceId, f.meetingId, { generation: doc.generation, vector: core.vector(), update: core.checkpoint() }));
  await exchange(a); b.apply((await exchange(b)).update); a.apply((await exchange(a)).update);
  expect(a.projection()).toEqual(b.projection());
  const before = await exchange(a); expect((await exchange(a)).revision).toBe(before.revision);
  for (let i = 0; i < 35; i++) { edit(a, "x"); a.apply((await exchange(a)).update); }
  expect((await f.run((s) => s.getDocument(f.workspaceId, f.meetingId)))?.text).toBe(a.projection().text);
  const db = new DatabaseSync(f.path);
  try { expect(Number(db.prepare("SELECT count(*) AS n FROM document_updates").get()!.n)).toBeLessThan(32); } finally { db.close(); }
});

it("requires explicit meeting restoration and a fresh generation before merging offline edits", async () => {
  const f = await setup(), core = new DocumentCore(); core.insertText("seed", uuidV7);
  try {
    const initial = await f.run((s) => s.initializeDocument(f.workspaceId, f.meetingId, core.checkpoint()));
    ((core.document.getXmlFragment(documentFragment).get(0) as Y.XmlElement).get(0) as Y.XmlText).insert(4, " offline");
    const request = { generation: initial.generation, vector: core.vector(), update: core.checkpoint() };
    const lifecycle = (action: "delete" | "restore", baseRevision: number) => f.sync.commitTransaction(owner, {
      id: uuidV7(), schemaVersion: 3, workspaceId: f.workspaceId, createdAt: new Date().toISOString(), operations: [
        { id: uuidV7(), entity: "meeting", action, entityId: f.meetingId, baseRevision, data: {} },
      ],
    });
    await lifecycle("delete", 1);
    await expect(f.run((s) => s.exchangeDocument(f.workspaceId, f.meetingId, request))).rejects.toThrow("document_unavailable");
    await expect(f.run((s) => s.getDocument(f.workspaceId, f.meetingId))).rejects.toThrow("document_unavailable");
    expect(await f.store.sync.withIdentity(owner, (s) => s.getMeeting(f.workspaceId, f.meetingId))).toBeNull();
    await lifecycle("restore", 2);
    await expect(f.run((s) => s.exchangeDocument(f.workspaceId, f.meetingId, request))).rejects.toThrow("document_generation_changed");
    const restored = await f.run((s) => s.getDocument(f.workspaceId, f.meetingId));
    expect(restored?.generation).not.toBe(initial.generation);
    expect(restored?.text).toBe("seed");
    await f.run((s) => s.exchangeDocument(f.workspaceId, f.meetingId, { ...request, generation: restored!.generation }));
    expect((await f.run((s) => s.getDocument(f.workspaceId, f.meetingId)))?.text).toBe("seed offline");
  } finally { core.destroy(); }
});

it("authorizes all document paths and encrypts checkpoints, updates, recovery and snapshots", async () => {
  const f = await setup(true), core = new DocumentCore(); core.insertText("PRIVATE_NOTE", uuidV7);
  const doc = await f.run((s) => s.initializeDocument(f.workspaceId, f.meetingId, core.checkpoint()));
  await expect(f.run((s) => s.getDocument(f.workspaceId, f.meetingId), outsider)).rejects.toThrow("document_unavailable");
  const service = new SummaryService(f.store.sync, [{ id: "transcript", captureSettings: () => ({ model: "test", reasoningEffort: "medium", detail: "medium" }),
    version: async () => "v1", generate: async () => { throw new Error("unused"); } }]);
  const job = await service.start(owner, f.workspaceId, f.meetingId, { id: uuidV7() });
  expect(job.notesSnapshot).toMatchObject({ documentId: f.meetingId, text: "PRIVATE_NOTE", revision: 1 });
  expect(JSON.stringify(summaryJobResponse(job))).not.toContain("PRIVATE_NOTE");
  core.document.getXmlFragment(documentFragment).delete(0, 1);
  await f.run((s) => s.exchangeDocument(f.workspaceId, f.meetingId, { generation: doc.generation, vector: core.vector(), update: core.checkpoint() }));
  expect((await f.run((s) => s.documentRecoveries(f.workspaceId, f.meetingId))).items[0]?.blocks[0]?.text).toBe("PRIVATE_NOTE");
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
