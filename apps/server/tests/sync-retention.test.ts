import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it, vi } from "vitest";

import { createApp } from "../src/app";
import { createNodeApplicationStore, type NodeApplicationStore } from "../src/auth/node-store";
import type { Identity } from "../src/auth/identity";
import type { AppConfig } from "../src/config";
import { pruneSyncHistory } from "../src/sync/retention";
import { TextContentDigest } from "../src/sync/text-content";
import { MeetingSyncService } from "../src/sync/service";
import { decodeSyncCursor, SYNC_HISTORY_RETENTION_MS, SYNC_SNAPSHOT_PAGE_BYTES } from "../src/sync/store";
import type { SyncTransactionOperation } from "../src/sync/types";
import { receipt as receiptSchema } from "../src/api/schemas";

const owner: Identity = { userId: "retention-owner", workspaceId: "personal:retention-owner", source: "header" };
const member: Identity = { userId: "retention-member", workspaceId: "personal:retention-member", source: "header" };
const resources: { directory: string; store: NodeApplicationStore; raw: DatabaseSync }[] = [];

afterEach(async () => {
  vi.restoreAllMocks();
  for (const resource of resources.splice(0)) {
    resource.raw.close();
    await resource.store.close?.();
    rmSync(resource.directory, { recursive: true, force: true });
  }
});

function id() {
  const value = crypto.randomUUID();
  return `${value.slice(0, 14)}7${value.slice(15)}`;
}

function body(vaultId: string, operations: Omit<SyncTransactionOperation, "id">[]) {
  return {
    schemaVersion: 2, id: id(), vaultId, createdAt: new Date().toISOString(),
    operations: operations.map((operation) => ({ id: id(), ...operation })),
  };
}

async function setup() {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-retention-"));
  const path = join(directory, "test.sqlite");
  const config: AppConfig = {
    authProvider: "header", authHeader: "X-Forwarded-Email", baseUrl: "https://dahlia.example",
    databaseType: "sqlite", databaseUrl: `file:${path}`, oauthRedirectUris: [], maxRequestBytes: 1024 * 1024,
  };
  const store = createNodeApplicationStore(config);
  await store.migrate();
  await store.ensureIdentityUser(owner);
  await store.ensureIdentityUser(member);
  const raw = new DatabaseSync(path);
  resources.push({ directory, store, raw });
  const service = new MeetingSyncService(store.sync);
  const vaultId = id();
  const create = body(vaultId, [{ entity: "vault", action: "create", entityId: vaultId, baseRevision: null, data: {
    name: "Durable Vault", createdAt: new Date().toISOString(),
  } }]);
  const receipt = await service.commitTransaction(owner, create);
  return { directory, path, config, store, raw, service, vaultId, create, receipt };
}

function expire(raw: DatabaseSync, time = Date.now() - SYNC_HISTORY_RETENTION_MS - 1_000) {
  raw.prepare("UPDATE sync_changes SET created_at = ?").run(time);
  raw.prepare("UPDATE transaction_receipts SET created_at = ?").run(time);
}

