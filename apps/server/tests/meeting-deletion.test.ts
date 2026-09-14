import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { createNodeApplicationStore } from "../src/auth/node-store";
import type { AppConfig } from "../src/config";
import type { Identity } from "../src/auth/identity";
import type { SyncTransactionOperation } from "../src/sync/types";
import { MeetingSyncService } from "../src/sync/service";
import { uuidV7 } from "../src/id";
import { fileStorageKey } from "../src/files/model";
import { encodeBase64, encryptionConfig } from "../src/encryption/crypto";
import { LocalObjectStorage } from "../src/storage/local";
import { createContractApp } from "./api-test-client";
import { seedHeaderIdentity, testOrganizationID, testUserID } from "./public-test-client";

const owner: Identity = { userId: testUserID("trash-owner"), source: "header" };
const editor: Identity = { userId: testUserID("trash-editor"), source: "header" };
const viewer: Identity = { userId: testUserID("trash-viewer"), source: "header" };
const outsider: Identity = { userId: testUserID("trash-outsider"), source: "header" };
const cleanups: Array<() => Promise<void>> = [];
const day = 86_400_000;
afterEach(async () => {
  vi.useRealTimers();
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

function body(workspaceId: string, operations: Omit<SyncTransactionOperation, "id">[]) {
  return { schemaVersion: 3, id: uuidV7(), workspaceId, createdAt: new Date().toISOString(),
    operations: operations.map((operation) => ({ id: uuidV7(), ...operation })) };
}
const meetingData = () => ({ projectId: null, name: "Recoverable meeting", description: "Notes", status: "READY", duration: null,
  recordingStartedAt: null, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() });

async function setup(encrypted = false, storageEnabled = false) {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-meeting-trash-"));
  const path = join(directory, "test.sqlite");
  const config: AppConfig = { authProvider: "header", authHeader: "X-Forwarded-Email", baseUrl: "https://dahlia.example",
    databaseType: "sqlite", databaseUrl: `file:${path}`, oauthRedirectUris: [], maxRequestBytes: 1024 * 1024,
    ...(encrypted ? { encryption: encryptionConfig({ DAHLIA_ENCRYPTION_MASTER_KEY_1: encodeBase64(new Uint8Array(32).fill(1)), DAHLIA_ENCRYPTION_ACTIVE_KEY_ID: "1" }) } : {}) };
  const store = createNodeApplicationStore(config);
  await store.migrate();
  for (const identity of [owner, editor, viewer, outsider]) await seedHeaderIdentity(store, path, identity);
  const raw = new DatabaseSync(path);
  raw.exec("PRAGMA foreign_keys = ON");
  cleanups.push(async () => { raw.close(); await store.close?.(); rmSync(directory, { recursive: true, force: true }); });
  const storage = storageEnabled ? new LocalObjectStorage(join(directory, "objects")) : undefined;
  const service = new MeetingSyncService(store.sync, storage, undefined, undefined, undefined, undefined, false);
  const workspaceId = uuidV7();
  const meetingId = uuidV7();
  const create = body(workspaceId, [{ entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null,
    data: { organizationId: testOrganizationID, name: "Recovery", encryption: encrypted ? "server" : "none", createdAt: new Date().toISOString() } },
    { entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: meetingData() }]);
  await service.commitTransaction(owner, create);
  await store.sync.withIdentity(owner, async (scoped) => {
    await scoped.putPermission(workspaceId, "user", editor.userId, "editor");
    await scoped.putPermission(workspaceId, "user", viewer.userId, "viewer");
  });
  const change = (action: "delete" | "restore", revision: number, identity = owner) => service.commitTransaction(identity,
    body(workspaceId, [{ entity: "meeting", action, entityId: meetingId, baseRevision: revision, data: {} }]));
  const grace = (days: number, revision = 1, identity = owner) => service.commitTransaction(identity,
    body(workspaceId, [{ entity: "workspace", action: "update", entityId: workspaceId, baseRevision: revision, data: { name: "Recovery", meetingDeletionGraceDays: days } }]));
  const trashTime = (time: number) => raw.prepare("UPDATE meetings SET deleted_at = ? WHERE meeting_id = ?").run(time, meetingId);
  const file = () => {
    const fileId = uuidV7();
    raw.prepare("INSERT INTO files(file_id, workspace_id, uri, size, content_type, checksum, name, metadata, active, uploaded_at, revision) VALUES (?, ?, ?, 1, 'image/png', ?, 'capture.png', ?, 1, ?, 1)")
      .run(fileId, workspaceId, `/files/${fileId}/original`, `SHA-256:${"a".repeat(64)}`, '{"source":"screenshot","ocr_text":"Retained image text"}', Date.now());
    return fileId;
  };
  const attach = (fileId: string, parent = meetingId) => {
    const id = uuidV7();
    raw.prepare("INSERT INTO meeting_attachments(id, workspace_id, meeting_id, file_id, captured_at) VALUES (?, ?, ?, ?, ?)")
      .run(id, workspaceId, parent, fileId, Date.now());
    return id;
  };
  return { config, store, raw, service, workspaceId, meetingId, change, grace, trashTime, file, attach, storage };
}

describe("meeting trash", () => {
  it.each([false, true])("retains canonical content and restores it without rewinding revisions (encrypted: %s)", async (encrypted) => {
    const { service, store, raw, workspaceId, meetingId, change, trashTime } = await setup(encrypted);
    expect(await service.getWorkspace(owner, workspaceId)).toMatchObject({ meetingDeletionGraceDays: 7 });
    await service.commitTransaction(owner, body(workspaceId, [{ entity: "summary", action: "upsert", entityId: meetingId, baseRevision: 0,
      data: { title: "Saved summary", document: "Original summary text", createdAt: new Date().toISOString() } }]));
    const snapshot = await service.listSnapshot(owner, workspaceId);
    await change("delete", 1, editor);
    expect(raw.prepare("SELECT deleted_at FROM meetings WHERE meeting_id = ?").get(meetingId)?.deleted_at).toEqual(expect.any(Number));
    expect(raw.prepare("SELECT count(*) AS n FROM summaries WHERE meeting_id = ?").get(meetingId)?.n).toBe(1);
    expect(raw.prepare("SELECT count(*) AS n FROM jobs_storage_delete").get()?.n).toBe(0);
    expect(await service.getMeetingById(owner, meetingId)).toBeNull();
    expect((await service.listMeetings(owner, workspaceId)).items).toEqual([]);
    expect((await service.listMeetings(owner, workspaceId, "Recoverable")).items).toEqual([]);
    expect((await service.listSnapshot(owner, workspaceId)).items.map((item) => item.entity)).toEqual(["workspace"]);
    const deletion = await service.listChanges(owner, workspaceId, snapshot.startCursor);
    expect(deletion.items.filter((item) => item.entity !== "workspace").every((item) => item.action === "delete" && item.record === null)).toBe(true);
    expect((await service.listDeletedMeetings(viewer, workspaceId)).items).toEqual([
      expect.objectContaining({ meetingId, name: "Recoverable meeting", revision: 2 }),
    ]);
    await expect(service.commitTransaction(owner, body(workspaceId, [{ entity: "meeting", action: "create", entityId: meetingId,
      baseRevision: null, data: meetingData() }]))).rejects.toMatchObject({ code: "meeting_deleted" });
    await expect(service.commitTransaction(owner, body(workspaceId, [{ entity: "meeting", action: "update", entityId: meetingId,
      baseRevision: 1, data: { ...meetingData(), createdAt: undefined } }]))).rejects.toThrow();
    await expect(store.sync.withIdentity(owner, (scoped) => scoped.putTranscriptChunk(workspaceId, meetingId, uuidV7(), 0, "a".repeat(64), [], []))).resolves.toBe(false);
    await expect(service.commitTransaction(owner, body(workspaceId, [{ entity: "summary", action: "upsert", entityId: meetingId, baseRevision: 1,
      data: { title: "Late result", document: "must not write", createdAt: new Date().toISOString() } }]))).rejects.toMatchObject({ code: "revision_conflict" });
    trashTime(Date.now() - 100 * day);
    await expect(change("restore", 1)).rejects.toMatchObject({ code: "revision_conflict" });
    const request = body(workspaceId, [{ entity: "meeting", action: "restore", entityId: meetingId, baseRevision: 2, data: {} }]);
    const restored = await service.commitTransaction(editor, request);
    expect(await service.commitTransaction(editor, request)).toEqual(restored);
    expect(await service.getMeetingById(owner, meetingId)).toMatchObject({ name: "Recoverable meeting", revision: 3, summaryDocument: "Original summary text" });
    expect((await service.listDeletedMeetings(owner, workspaceId)).items).toEqual([]);
    const delta = await service.listChanges(owner, workspaceId, deletion.cursor);
    expect(delta.items.map((item) => [item.entity, item.action])).toEqual([["meeting", "upsert"], ["summary", "upsert"], ["transcript", "upsert"]]);
    expect(delta.items[0]?.revision).toBe(3);
    await change("delete", 3);
    expect(raw.prepare("SELECT deleted_at FROM meetings WHERE meeting_id = ?").get(meetingId)?.deleted_at).toBeGreaterThan(Date.now() - 1000);
  });

  it("hides retained attachments and recordings, then republishes every child on restore", async () => {
    const { service, store, raw, workspaceId, meetingId, change, file, attach } = await setup();
    const fileId = file();
    const attachmentId = attach(fileId);
    const removedFileId = file();
    const removedAttachmentId = attach(removedFileId);
    await service.commitTransaction(owner, body(workspaceId, [
      { entity: "meeting_attachment", action: "delete", entityId: removedAttachmentId, baseRevision: 1, data: {} },
      { entity: "file", action: "delete", entityId: removedFileId, baseRevision: 1, data: {} },
    ]));
    const transcriptId = uuidV7();
    const sessionId = uuidV7();
    raw.prepare("INSERT INTO transcripts(id, meeting_id, version, sync_revision, started_at, ended_at, created_at) VALUES (?, ?, 1, 1, ?, ?, ?)")
      .run(transcriptId, meetingId, Date.now(), Date.now(), Date.now());
    raw.prepare("INSERT INTO transcript_segments(transcript_id, segment_id, started_at, text) VALUES (?, ?, ?, 'Retained speech')").run(transcriptId, uuidV7(), Date.now());
    raw.prepare("UPDATE meetings SET transcript_revision = 1 WHERE meeting_id = ?").run(meetingId);
    raw.prepare("INSERT INTO recordings(session_id, meeting_id, number, started_at, ended_at, audio, revision, created_at, updated_at) VALUES (?, ?, 1, ?, ?, '{}', 1, ?, ?)")
      .run(sessionId, meetingId, Date.now(), Date.now(), Date.now(), Date.now());
    const before = await service.listSnapshot(owner, workspaceId);
    await change("delete", 1);
    await store.sync.withIdentity(owner, async (scoped) => {
      expect(await scoped.getFile(fileId, true)).toBeNull();
      expect(await scoped.getScreenshot(workspaceId, meetingId, attachmentId, true)).toBeNull();
      expect(await scoped.listMeetingAttachments(workspaceId, meetingId, undefined, 200)).toEqual([]);
      expect(await scoped.getRecording(meetingId, 1)).toBeNull();
      expect(await scoped.listRecordings(meetingId, 0, 200)).toEqual([]);
      expect(await scoped.getTranscript(workspaceId, meetingId)).toBeNull();
    });
    expect((await service.listFiles(owner, workspaceId)).items).toEqual([]);
    expect((await service.listSnapshot(owner, workspaceId)).items.map((item) => item.entity)).toEqual(["workspace"]);
    const removed = await service.listChanges(owner, workspaceId, before.startCursor);
    expect(removed.items.filter((item) => item.action === "delete").map((item) => item.entity)).toEqual(["meeting", "summary", "transcript", "file", "meeting_attachment", "recording"]);
    await change("restore", 2);
    expect((await service.listChanges(owner, workspaceId, removed.cursor)).items.map((item) => item.action)).toEqual(Array(6).fill("upsert"));
    await store.sync.withIdentity(owner, async (scoped) => {
      expect(await scoped.getFile(fileId, true)).not.toBeNull();
      expect(await scoped.getFile(removedFileId, true)).toBeNull();
      expect(await scoped.listTranscript(workspaceId, meetingId, 10)).toEqual([expect.objectContaining({ text: "Retained speech" })]);
      expect(await scoped.listMeetingAttachments(workspaceId, meetingId, undefined, 200)).toHaveLength(1);
    });
  });

  it("invalidates a shared file when its last live meeting detaches it", async () => {
    const { service, workspaceId, change, file, attach } = await setup();
    const fileId = file();
    attach(fileId);
    const otherMeeting = uuidV7();
    await service.commitTransaction(owner, body(workspaceId, [{ entity: "meeting", action: "create", entityId: otherMeeting, baseRevision: null, data: meetingData() }]));
    const liveAttachment = attach(fileId, otherMeeting);
    const deleted = await change("delete", 1);
    expect((await service.listFiles(owner, workspaceId)).items).toHaveLength(1);
    await service.commitTransaction(owner, body(workspaceId, [{ entity: "meeting_attachment", action: "delete", entityId: liveAttachment, baseRevision: 1, data: {} }]));
    expect((await service.listFiles(owner, workspaceId)).items).toEqual([]);
    expect((await service.listChanges(owner, workspaceId, deleted.cursor)).items)
      .toEqual(expect.arrayContaining([expect.objectContaining({ entity: "file", entityId: fileId, action: "delete", record: null })]));
    await expect(service.commitTransaction(owner, body(workspaceId, [{ entity: "meeting_attachment", action: "upsert", entityId: uuidV7(), baseRevision: null,
      data: { meetingId: otherMeeting, fileId, capturedAt: null, sessionId: null, createdAt: new Date().toISOString() } }])))
      .rejects.toMatchObject({ code: "file_not_found" });
    await change("restore", 2);
    expect((await service.listFiles(owner, workspaceId)).items).toHaveLength(1);
  });

  it("uses the current grace period and atomically purges only unreferenced images", async () => {
    const { service, store, raw, workspaceId, meetingId, change, grace, trashTime, file, attach } = await setup();
    const shared = file(); const exclusive = file(); const independent = file();
    attach(shared); attach(exclusive);
    const otherMeeting = uuidV7();
    await service.commitTransaction(owner, body(workspaceId, [{ entity: "meeting", action: "create", entityId: otherMeeting, baseRevision: null, data: meetingData() }]));
    attach(shared, otherMeeting);
    await change("delete", 1);
    const now = Date.now();
    trashTime(now - 8 * day);
    await grace(90);
    expect(await store.sync.purgeDeletedMeetings(workspaceId, new Date(now))).toBe(0);
    await grace(7, 2);
    expect((await service.listFiles(owner, workspaceId)).items.map((item) => item.id).sort()).toEqual([shared, independent].sort());
    expect(await store.sync.purgeDeletedMeetings(workspaceId, new Date(now))).toBe(1);
    expect(raw.prepare("SELECT meeting_id FROM meetings WHERE meeting_id = ?").get(meetingId)).toBeUndefined();
    expect(raw.prepare("SELECT file_id FROM files WHERE file_id = ?").get(exclusive)).toBeUndefined();
    expect(raw.prepare("SELECT file_id FROM files WHERE file_id = ?").get(shared)).toBeDefined();
    expect(raw.prepare("SELECT file_id FROM files WHERE file_id = ?").get(independent)).toBeDefined();
    expect(raw.prepare("SELECT storage_key FROM jobs_storage_delete").all()).toEqual([{ storage_key: fileStorageKey(exclusive) }]);
    await expect(change("restore", 2)).rejects.toMatchObject({ code: "meeting_not_deleted" });
    expect(await store.sync.purgeDeletedMeetings(workspaceId, new Date(now))).toBe(0);
  });

  it.each([1, 7, 90])("purges at the %i-day boundary, including without object storage", async (days) => {
    const { service, store, raw, workspaceId, meetingId, change, grace, trashTime } = await setup();
    await grace(days);
    await change("delete", 1);
    const now = Date.now();
    trashTime(now - days * day + 1);
    expect(await store.sync.purgeDeletedMeetings(workspaceId, new Date(now))).toBe(0);
    trashTime(now - days * day);
    await service.runStorageMaintenance();
    expect(raw.prepare("SELECT meeting_id FROM meetings WHERE meeting_id = ?").get(meetingId)).toBeUndefined();
  });

  it("validates settings and enforces permissions for trash reads, restore and settings", async () => {
    const { service, workspaceId, change, grace } = await setup();
    for (const days of [0, 91, 1.5, -1]) await expect(grace(days)).rejects.toMatchObject({ code: "invalid_sync_operation" });
    await expect(grace(30, 1, editor)).rejects.toMatchObject({ code: "workspace_admin_required" });
    await change("delete", 1);
    await expect(change("restore", 2, viewer)).rejects.toThrow();
    await expect(change("restore", 2, outsider)).rejects.toThrow();
    await expect(service.listDeletedMeetings(outsider, workspaceId)).rejects.toMatchObject({ code: "workspace_not_found" });
    await expect(service.listDeletedMeetings(owner, workspaceId, "invalid")).rejects.toThrow();
    expect((await service.listDeletedMeetings(viewer, workspaceId)).items).toHaveLength(1);
    await expect(service.commitTransaction(owner, body(workspaceId, [{ entity: "workspace", action: "reset", entityId: workspaceId, baseRevision: 1, data: {} }])))
      .rejects.toMatchObject({ code: "workspace_not_empty" });
  });

  it("rolls back cleanup and its storage queue together on failure", async () => {
    const { store, raw, workspaceId, meetingId, change, trashTime, file, attach } = await setup();
    attach(file());
    await change("delete", 1);
    trashTime(Date.now() - 8 * day);
    raw.exec("CREATE TRIGGER abort_meeting_cleanup BEFORE DELETE ON meetings BEGIN SELECT RAISE(ABORT, 'test cleanup failure'); END");
    await expect(store.sync.purgeDeletedMeetings(workspaceId, new Date())).rejects.toThrow();
    expect(raw.prepare("SELECT deleted_at FROM meetings WHERE meeting_id = ?").get(meetingId)).toBeDefined();
    expect(raw.prepare("SELECT count(*) AS n FROM jobs_storage_delete").get()?.n).toBe(0);
    raw.exec("DROP TRIGGER abort_meeting_cleanup");
    expect(await store.sync.purgeDeletedMeetings(workspaceId, new Date())).toBe(1);
  });

  it("keeps the durable storage deletion job when object deletion fails, then retries", async () => {
    const { service, store, raw, workspaceId, change, trashTime, file, attach, storage } = await setup(false, true);
    const fileId = file(); attach(fileId);
    const remove = vi.spyOn(storage!, "delete").mockRejectedValue(new Error("storage offline"));
    await change("delete", 1);
    expect(remove).not.toHaveBeenCalled();
    trashTime(Date.now() - 8 * day);
    await service.runStorageMaintenance();
    expect((await service.listDeletedMeetings(owner, workspaceId)).items).toEqual([]);
    expect(raw.prepare("SELECT storage_key FROM jobs_storage_delete").get()).toEqual({ storage_key: fileStorageKey(fileId) });
    remove.mockResolvedValue(undefined);
    raw.prepare("UPDATE jobs_storage_delete SET available_at = ?").run(Date.now() - 1);
    await service.runStorageMaintenance();
    expect(raw.prepare("SELECT count(*) AS n FROM jobs_storage_delete").get()?.n).toBe(0);
    expect(await store.sync.purgeDeletedMeetings(workspaceId, new Date())).toBe(0);
  });

  it("does not revive the recording indicator from a session predating deletion", async () => {
    const { raw, service, workspaceId, meetingId, change } = await setup();
    raw.prepare(`INSERT INTO meeting_events(id, owner_user_id, workspace_id, meeting_id, kind, occurred_at, received_at, session_id)
      VALUES (?, ?, ?, ?, 'recording_started', ?, ?, ?)`)
      .run(uuidV7(), owner.userId, workspaceId, meetingId, Date.now() - day, Date.now() - day, uuidV7());
    expect(await service.getMeetingById(owner, meetingId)).toMatchObject({ isRecording: true });
    await change("delete", 1);
    await change("restore", 2);
    expect(await service.getMeetingById(owner, meetingId)).toMatchObject({ isRecording: false });
    expect(raw.prepare("SELECT count(*) AS n FROM meeting_events WHERE kind = 'recording_started'").get()?.n).toBe(1);
  });

  it("cancels another requester's active job without reviving it on restore", async () => {
    const { raw, workspaceId, meetingId, change } = await setup();
    raw.prepare(`INSERT INTO jobs_summary(id, workspace_id, meeting_id, owner_user_id, method, settings,
      output_language, status, created_at, available_at, claimed_at, lease_expires_at, summary_revision, input_version, request_hash)
      VALUES (?, ?, ?, ?, 'transcript', '{}', 'en', 'processing', ?, ?, ?, ?, 0, '1', 'test')`)
      .run(uuidV7(), workspaceId, meetingId, editor.userId, Date.now(), Date.now(), Date.now(), Date.now() + day);
    await change("delete", 1);
    await change("restore", 2);
    expect(raw.prepare("SELECT status, claimed_at, lease_expires_at FROM jobs_summary").get())
      .toEqual({ status: "cancelled", claimed_at: null, lease_expires_at: null });
  });

  it("serves a validated trash API with current Workspace permissions", async () => {
    const { config, store, service, workspaceId, meetingId, change } = await setup();
    await change("delete", 1);
    const app = createContractApp({ config, authStore: store, syncService: service });
    const response = await app.fetch(new Request(`${config.baseUrl}/api/v1/workspaces/${workspaceId}/trash/meetings`, {
      headers: { "X-Forwarded-Email": `${owner.userId}@example.com` },
    }));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ items: [{ meetingId, revision: 2 }], nextCursor: null });
  });
});
