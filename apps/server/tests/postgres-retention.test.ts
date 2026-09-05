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
    const identity: Identity = { userId, workspaceId: `personal:${userId}`, source: "header" };
    const vaultId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    const meetingData = { projectId: null, name: "Meeting", description: "", status: "READY", duration: null,
      recordingStartedAt: null, createdAt: new Date(), updatedAt: new Date() };
    try {
      await store.ensureIdentityUser(identity);
      const initial = await store.sync.withIdentity(identity, (sync) => sync.commitTransaction({
        schemaVersion: 1, id: crypto.randomUUID(), vaultId, createdAt: new Date(), requestHash: "initial",
        operations: [
          { id: crypto.randomUUID(), entity: "vault", action: "create", entityId: vaultId, baseRevision: null, data: { name: "Vault", createdAt: new Date() } },
          { id: crypto.randomUUID(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: meetingData },
        ],
      }));
      await raw.query("BEGIN");
      await raw.query("SELECT set_config('app.user_id', $1, true)", [userId]);
      await raw.query(`INSERT INTO app.screenshots(screenshot_id, vault_id, meeting_id, captured_at, content_type, storage_key, content_length, content_hash)
        SELECT gen_random_uuid(), $1, $2, now(), 'image/png', 'test/' || gen_random_uuid(), 1, repeat('a', 64) FROM generate_series(1, 105)`, [vaultId, meetingId]);
      await raw.query("COMMIT");
      await store.sync.withIdentity(identity, (sync) => sync.commitTransaction({
        schemaVersion: 1, id: crypto.randomUUID(), vaultId, createdAt: new Date(), requestHash: "delete",
        operations: [{ id: crypto.randomUUID(), entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 1, data: {} }],
      }));
      const recreated = await store.sync.withIdentity(identity, (sync) => sync.commitTransaction({
        schemaVersion: 1, id: crypto.randomUUID(), vaultId, createdAt: new Date(), requestHash: "recreate",
        operations: [{ id: crypto.randomUUID(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: meetingData }],
      }));
      const service = new MeetingSyncService(store.sync);
      const first = await service.listChanges(identity, vaultId, initial.cursor);
      expect(first.items).toHaveLength(100);
      expect(first.hasMore).toBe(true);
      const second = await service.listChanges(identity, vaultId, first.cursor, first.highWaterCursor);
      expect(second.items).toHaveLength(8);
      expect(second.hasMore).toBe(false);
      expect(second.cursor).toBe(recreated.cursor);
      const items = [...first.items, ...second.items];
      expect(items.filter(({ entity, action }) => entity === "screenshot" && action === "delete")).toHaveLength(105);
      expect(items.find(({ entity }) => entity === "summary")).toMatchObject({ record: { document: null } });
      expect(items.find(({ entity }) => entity === "transcript")).toMatchObject({ revision: 0 });
    } finally {
      await raw.query("ROLLBACK");
      await raw.end();
      await store.close?.();
    }
  });

  it("serializes pruning with commits and rolls back the floor with failed deletion under FORCE RLS", async () => {
    const store = createNodeApplicationStore({
      authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "postgres", databaseUrl,
      baseUrl: "https://dahlia.example", oauthRedirectUris: [], maxRequestBytes: 1024 * 1024,
    });
    const raw = new Client({ connectionString: databaseUrl });
    await raw.connect();
    const userId = crypto.randomUUID();
    const owner: Identity = { userId, workspaceId: `personal:${userId}`, source: "header" };
    const vaultId = crypto.randomUUID();
    const transactionId = crypto.randomUUID();
    const target = { ownerUserId: userId, vaultId };
    try {
      await store.ensureIdentityUser(owner);
      const receipt = await store.sync.withIdentity(owner, (sync) => sync.commitTransaction({
        schemaVersion: 1, id: transactionId, vaultId, createdAt: new Date(), requestHash: "retention-test",
        operations: [{ id: crypto.randomUUID(), entity: "vault", action: "create", entityId: vaultId, baseRevision: null,
          data: { name: "Preserved", createdAt: new Date().toISOString() } }],
      }));
      expect((await raw.query("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")).rows[0])
        .toEqual({ rolsuper: false, rolbypassrls: false });
      await raw.query("BEGIN");
      await raw.query("SELECT set_config('app.user_id', $1, true)", [userId]);
      await raw.query("UPDATE app.sync_changes SET created_at = now() - interval '91 days' WHERE vault_id = $1", [vaultId]);
      await raw.query("UPDATE app.transaction_receipts SET created_at = now() - interval '91 days' WHERE transaction_id = $1", [transactionId]);
      await raw.query("COMMIT");
      expect((await raw.query("SELECT * FROM app.transaction_receipts WHERE transaction_id = $1", [transactionId])).rows).toEqual([]);
      // A deliberate database failure after the floor update must roll back the complete batch.
      await raw.query(`CREATE FUNCTION app.retention_test_abort() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test deletion failure'; END $$`);
      await raw.query(`CREATE TRIGGER retention_test_abort BEFORE DELETE ON app.sync_changes FOR EACH ROW WHEN (OLD.vault_id = '${vaultId}'::uuid) EXECUTE FUNCTION app.retention_test_abort()`);
      await expect(store.sync.pruneHistoryBatch(target)).rejects.toThrow();
      expect((await raw.query<{ pruned_through: string }>("SELECT pruned_through FROM app.sync_vault_state WHERE vault_id = $1", [vaultId])).rows[0]?.pruned_through).toBe("0");
      await raw.query("DROP TRIGGER retention_test_abort ON app.sync_changes");
      await raw.query("DROP FUNCTION app.retention_test_abort()");
      const results = await Promise.all([
        store.sync.pruneHistoryBatch(target), store.sync.pruneHistoryBatch(target),
        store.sync.withIdentity(owner, (sync) => sync.commitTransaction({
          schemaVersion: 1, id: crypto.randomUUID(), vaultId, createdAt: new Date(), requestHash: "new-edit",
          operations: [{ id: crypto.randomUUID(), entity: "vault", action: "update", entityId: vaultId, baseRevision: 1, data: { name: "Latest" } }],
        })),
      ]);
      expect(results[0].changesDeleted + results[1].changesDeleted).toBe(1);
      expect(results[0].receiptsCompacted + results[1].receiptsCompacted).toBe(1);
      const service = new MeetingSyncService(store.sync);
      await expect(service.listChanges(owner, vaultId)).rejects.toMatchObject({ code: "sync_cursor_expired", status: 410 });
      expect(await service.listSnapshot(owner, vaultId)).toMatchObject({ items: [{ record: { name: "Latest" } }] });
      const delta = await service.listChanges(owner, vaultId, receipt.cursor);
      expect(decodeSyncCursor(delta.cursor)).toBeGreaterThan(decodeSyncCursor(receipt.cursor));
      await raw.query("BEGIN");
      await raw.query("SELECT set_config('app.user_id', $1, true)", [userId]);
      const row = (await raw.query<{ response_json: unknown; results_json: unknown }>("SELECT response_json, results_json FROM app.transaction_receipts WHERE transaction_id = $1", [transactionId])).rows[0];
      expect(row).toEqual({ response_json: null, results_json: [{ entity: "vault", id: vaultId, revision: 1 }] });
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