describe("sync history retention", () => {
  it.each(["deleted", "recreated-empty", "recreated-summary", "updated"])(
    "keeps child invalidations complete when a snapshotted meeting is %s", async (scenario) => {
      const { service, raw, vaultId } = await setup();
      const meetingId = id();
      const screenshotId = id();
      const createdAt = new Date().toISOString();
      const data = { projectId: null, name: "Meeting", description: "", status: "READY", duration: null,
        recordingStartedAt: null, createdAt, updatedAt: createdAt };
      const createMeeting = { entity: "meeting" as const, action: "create" as const, entityId: meetingId, baseRevision: null, data };
      await service.commitTransaction(owner, body(vaultId, [createMeeting, {
        entity: "summary", action: "upsert", entityId: meetingId, baseRevision: 0,
        data: { title: "Old summary", document: "{}", createdAt },
      }]));
      raw.prepare("UPDATE meetings SET transcript_revision = 1 WHERE meeting_id = ?").run(meetingId);
      raw.prepare("INSERT INTO files(file_id, vault_id, uri, size, content_type, checksum, name, metadata, active, uploaded_at, revision) VALUES (?, ?, ?, 1, 'image/png', ?, 'capture.png', ?, 1, ?, 1)")
        .run(screenshotId, vaultId, `/Volumes/test/app/files/files/${screenshotId}/original`, `SHA-256:${"a".repeat(64)}`, '{"source":"screenshot"}', Date.now());
      raw.prepare("INSERT INTO meeting_files(id, vault_id, meeting_id, file_id, captured_at) VALUES (?, ?, ?, ?, ?)")
        .run(screenshotId, vaultId, meetingId, screenshotId, Date.now());
      const snapshot = await service.listSnapshot(owner, vaultId);
      expect(snapshot.items.map(({ entity }) => entity)).toEqual(["vault", "meeting", "summary", "transcript", "file", "meeting_file"]);
      if (scenario === "updated") {
        await service.commitTransaction(owner, body(vaultId, [{
          entity: "meeting", action: "update", entityId: meetingId, baseRevision: 1,
          data: { projectId: null, name: "Renamed", description: "", status: "READY", duration: null,
            recordingStartedAt: null, updatedAt: createdAt },
        }]));
      } else {
        await service.commitTransaction(owner, body(vaultId, [{ entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 1, data: {} }]));
        if (scenario !== "deleted") await service.commitTransaction(owner, body(vaultId, [createMeeting]));
        if (scenario === "recreated-summary") await service.commitTransaction(owner, body(vaultId, [{
          entity: "summary", action: "upsert", entityId: meetingId, baseRevision: 0,
          data: { title: "Replacement summary", document: "{}", createdAt },
        }]));
      }
      const delta = await service.listChanges(owner, vaultId, snapshot.startCursor);
      if (scenario === "updated") {
        expect(delta.items).toMatchObject([{ entity: "meeting", action: "upsert" }]);
        return;
      }
      expect(delta.items).toEqual(expect.arrayContaining([
        expect.objectContaining({ entity: "transcript", entityId: meetingId,
          action: scenario === "deleted" ? "delete" : "upsert", revision: scenario === "deleted" ? null : 0 }),
        expect.objectContaining({ entity: "meeting_file", entityId: screenshotId, action: "delete" }),
        expect.objectContaining({ entity: "meeting", entityId: meetingId, action: scenario === "deleted" ? "delete" : "upsert" }),
      ]));
      const summary = delta.items.find(({ entity }) => entity === "summary");
      if (scenario === "recreated-summary") {
        expect(summary).toMatchObject({ action: "upsert", record: { title: "Replacement summary" } });
      } else if (scenario === "deleted") {
        expect(summary).toMatchObject({ action: "delete", record: null });
      } else {
        expect(summary).toMatchObject({ action: "upsert", record: { contentOmitted: true, contentPresent: false } });
      }
      expect(delta.items).toHaveLength(4);
    },
  );

  it("rolls back a failed SQLite prune and drains a ledger across bounded batches", async () => {
    const { store, raw, vaultId, receipt } = await setup();
    const insert = raw.prepare("INSERT INTO sync_changes(owner_user_id, vault_id, entity, entity_id, action, revision, transaction_id) VALUES (?, ?, 'vault', ?, 'upsert', 1, ?)");
    raw.exec("BEGIN");
    for (let index = 0; index < 1_000; index++) insert.run(owner.userId, vaultId, vaultId, id());
    raw.prepare("UPDATE sync_vault_state SET latest_sequence = (SELECT max(sequence) FROM sync_changes) WHERE vault_id = ?").run(vaultId);
    raw.exec("COMMIT");
    expire(raw);
    raw.exec("CREATE TRIGGER fail_prune BEFORE DELETE ON sync_changes BEGIN SELECT RAISE(ABORT, 'test failure'); END");
    await expect(pruneSyncHistory(store.sync)).rejects.toThrow();
    expect(raw.prepare("SELECT pruned_through FROM sync_vault_state").get()).toEqual({ pruned_through: 0 });
    expect(raw.prepare("SELECT count(*) AS count FROM sync_changes").get()).toEqual({ count: 1_001 });
    raw.exec("DROP TRIGGER fail_prune");
    const first = await store.sync.pruneHistoryBatch({ ownerUserId: owner.userId, vaultId });
    expect(first).toEqual({ changesDeleted: 1_000, receiptsCompacted: 1 });
    expect(await pruneSyncHistory(store.sync)).toEqual({ changesDeleted: 1, receiptsCompacted: 0 });
    expect(raw.prepare("SELECT latest_sequence = pruned_through AS complete FROM sync_vault_state").get()).toEqual({ complete: 1 });
    expect(raw.prepare("SELECT cursor FROM transaction_receipts").get()).toEqual({ cursor: decodeSyncCursor(receipt.cursor) });
  });

  it("keeps the exact 90-day boundary and compacts only older data", async () => {
    const { store, raw } = await setup();
    const time = Date.now();
    vi.spyOn(Date, "now").mockReturnValue(time);
    expire(raw, time - SYNC_HISTORY_RETENTION_MS);
    expect(await pruneSyncHistory(store.sync)).toEqual({ changesDeleted: 0, receiptsCompacted: 0 });
    expire(raw, time - SYNC_HISTORY_RETENTION_MS - 1);
    expect(await pruneSyncHistory(store.sync)).toEqual({ changesDeleted: 1, receiptsCompacted: 1 });
    expect(await pruneSyncHistory(store.sync)).toEqual({ changesDeleted: 0, receiptsCompacted: 0 });
    expect(raw.prepare("SELECT name FROM vaults").get()).toEqual({ name: "Durable Vault" });
  });

  it("preserves cursors after deleting every change and bootstraps an old Vault from canonical rows", async () => {
    const { store, service, raw, vaultId, receipt } = await setup();
    expire(raw);
    await pruneSyncHistory(store.sync);
    expect(await service.latestCursor(owner)).toBe(receipt.cursor);
    await expect(service.listChanges(owner, vaultId)).rejects.toMatchObject({ status: 410, code: "sync_cursor_expired" });
    expect(await service.listChanges(owner, vaultId, receipt.cursor)).toMatchObject({ items: [], cursor: receipt.cursor, hasMore: false });
    const snapshot = await service.listSnapshot(owner, vaultId);
    expect(snapshot).toMatchObject({ startCursor: receipt.cursor, nextCursor: null, items: [{ entity: "vault", id: vaultId }] });
    const next = await service.commitTransaction(owner, body(vaultId, [{
      entity: "vault", action: "update", entityId: vaultId, baseRevision: 1, data: { name: "New name" },
    }]));
    expect(decodeSyncCursor(next.cursor)).toBeGreaterThan(decodeSyncCursor(receipt.cursor));
    expect(await service.listChanges(owner, vaultId, snapshot.startCursor)).toMatchObject({ items: [{ record: { name: "New name" } }] });
  });

  it("projects historical full receipts on resolve and commit replay without rewriting stored results", async () => {
    const { service, raw, vaultId, create, receipt } = await setup();
    const date = new Date().toISOString();
    const fileId = id(), meetingId = id(), sessionId = id();
    const historical = { ...receipt, records: [...receipt.records,
      { entity: "file", id: fileId, revision: 1, record: { id: fileId, vaultId, revision: 1,
        uri: "private-storage-key", offset: 0, content_type: "image/png", size: 3, checksum: "old-checksum", name: "capture.png",
        metadata: { source: "screenshot", ocr_text: "committed text", caption: null }, createdAt: date, updatedAt: date } },
      { entity: "recording", id: id(), revision: 1, record: { id: 0, recordingNumber: 0, vaultId, meetingId, sessionId,
        startedAt: date, endedAt: date, revision: 1,
        audio: { mic: { content_type: "audio/mp4", size: 7, checksum: null, contentURL: `/api/v1/meetings/${meetingId}/recordings/0/audio/mic` } } } },
      { entity: "file", id: id(), revision: null, record: null },
    ] };
    const stored = JSON.stringify(historical);
    raw.prepare("UPDATE transaction_receipts SET response_json = ? WHERE transaction_id = ?").run(stored, create.id);
    await service.commitTransaction(owner, body(vaultId, [{ entity: "vault", action: "update", entityId: vaultId,
      baseRevision: 1, data: { name: "Newer name" } }]));
    const resolved = await service.resolveTransaction(owner, create);
    expect(receiptSchema.safeParse(resolved).success).toBe(true);
    expect(resolved).toMatchObject({ cursor: receipt.cursor, records: [
      receipt.records[0],
      { record: { contentType: "image/png", checksum: "old-checksum", metadata: { ocrText: "committed text", caption: null } } },
      { record: { audio: { mic: { contentType: "audio/mp4", contentUrl: `/api/v1/meetings/${meetingId}/recordings/0/audio/mic` } } } },
      { record: null },
    ] });
    expect(JSON.stringify(resolved)).not.toMatch(/content_type|contentURL|ocr_text|private-storage-key/);
    expect(await service.commitTransaction(owner, create)).toEqual(resolved);
    expect(await service.resolveTransaction(owner, create)).toEqual(resolved);
    expect(raw.prepare("SELECT response_json FROM transaction_receipts WHERE transaction_id = ?").get(create.id)?.response_json).toBe(stored);
    await expect(service.resolveTransaction(member, create)).rejects.toMatchObject({ status: 404 });
  });

  it("resolves compact receipts without replay or stale content, and rejects altered requests", async () => {
    const { store, service, raw, vaultId, create, receipt } = await setup();
    expect(await service.resolveTransaction(owner, create)).toEqual(receipt);
    expire(raw);
    await pruneSyncHistory(store.sync);
    const compact = await service.resolveTransaction(owner, create);
    expect(compact).toEqual({
      id: create.id, status: "committed", receipt: "compact", cursor: receipt.cursor,
      records: [{ entity: "vault", id: vaultId, revision: 1 }],
    });
    expect(raw.prepare("SELECT response_json, results_json FROM transaction_receipts").get()).toEqual({
      response_json: null, results_json: JSON.stringify([{ entity: "vault", id: vaultId, revision: 1 }]),
    });
    await expect(service.commitTransaction(owner, create)).rejects.toMatchObject({ status: 410, code: "transaction_receipt_expired" });
    await expect(service.resolveTransaction(owner, { ...create, operations: [{ ...create.operations[0], data: { ...create.operations[0]!.data, name: "Changed" } }] }))
      .rejects.toMatchObject({ status: 409, code: "idempotency_key_reused" });
    await expect(service.resolveTransaction(member, create)).rejects.toMatchObject({ status: 404 });
    expect(await service.resolveTransaction(owner, { ...create, id: id() })).toMatchObject({ status: "unknown" });
    expect(raw.prepare("SELECT revision FROM vaults").get()).toEqual({ revision: 1 });
  });

  it("preserves deletion acknowledgements after the Vault and its change history disappear", async () => {
    const { store, service, raw, vaultId } = await setup();
    const deletion = body(vaultId, [{ entity: "vault", action: "reset", entityId: vaultId, baseRevision: 1, data: {} }]);
    const receipt = await service.commitTransaction(owner, deletion);
    expire(raw);
    await pruneSyncHistory(store.sync);
    expect(await service.resolveTransaction(owner, deletion)).toMatchObject({
      status: "committed", receipt: "compact", cursor: receipt.cursor, records: [{ entity: "vault", revision: null }],
    });
    expect(await service.latestCursor(owner)).toBe(receipt.cursor);
    await expect(service.listSnapshot(owner, vaultId)).rejects.toMatchObject({ status: 404 });
    await expect(service.listChanges(member, vaultId)).rejects.toMatchObject({ status: 404 });
  });

  it("bounds serialized snapshot bytes and resumes without skipping large summaries", async () => {
    const { service, raw, vaultId } = await setup();
    const meetings = [id(), id(), id()].sort();
    const createdAt = new Date().toISOString();
    await service.commitTransaction(owner, body(vaultId, meetings.map((meetingId) => ({
      entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
      data: { projectId: null, name: "Meeting", description: "", status: "READY", duration: null,
        recordingStartedAt: null, createdAt, updatedAt: createdAt },
    }))));
    expect((await service.listSnapshot(owner, vaultId)).items
      .filter((item) => item.entity === "meeting").map((item) => item.record?.hasSummary)).toEqual([false, false, false]);
    // Multibyte text and escaped quotes exercise serialized bytes rather than string length.
    const document = JSON.stringify({ text: 'あ"'.repeat(700_000) });
    for (const meetingId of meetings) {
      raw.prepare("UPDATE meetings SET summary_revision = 1 WHERE meeting_id = ?").run(meetingId);
      raw.prepare("INSERT INTO summaries(id, meeting_id, version, title, document, saved_at) VALUES (?, ?, 1, 'Summary', ?, 0)").run(id(), meetingId, document);
    }
    const seen: string[] = [];
    let page = await service.listSnapshot(owner, vaultId);
    expect(page.items.filter((item) => item.entity === "meeting").map((item) => item.record?.hasSummary)).toEqual([true, true, true]);
    const startCursor = page.startCursor;
    let pages = 0;
    while (true) {
      expect(++pages).toBeLessThanOrEqual(7);
      expect(new TextEncoder().encode(JSON.stringify(page)).byteLength).toBeLessThanOrEqual(SYNC_SNAPSHOT_PAGE_BYTES + 1024);
      expect(page.startCursor).toBe(startCursor);
      seen.push(...page.items.filter((item) => item.entity === "summary").map((item) => item.id));
      if (!page.nextCursor) break;
      page = await service.listSnapshot(owner, vaultId, page.nextCursor, startCursor);
    }
    expect(pages).toBeGreaterThan(1);
    expect(seen).toEqual(meetings);
  });

  it("finishes a paged snapshot with delta catch-up and refuses a pruned starting cursor", async () => {
    const { store, service, raw, vaultId } = await setup();
    const projects = Array.from({ length: 105 }, () => id()).sort();
    await service.commitTransaction(owner, body(vaultId, projects.map((projectId) => ({
      entity: "project", action: "create", entityId: projectId, baseRevision: null,
      data: { name: "Project", description: "", parentProjectId: null, projectType: "internal", createdAt: new Date().toISOString() },
    }))));
    const first = await service.listSnapshot(owner, vaultId);
    expect(first.items).toHaveLength(100);
    expect(first.nextCursor).not.toBeNull();
    const added = id();
    await service.commitTransaction(owner, body(vaultId, [
      { entity: "project", action: "delete", entityId: projects[0]!, baseRevision: 1, data: {} },
      { entity: "project", action: "create", entityId: added, baseRevision: null, data: {
        name: "Added during scan", description: "", parentProjectId: null, projectType: "personal", createdAt: new Date().toISOString(),
      } },
    ]));
    const second = await service.listSnapshot(owner, vaultId, first.nextCursor!, first.startCursor);
    expect(second.startCursor).toBe(first.startCursor);
    const delta = await service.listChanges(owner, vaultId, first.startCursor);
    expect(delta.items).toEqual(expect.arrayContaining([
      expect.objectContaining({ entityId: projects[0], action: "delete" }),
      expect.objectContaining({ entityId: added, action: "upsert" }),
    ]));
    expire(raw);
    await pruneSyncHistory(store.sync);
    await expect(service.listSnapshot(owner, vaultId, first.nextCursor!, first.startCursor))
      .rejects.toMatchObject({ status: 410, code: "sync_cursor_expired" });
    await expect(service.listChanges(owner, vaultId, first.startCursor, delta.highWaterCursor))
      .rejects.toMatchObject({ status: 410, code: "sync_cursor_expired" });
  });

  it("reauthorizes each snapshot page after sharing is revoked", async () => {
    const { store, service, raw, vaultId } = await setup();
    raw.prepare("INSERT INTO vault_permissions(vault_id, principal_type, principal_id, role, granted_by_user_id) VALUES (?, 'user', ?, 'member', ?)")
      .run(vaultId, member.userId, owner.userId);
    const snapshot = await service.listSnapshot(member, vaultId);
    expect(snapshot.items).toHaveLength(1);
    raw.prepare("DELETE FROM vault_permissions WHERE principal_id = ?").run(member.userId);
    await expect(service.listSnapshot(member, vaultId, undefined, snapshot.startCursor)).rejects.toMatchObject({ status: 404 });
    expect(await store.sync.withIdentity(owner, (sync) => sync.getVault(vaultId))).not.toBeNull();
  });

  it("registers authenticated, body-limited resolve and snapshot routes", async () => {
    const { store, config, vaultId, create, receipt } = await setup();
    const app = createApp({ config, authStore: store });
    const headers = { "x-forwarded-user": owner.userId, "x-forwarded-email": "retention@example.com", "content-type": "application/json" };
    const response = await app.request("/api/v1/transactions/resolve", { method: "POST", headers, body: JSON.stringify(create) });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ id: create.id, cursor: receipt.cursor });
    expect((await app.request(`/api/v1/vaults/${vaultId}/snapshot`, { headers })).status).toBe(200);
    expect((await app.request(`/api/v1/vaults/${vaultId}/snapshot`)).status).toBe(401);
    expect((await app.request("/api/v1/transactions/resolve", {
      method: "POST", headers: { ...headers, origin: "https://untrusted.example" }, body: JSON.stringify(create),
    })).status).toBe(403);
    expect((await app.request(`/api/v1/vaults/${vaultId}/snapshot?cursor=invalid`, { headers })).status).toBe(400);
  });


});


