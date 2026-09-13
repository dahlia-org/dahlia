import { seedPostgresIdentity } from "./public-test-client";
import { testOrganizationID } from "./public-test-client";
import type { SummaryJob } from "../src/summary/model";
import { expect, it, vi } from "vitest";
import { Client, Pool } from "pg";
import { drizzle } from "drizzle-orm/node-postgres";
import { createPostgresMeetingSyncStore } from "../src/sync/store";
import { createPostgresSearchIndexStore } from "../src/search/index-store";
import { MeetingSyncService } from "../src/sync/service";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { createWorkspaceCipher, unwrapDataKey, encodeBase64, encryptionConfig } from "../src/encryption/crypto";
import { uuidV7 } from "../src/id";
import type { Identity } from "../src/auth/identity";
import type { SyncTransaction } from "../src/sync/types";

// Dedicated disposable database owned by a non-superuser without BYPASSRLS.
it.runIf(process.env.TEST_ENCRYPTION_DATABASE_URL)("stores ciphertext under PostgreSQL RLS and supports authorized reads and rotation", async () => {
  const databaseUrl = process.env.TEST_ENCRYPTION_DATABASE_URL!;
  const master = encodeBase64(new Uint8Array(32).fill(7));
  const encryption = encryptionConfig({ DAHLIA_ENCRYPTION_MASTER_KEY_7: master, DAHLIA_ENCRYPTION_ACTIVE_KEY_ID: "7" })!;
  const store = createNodeApplicationStore({ databaseType: "postgres", databaseUrl, encryption, authProvider: "header", authHeader: "X-Forwarded-Email",
    baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1024 * 1024 });
  const client = new Client({ connectionString: databaseUrl });
  await client.connect();
  const pool = new Pool({ connectionString: databaseUrl });
  try {
    expect((await client.query("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")).rows).toEqual([{ rolsuper: false, rolbypassrls: false }]);
    await store.migrate();
    expect(await store.sync.isAvailable()).toBe(true);
    expect((await client.query("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = 'search.documents'::regclass")).rows)
      .toEqual([{ relrowsecurity: true, relforcerowsecurity: true }]);
    expect((await client.query("SELECT to_regclass('app.search_embeddings') AS old_vectors, to_regclass('app.search_documents') AS old_documents")).rows)
      .toEqual([{ old_vectors: null, old_documents: null }]);
    const owner: Identity = { userId: uuidV7(),  source: "header" };
    const member: Identity = { userId: uuidV7(),  source: "header" };
    await seedPostgresIdentity(store, databaseUrl, owner);
    await seedPostgresIdentity(store, databaseUrl, member);
    const workspaceId = uuidV7(), meetingId = uuidV7(), now = new Date();
    const tx: SyncTransaction = { schemaVersion: 3, id: uuidV7(), workspaceId, requestHash: uuidV7(), createdAt: now, operations: [
      { id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null, data: { organizationId: testOrganizationID, encryption: "server", name: "PG_PRIVATE_WORKSPACE", createdAt: now } },
      { id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: { name: "PG_PRIVATE_MEETING", description: "PG_PRIVATE_DESCRIPTION", status: "READY", projectId: null, createdAt: now, updatedAt: now } },
    ] };
    await store.sync.withIdentity(owner, (sync) => sync.commitTransaction(tx));
    expect(await store.sync.withIdentity(owner, (sync) => sync.getMeeting(workspaceId, meetingId))).toMatchObject({ name: "PG_PRIVATE_MEETING" });
    const job: SummaryJob = { id: uuidV7(), workspaceId, meetingId, ownerUserId: owner.userId, method: "transcript",
      settings: { detail: "medium", model: "PG_PRIVATE_MODEL", reasoningEffort: "low" },
      input: { type: "transcript", version: "PG_PRIVATE_INPUT" },
      transcriptResult: { transcriptId: uuidV7(), version: "1" },
      inputVersion: "PG_PRIVATE_VERSION", requestHash: "PG_PRIVATE_REQUEST", outputLanguage: "ja",
      status: "pending", attempts: 0, createdAt: now, availableAt: now, claimedAt: null,
      leaseExpiresAt: null, lastErrorCode: null, summaryRevision: 0 };
    await store.sync.withIdentity(owner, (sync) => sync.insertSummaryJob(job));
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
    const raw = (await client.query<{ encrypted_payload: string; input_version: string; request_hash: string }>("SELECT * FROM jobs.summary WHERE id = $1", [job.id])).rows[0]!;
    expect(JSON.stringify(raw)).not.toContain("PG_PRIVATE");
    const wrapped = (await client.query<{ wrapped_key: string }>("SELECT wrapped_key FROM crypto.workspace_keys WHERE workspace_id = $1", [workspaceId])).rows[0]!.wrapped_key;
    const cipher = await createWorkspaceCipher(workspaceId, await unwrapDataKey(encryption, workspaceId, wrapped));
    const fields = { settings: job.settings, input: job.input, transcriptResult: job.transcriptResult,
      inputVersion: job.inputVersion, requestHash: job.requestHash };
    expect(await cipher.decrypt("jobs_summary", JSON.stringify([job.id]), "content", raw.encrypted_payload)).toEqual(fields);
    expect(raw.input_version).toBe(await cipher.hash("jobs_summary.inputVersion", job.inputVersion));
    expect(raw.request_hash).toBe(await cipher.hash("jobs_summary.requestHash", job.requestHash));
    // Independent old-format ciphertext, as retained by ALTER TABLE SET SCHEMA/RENAME.
    const legacy = await cipher.encrypt("jobs_summary", JSON.stringify([job.id]), "content", fields);
    await client.query("UPDATE jobs.summary SET encrypted_payload = $1 WHERE id = $2", [legacy, job.id]);
    await client.query("COMMIT");
    expect((await client.query("SELECT * FROM jobs.summary WHERE id = $1", [job.id])).rows).toEqual([]);
    expect(await store.summaryJobs.claim({ id: job.id, ownerUserId: member.userId })).toBeNull();
    const claimed = (await store.summaryJobs.claim({ id: job.id, ownerUserId: owner.userId }))!;
    expect(claimed).toMatchObject(fields);
    await store.summaryJobs.fail(claimed, "temporary", true);
    expect(await store.sync.withIdentity(owner, (sync) => sync.getSummaryJob(workspaceId, meetingId, job.id)))
      .toMatchObject({ ...fields, status: "pending", attempts: 1 });
    expect(await store.sync.withIdentity(owner, (sync) => sync.cancelSummaryJob(workspaceId, meetingId, job.id)))
      .toMatchObject({ ...fields, status: "cancelled" });

    expect(await store.sync.withIdentity(member, (sync) => sync.getMeeting(workspaceId, meetingId))).toBeNull();
    expect((await client.query("SELECT * FROM crypto.workspace_keys")).rows).toEqual([]);
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
    expect(JSON.stringify((await client.query("SELECT * FROM app.meetings WHERE workspace_id = $1", [workspaceId])).rows)).not.toContain("PG_PRIVATE");
    expect(JSON.stringify((await client.query("SELECT * FROM app.transaction_receipts WHERE workspace_id = $1", [workspaceId])).rows)).not.toContain("PG_PRIVATE");
    await client.query("INSERT INTO app.workspace_permissions(workspace_id, principal_type, principal_id, role, granted_by_user_id) VALUES ($1, 'user', $2, 'viewer', $3)", [workspaceId, member.userId, owner.userId]);
    await client.query("COMMIT");
    expect(await store.sync.withIdentity(member, (sync) => sync.getMeeting(workspaceId, meetingId))).toMatchObject({ name: "PG_PRIVATE_MEETING" });
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
    await client.query("DELETE FROM app.workspace_permissions WHERE workspace_id = $1 AND principal_id = $2", [workspaceId, member.userId]);
    await client.query("COMMIT");
    expect(await store.sync.withIdentity(member, (sync) => sync.getMeeting(workspaceId, meetingId))).toBeNull();
    expect(await store.rotateEncryptionKeys(false)).toMatchObject({ pending: 0 });
    const db = drizzle({ client: pool });
    const sync = createPostgresMeetingSyncStore(db, "postgres", { model: "test", dimensions: 32 }, encryption);
    const service = new MeetingSyncService(sync);
    const index = createPostgresSearchIndexStore(db);
    const rename = (name: string, baseRevision: number) => service.commitTransaction(owner, {
      schemaVersion: 3, id: uuidV7(), workspaceId, createdAt: now.toISOString(), operations: [{
        id: uuidV7(), entity: "meeting", action: "update", entityId: meetingId, baseRevision,
        data: { name, description: "", projectId: null, status: "READY", duration: null, recordingStartedAt: null, updatedAt: now.toISOString() },
      }],
    });
    await rename("Searchable title", 1);
    await client.query("UPDATE jobs.search_index SET available_at = '2000-01-01' WHERE workspace_id = $1", [workspaceId]);
    const [indexJob] = await index.claim("test", 32, 100);
    const document = (await index.load(indexJob!))!;
    expect(document.embeddingText).toBe("searchable title");
    const vector = [1, ...new Array<number>(31).fill(0)];
    expect(await index.save(document, "test", 32, vector)).toBe(true);
    expect((await client.query("SELECT * FROM search.documents WHERE workspace_id = $1", [workspaceId])).rows).toEqual([]);
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
    expect((await client.query("SELECT search_text, embedding_model, embedding FROM search.documents WHERE workspace_id = $1", [workspaceId])).rows)
      .toEqual([{ search_text: "searchable title", embedding_model: "test", embedding: vector }]);
    await client.query("COMMIT");
    await rename("Changed title", 2);
    expect(await index.save(document, "test", 32, vector)).toBe(false);
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
    expect((await client.query("SELECT embedding, embedding_model FROM search.documents WHERE workspace_id = $1", [workspaceId])).rows)
      .toEqual([{ embedding: null, embedding_model: null }]);
    await client.query("COMMIT");
    await client.query("UPDATE jobs.search_index SET available_at = '2000-01-01' WHERE workspace_id = $1", [workspaceId]);
    const [pending] = await index.claim("test", 32, 100);
    const oldModel = (await index.load(pending!))!;
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
    await client.query("UPDATE search.documents SET embedding = $1, embedding_model = 'new-model' WHERE workspace_id = $2", [vector, workspaceId]);
    await client.query("DELETE FROM jobs.search_index WHERE workspace_id = $1", [workspaceId]);
    const lateSave = index.save(oldModel, "test", 32, vector);
    await vi.waitFor(async () => {
      expect(Number((await client.query<{ n: string }>("SELECT count(*) AS n FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '%documents%'")).rows[0]!.n)).toBeGreaterThan(0);
    });
    await client.query("COMMIT");
    expect(await lateSave).toBe(false);

  } finally {
    await client.end();
    await pool.end();
    await store.close?.();
  }
});
