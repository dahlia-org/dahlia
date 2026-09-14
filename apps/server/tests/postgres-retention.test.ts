import { seedPostgresIdentity } from "./public-test-client";
import { testOrganizationID } from "./public-test-client";
import { Client } from "pg";
import { describe, expect, it } from "vitest";
import { createNodeApplicationStore } from "../src/auth/node-store";
import type { Identity } from "../src/auth/identity";
import { MeetingSyncService } from "../src/sync/service";
import { decodeSyncCursor } from "../src/sync/store";

const databaseUrl = process.env.TEST_DATABASE_URL;

describe.runIf(databaseUrl)("PostgreSQL retention", () => {
  it("publishes every cascaded child invalidation across ledger batches", async () => {
    const store = createNodeApplicationStore({
      authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "postgres", databaseUrl,
      baseUrl: "https://dahlia.example", oauthRedirectUris: [], maxRequestBytes: 1024 * 1024,
    });
    const raw = new Client({ connectionString: databaseUrl });
    await raw.connect();
    const userId = crypto.randomUUID();
    const identity: Identity = { userId,  source: "header" };
    const workspaceId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    const meetingData = { projectId: null, name: "Meeting", description: "", status: "READY", duration: null,
      recordingStartedAt: null, createdAt: new Date(), updatedAt: new Date() };
    try {
      await seedPostgresIdentity(store, databaseUrl!, identity);
      const initial = await store.sync.withIdentity(identity, (sync) => sync.commitTransaction({
        schemaVersion: 3, id: crypto.randomUUID(), workspaceId, createdAt: new Date(), requestHash: "initial",
        operations: [
          { id: crypto.randomUUID(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null, data: { organizationId: testOrganizationID, name: "Workspace", createdAt: new Date() } },
          { id: crypto.randomUUID(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: meetingData },
        ],
      }));
      await raw.query("BEGIN");
      await raw.query("SELECT set_config('app.user_id', $1, true)", [userId]);
      await raw.query(`INSERT INTO app.files(file_id, workspace_id, uri, size, content_type, checksum, name, metadata, active, uploaded_at, revision)
        SELECT gen_random_uuid(), $1, '/Volumes/test/app/files/test', 1, 'image/png', 'SHA-256:' || repeat('a', 64), 'capture.png', '{"source":"screenshot"}', true, now(), 1 FROM generate_series(1, 105)`, [workspaceId]);
      await raw.query(`INSERT INTO app.meeting_attachments(id, workspace_id, meeting_id, file_id, captured_at)
        SELECT file_id, workspace_id, $2, file_id, now() FROM app.files WHERE workspace_id = $1`, [workspaceId, meetingId]);
      await raw.query("COMMIT");
      await store.sync.withIdentity(identity, (sync) => sync.commitTransaction({
        schemaVersion: 3, id: crypto.randomUUID(), workspaceId, createdAt: new Date(), requestHash: "delete",
        operations: [{ id: crypto.randomUUID(), entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 1, data: {} }],
      }));
      await store.sync.purgeDeletedMeetings(workspaceId, new Date(Date.now() + 8 * 86_400_000));
      const recreated = await store.sync.withIdentity(identity, (sync) => sync.commitTransaction({
        schemaVersion: 3, id: crypto.randomUUID(), workspaceId, createdAt: new Date(), requestHash: "recreate",
        operations: [{ id: crypto.randomUUID(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: meetingData }],
      }));
      const service = new MeetingSyncService(store.sync);
      const first = await service.listChanges(identity, workspaceId, initial.cursor);
      expect(first.items).toHaveLength(100);
      expect(first.hasMore).toBe(true);
      const middle = await service.listChanges(identity, workspaceId, first.cursor, first.highWaterCursor);
      expect(middle.items).toHaveLength(100);
      const second = await service.listChanges(identity, workspaceId, middle.cursor, first.highWaterCursor);
      expect(second.items).toHaveLength(13);
      expect(second.hasMore).toBe(false);
      expect(second.cursor).toBe(recreated.cursor);
      const items = [...first.items, ...middle.items, ...second.items];
      expect(items.filter(({ entity, action }) => entity === "meeting_attachment" && action === "delete")).toHaveLength(105);
      const summary = items.find(({ entity }) => entity === "summary");
      expect(summary).toMatchObject({ record: { contentOmitted: true, contentPresent: false } });
      expect(summary?.record).not.toHaveProperty("document");
      expect(items.find(({ entity }) => entity === "transcript")).toMatchObject({ revision: 0 });
    } finally {
      await raw.query("ROLLBACK");
      await raw.end();
      await store.close?.();
    }
  });

  it("retains jobs and content safely across restore/purge races under RLS", async () => {
    const store = createNodeApplicationStore({ authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "postgres", databaseUrl,
      baseUrl: "https://dahlia.example", oauthRedirectUris: [], maxRequestBytes: 1024 * 1024 });
    const raw = new Client({ connectionString: databaseUrl });
    await raw.connect();
    const owner: Identity = { userId: crypto.randomUUID(), source: "header" };
    const editor: Identity = { userId: crypto.randomUUID(), source: "header" };
    const workspaceId = crypto.randomUUID(), meetingId = crypto.randomUUID();
    const commit = (operations: import("../src/sync/types").SyncTransactionOperation[]) => store.sync.withIdentity(owner, (sync) => sync.commitTransaction({
      schemaVersion: 3, id: crypto.randomUUID(), workspaceId, createdAt: new Date(), requestHash: crypto.randomUUID(), operations,
    }));
    const change = (action: "delete" | "restore", baseRevision: number) => commit([
      { id: crypto.randomUUID(), entity: "meeting", entityId: meetingId, action, baseRevision, data: {} },
    ]);
    try {
      await seedPostgresIdentity(store, databaseUrl!, owner);
      await seedPostgresIdentity(store, databaseUrl!, editor);
      await commit([
        { id: crypto.randomUUID(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null,
          data: { organizationId: testOrganizationID, name: "Trash RLS", createdAt: new Date() } },
        { id: crypto.randomUUID(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
          data: { projectId: null, name: "Retained", description: "content", status: "READY", duration: null, recordingStartedAt: null, createdAt: new Date(), updatedAt: new Date() } },
      ]);
      await store.sync.withIdentity(owner, (sync) => sync.putPermission(workspaceId, "user", editor.userId, "editor"));
      await raw.query("BEGIN");
      await raw.query("SELECT set_config('app.user_id', $1, true)", [editor.userId]);
      await raw.query(`INSERT INTO jobs.summary(id, workspace_id, meeting_id, owner_user_id, method, settings, output_language,
        status, created_at, available_at, claimed_at, lease_expires_at, summary_revision, input_version, request_hash)
        VALUES (gen_random_uuid(), $1, $2, $3, 'transcript', '{}', 'en', 'processing', now(), now(), now(), now() + interval '1 day', 0, '1', 'test')`,
      [workspaceId, meetingId, editor.userId]);
      await raw.query("COMMIT");
      await change("delete", 1);
      expect((await raw.query("SELECT * FROM app.meetings WHERE meeting_id = $1", [meetingId])).rows).toEqual([]);
      expect(await store.sync.withIdentity(editor, (sync) => sync.getMeeting(workspaceId, meetingId))).toBeNull();
      await change("restore", 2);
      expect(await store.sync.withIdentity(editor, (sync) => sync.getMeeting(workspaceId, meetingId))).toMatchObject({ name: "Retained", revision: 3 });
      await raw.query("BEGIN");
      await raw.query("SELECT set_config('app.user_id', $1, true)", [editor.userId]);
      expect((await raw.query("SELECT status, claimed_at, lease_expires_at FROM jobs.summary WHERE meeting_id = $1", [meetingId])).rows)
        .toEqual([{ status: "cancelled", claimed_at: null, lease_expires_at: null }]);
      await raw.query("COMMIT");
      await change("delete", 3);
      const [restored, purged] = await Promise.allSettled([
        change("restore", 4), store.sync.purgeDeletedMeetings(workspaceId, new Date(Date.now() + 8 * 86_400_000)),
      ]);
      expect(purged.status).toBe("fulfilled");
      const current = await store.sync.withIdentity(owner, (sync) => sync.getMeeting(workspaceId, meetingId));
      if (restored.status === "fulfilled") {
        expect(current).toMatchObject({ name: "Retained", revision: 5 });
        expect(purged).toMatchObject({ value: 0 });
      } else {
        expect(current).toBeNull();
        expect(purged).toMatchObject({ value: 1 });
        expect(restored.reason).toMatchObject({ code: "meeting_not_deleted" });
      }
    } finally { await raw.query("ROLLBACK"); await raw.end(); await store.close?.(); }
  });

  it("serializes pruning with commits and rolls back the floor with failed deletion under FORCE RLS", async () => {
    const store = createNodeApplicationStore({
      authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "postgres", databaseUrl,
      baseUrl: "https://dahlia.example", oauthRedirectUris: [], maxRequestBytes: 1024 * 1024,
    });
    const raw = new Client({ connectionString: databaseUrl });
    await raw.connect();
    const userId = crypto.randomUUID();
    const owner: Identity = { userId,  source: "header" };
    const workspaceId = crypto.randomUUID();
    const transactionId = crypto.randomUUID();
    const target = { ownerUserId: userId, workspaceId };
    try {
      await seedPostgresIdentity(store, databaseUrl!, owner);
      const receipt = await store.sync.withIdentity(owner, (sync) => sync.commitTransaction({
        schemaVersion: 3, id: transactionId, workspaceId, createdAt: new Date(), requestHash: "retention-test",
        operations: [{ id: crypto.randomUUID(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null,
          data: { organizationId: testOrganizationID, name: "Preserved", createdAt: new Date().toISOString() } }],
      }));
      expect((await raw.query("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")).rows[0])
        .toEqual({ rolsuper: false, rolbypassrls: false });
      await raw.query("BEGIN");
      await raw.query("SELECT set_config('app.user_id', $1, true)", [userId]);
      await raw.query("UPDATE app.sync_changes SET created_at = now() - interval '91 days' WHERE workspace_id = $1", [workspaceId]);
      await raw.query("UPDATE app.transaction_receipts SET created_at = now() - interval '91 days' WHERE transaction_id = $1", [transactionId]);
      await raw.query("COMMIT");
      expect((await raw.query("SELECT * FROM app.transaction_receipts WHERE transaction_id = $1", [transactionId])).rows).toEqual([]);
      // A deliberate database failure after the floor update must roll back the complete batch.
      await raw.query(`CREATE FUNCTION app.retention_test_abort() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test deletion failure'; END $$`);
      await raw.query(`CREATE TRIGGER retention_test_abort BEFORE DELETE ON app.sync_changes FOR EACH ROW WHEN (OLD.workspace_id = '${workspaceId}'::uuid) EXECUTE FUNCTION app.retention_test_abort()`);
      await expect(store.sync.pruneHistoryBatch(target)).rejects.toThrow();
      expect((await raw.query<{ pruned_through: string }>("SELECT pruned_through FROM app.sync_workspace_state WHERE workspace_id = $1", [workspaceId])).rows[0]?.pruned_through).toBe("0");
      await raw.query("DROP TRIGGER retention_test_abort ON app.sync_changes");
      await raw.query("DROP FUNCTION app.retention_test_abort()");
      const results = await Promise.all([
        store.sync.pruneHistoryBatch(target), store.sync.pruneHistoryBatch(target),
        store.sync.withIdentity(owner, (sync) => sync.commitTransaction({
          schemaVersion: 3, id: crypto.randomUUID(), workspaceId, createdAt: new Date(), requestHash: "new-edit",
          operations: [{ id: crypto.randomUUID(), entity: "workspace", action: "update", entityId: workspaceId, baseRevision: 1, data: { name: "Latest" } }],
        })),
      ]);
      expect(results[0].changesDeleted + results[1].changesDeleted).toBe(1);
      expect(results[0].receiptsCompacted + results[1].receiptsCompacted).toBe(1);
      const service = new MeetingSyncService(store.sync);
      await expect(service.listChanges(owner, workspaceId)).rejects.toMatchObject({ code: "sync_cursor_expired", status: 410 });
      expect(await service.listSnapshot(owner, workspaceId)).toMatchObject({ items: [{ record: { name: "Latest" } }] });
      const delta = await service.listChanges(owner, workspaceId, receipt.cursor);
      expect(decodeSyncCursor(delta.cursor)).toBeGreaterThan(decodeSyncCursor(receipt.cursor));
      await raw.query("BEGIN");
      await raw.query("SELECT set_config('app.user_id', $1, true)", [userId]);
      const row = (await raw.query<{ response_json: unknown; results_json: unknown }>("SELECT response_json, results_json FROM app.transaction_receipts WHERE transaction_id = $1", [transactionId])).rows[0];
      expect(row).toEqual({ response_json: null, results_json: [{ entity: "workspace", id: workspaceId, revision: 1 }] });
      await raw.query("ROLLBACK");
      expect((await raw.query("SELECT * FROM app.transaction_receipts WHERE transaction_id = $1", [transactionId])).rows).toEqual([]);
    } finally {
      await raw.query("ROLLBACK");
      await raw.query("DROP TRIGGER IF EXISTS retention_test_abort ON app.sync_changes");
      await raw.query("DROP FUNCTION IF EXISTS app.retention_test_abort()");
      await raw.end();
      await store.close?.();
    }
  });
});