describe("partial text content", () => {
  it("shares byte-exact Unicode and nullable hashes with Swift", () => {
    const fixtures = JSON.parse(readFileSync(new URL("../../../test-fixtures/text-content-v1.json", import.meta.url), "utf8")) as {
      fields: { value: string | null; body: boolean }[]; sha256: string; byteCount: number;
    }[];
    for (const fixture of fixtures) {
      const digest = new TextContentDigest();
      for (const field of fixture.fields) digest.add(field.value, field.body);
      expect(digest.digestHex()).toBe(fixture.sha256);
      expect(digest.byteCount).toBe(fixture.byteCount);
    }
  });

  it("synchronizes 10000 historical meetings without transferring any text body", async () => {
    const { raw, service, vaultId } = await setup();
    const insert = raw.prepare(`INSERT INTO meetings(meeting_id, vault_id, name, status, created_at, updated_at,
      summary_revision, transcript_revision, active)
      VALUES (?, ?, 'History', 'READY', ?, ?, 1, 1, 1)`);
    const transcript = raw.prepare("INSERT INTO transcript_segments(transcript_id, segment_id, started_at, text) VALUES (?, ?, ?, ?)");
    const summary = raw.prepare("INSERT INTO summaries(id, meeting_id, version, title, document, created_at, saved_at) VALUES (?, ?, 1, 'Summary', ?, ?, ?)");
    const text = "large_text_marker".repeat(64);
    raw.exec("BEGIN");
    for (let index = 0; index < 10000; index += 1) {
      const meeting = id();
      insert.run(meeting, vaultId, index, index);
      summary.run(id(), meeting, text, index, index);
      raw.prepare("INSERT INTO transcripts(id, meeting_id, version, sync_revision, created_at) VALUES (?, ?, 1, 1, ?)").run(meeting, meeting, index);
      transcript.run(meeting, id(), index, text);
    }
    raw.exec("COMMIT");
    let cursor: string | undefined;
    let start: string | undefined;
    let meetings = 0;
    let transcripts = 0;
    do {
      const page = await service.listSnapshot(owner, vaultId, cursor, start);
      start = page.startCursor;
      expect(page).not.toHaveProperty("contentMode");
      expect(JSON.stringify(page)).not.toContain("large_text_marker");
      meetings += page.items.filter((item) => item.entity === "meeting").length;
      for (const item of page.items.filter((item) => item.entity === "transcript")) {
        expect(item.record).toMatchObject({ contentOmitted: true, contentCount: 1 });
        transcripts += 1;
      }
      cursor = page.nextCursor ?? undefined;
    } while (cursor);
    expect(meetings).toBe(10000);
    expect(transcripts).toBe(10000);
  }, 60000);

  it("pins every content page to its revision and reauthorizes deleted or revoked content", async () => {
    const { raw, service, vaultId } = await setup();
    const meetingId = id();
    const time = new Date().toISOString();
    await service.commitTransaction(owner, body(vaultId, [{ entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
      data: { name: "Metadata", projectId: null, description: "", status: "READY", duration: null, recordingStartedAt: null, createdAt: time, updatedAt: time } },
    { entity: "summary", action: "upsert", entityId: meetingId, baseRevision: 0, data: { title: "Summary", document: "{}", createdAt: time } }]));
    raw.prepare("UPDATE meetings SET transcript_revision = 1 WHERE meeting_id = ?").run(meetingId);
    const insert = raw.prepare("INSERT INTO transcript_segments(transcript_id, segment_id, started_at, text) VALUES (?, ?, ?, ?)");
    raw.prepare("INSERT INTO transcripts(id, meeting_id, version, sync_revision, created_at) VALUES (?, ?, 1, 1, ?)").run(meetingId, meetingId, Date.now());
    const digest = new TextContentDigest();
    const segments = Array.from({ length: 501 }, (_, index) => ({ id: id(), text: `原文${index}`, index }));
    raw.exec("BEGIN");
    for (const segment of segments) {
      insert.run(meetingId, segment.id, segment.index, segment.text);
      digest.add(segment.id, false); digest.add(segment.text);
    }
    raw.exec("COMMIT");
    const manifest = await service.transcriptContent(owner, vaultId, meetingId, "1", "1");
    expect(manifest).toMatchObject({ count: 501, sha256: digest.digestHex(), byteCount: digest.byteCount });
    expect(manifest).not.toHaveProperty("items");
    const first = await service.transcriptContent(owner, vaultId, meetingId, "1");
    expect(first.items).toHaveLength(500);
    expect(first.nextCursor).toBeTruthy();
    expect((await service.transcriptContent(owner, vaultId, meetingId, "1", undefined, first.nextCursor!)).items).toHaveLength(1);
    raw.prepare("UPDATE meetings SET transcript_revision = 2 WHERE meeting_id = ?").run(meetingId);
    expect((await service.transcriptContent(owner, vaultId, meetingId, "1", undefined, first.nextCursor!)).items).toHaveLength(1);
    const metadata = await service.listChanges(owner, vaultId, undefined, undefined);
    expect(metadata.items.find((item) => item.entity === "summary")?.record).toMatchObject({ contentOmitted: true, contentPresent: true });
    expect(await service.getMeeting(owner, vaultId, meetingId)).toHaveProperty("summaryDocument", "{}");
    await expect(service.transcriptContent(member, vaultId, meetingId, "2")).rejects.toMatchObject({ status: 404 });
    raw.prepare("UPDATE meetings SET active = 0 WHERE meeting_id = ?").run(meetingId);
    await expect(service.transcriptContent(owner, vaultId, meetingId, "2")).rejects.toMatchObject({ status: 404 });
  });

  it("keeps search pages stable when another Vault changes corpus-wide FTS statistics", async () => {
    const { raw, service, vaultId } = await setup();
    const otherVaultId = id();
    await service.commitTransaction(owner, body(otherVaultId, [{ entity: "vault", action: "create", entityId: otherVaultId,
      baseRevision: null, data: { name: "Other", createdAt: new Date().toISOString() } }]));
    const meeting = raw.prepare("INSERT INTO meetings(meeting_id, vault_id, name, status, created_at, updated_at, active) VALUES (?, ?, 'Metadata', 'READY', 0, 0, 1)");
    const document = raw.prepare("INSERT INTO search_documents(document_id, vault_id, meeting_id, kind, search_text, embedding_text, embedding_content_hash) VALUES (?, ?, ?, 'meeting', ?, ?, 'hash')");
    const ids = [id(), id()];
    for (const [index, text] of ["alpha beta", "alpha beta beta beta " + "noise ".repeat(10)].entries()) {
      const meetingId = ids[index]!;
      meeting.run(meetingId, vaultId);
      document.run(meetingId, vaultId, meetingId, text, text);
    }
    const first = await service.searchText(owner, vaultId, "alpha beta", "meeting", undefined, "1");
    expect(first.nextCursor).toBeTruthy();
    for (let index = 0; index < 10; index += 1) {
      const meetingId = id();
      const text = "alpha ".repeat(50) + "noise ".repeat(300);
      meeting.run(meetingId, otherVaultId);
      document.run(meetingId, otherVaultId, meetingId, text, text);
    }
    const second = await service.searchText(owner, vaultId, "alpha beta", "meeting", first.nextCursor!, "1");
    expect(second.nextCursor).toBeNull();
    expect([...first.items, ...second.items].map((item) => item.id).sort()).toEqual(ids.sort());
  });

  it("pages every FTS result without a hybrid candidate cap and rejects malformed cursors", async () => {
    const { raw, service, vaultId } = await setup();
    const meeting = raw.prepare("INSERT INTO meetings(meeting_id, vault_id, name, status, created_at, updated_at, active) VALUES (?, ?, 'Metadata', 'READY', 0, 0, 1)");
    const document = raw.prepare("INSERT INTO search_documents(document_id, vault_id, meeting_id, kind, search_text, embedding_text, embedding_content_hash) VALUES (?, ?, ?, 'meeting', 'needle', ?, 'hash')");
    raw.exec("BEGIN");
    for (let index = 0; index < 1101; index += 1) {
      const meetingId = id();
      meeting.run(meetingId, vaultId);
      document.run(meetingId, vaultId, meetingId, "needle ".repeat(100));
    }
    raw.exec("COMMIT");
    const found = new Set<string>();
    let cursor: string | undefined;
    do {
      const page = await service.searchText(owner, vaultId, "needle", "meeting", cursor);
      for (const item of page.items) {
        expect(item.snippet.length).toBeLessThanOrEqual(180);
        expect(found.has(item.id)).toBe(false);
        found.add(item.id);
      }
      cursor = page.nextCursor ?? undefined;
    } while (cursor);
    expect(found.size).toBe(1101);
    await expect(service.searchText(owner, vaultId, "needle", "meeting", "{")).rejects.toMatchObject({ status: 400 });
    await expect(service.searchText(member, vaultId, "needle", "meeting")).rejects.toMatchObject({ status: 404 });
  });
});
