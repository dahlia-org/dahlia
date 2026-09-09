import { readFileSync } from "node:fs";
import { Client } from "pg";
import { afterAll, describe, expect, it, vi } from "vitest";
import { eq, sql } from "drizzle-orm";

import { createPostgresAuthStore } from "../src/auth/store";
import type { Identity } from "../src/auth/identity";
import type { AppConfig } from "../src/config";
import { connectAuthDatabase } from "../src/db/client";
import * as schema from "../src/db/auth-schema";
import { createPostgresMeetingSyncStore, SyncTransactionError } from "../src/sync/store";
import type { IdentitySyncStore, SyncTransaction, SyncTransactionOperation } from "../src/sync/types";

const databaseUrl = process.env.TEST_DATABASE_URL;
const integration = describe.runIf(databaseUrl);
const config: AppConfig = {
  authProvider: "header",
  authHeader: "X-Forwarded-Email",
  databaseType: "postgres",
  databaseUrl,
  baseUrl: "https://dahlia.example",
  oauthRedirectUris: [],
  maxRequestBytes: 1024,
};
const connection = databaseUrl ? connectAuthDatabase(config) : undefined;

afterAll(async () => connection?.close());

integration("PostgreSQL application store", () => {
  it.each(["file", "transcript", "expiry"])("serializes %s staging with the transfer lock", async (kind) => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const userId = crypto.randomUUID();
    const owner: Identity = { userId, workspaceId: `personal:${userId}`, source: "header" };
    await store.ensureIdentityUser(owner);
    const source = crypto.randomUUID(), destination = crypto.randomUUID(), meeting = crypto.randomUUID();
    const now = new Date();
    await store.sync.withIdentity(owner, (sync) => createVault(sync, source, [{ id: crypto.randomUUID(), entity: "meeting",
      action: "create", entityId: meeting, baseRevision: null, data: meetingData(null, now, "Meeting", "") }]));
    await store.sync.withIdentity(owner, (sync) => createVault(sync, destination));
    const blocker = new Client({ connectionString: databaseUrl });
    await blocker.connect();
    await blocker.query("BEGIN");
    await blocker.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [`vault:${source}`]);
    let settled = false;
    const staging = store.sync.withIdentity(owner, async (sync) => {
      if (kind === "transcript") return sync.putTranscriptChunk(source, meeting, crypto.randomUUID(), 0, "hash", [], []);
      if (kind === "expiry") return sync.expireFileUploads(source, now);
      return sync.reserveFile({ fileId: crypto.randomUUID(), vaultId: source, uri: "/Volumes/test/staged", offset: 0,
        size: 0, checksum: "", contentType: "image/png", name: "Staged", metadata: { source: "screenshot" },
        active: false, uploadedAt: null, revision: 0, createdAt: now, updatedAt: now });
    }).then((value) => ({ value }), (error: unknown) => ({ error })).finally(() => { settled = true; });
    try {
      await vi.waitFor(async () => {
        const waiting = await blocker.query<{ waiting: boolean }>(
          "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pg_backend_pid() = ANY(pg_blocking_pids(pid))) AS waiting");
        expect(settled || waiting.rows[0]?.waiting).toBe(true);
      });
      expect(settled).toBe(false);
    } finally {
      await blocker.query("ROLLBACK");
      await blocker.end();
      const result = await staging;
      expect(result).not.toHaveProperty("error");
    }
    if (kind !== "expiry") {
      await expect(store.sync.withIdentity(owner, (sync) => sync.transferVault({ sourceVaultId: source, destinationVaultId: destination,
        sourceRevision: 1, destinationRevision: 1, idempotencyKey: crypto.randomUUID(), requestHash: kind })))
        .rejects.toMatchObject({ status: 409, code: "transfer_unsynced_data" });
    }
  });

  it("lists server directory records with correlated organization counts", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const id = crypto.randomUUID();
    const now = new Date();
    await connection!.db.insert(schema.user).values({ id, name: "Directory member", email: `${id}@example.com`, emailVerified: true });
    await connection!.db.insert(schema.organization).values({ id, name: "Directory organization", slug: id, createdAt: now });
    try {
      await connection!.db.insert(schema.member).values({ id, organizationId: id, userId: id, role: "member", createdAt: now });
      await connection!.db.insert(schema.team).values({ id, organizationId: id, name: "Directory team", createdAt: now });
      expect(await store.listServerOrganizations(1000, 0)).toContainEqual({ id, name: "Directory organization", slug: id, memberCount: 1, teamCount: 1 });
      expect(await store.listServerUsers(1000, 0)).toEqual(expect.arrayContaining([expect.objectContaining({ id, email: `${id}@example.com` })]));
    } finally {
      await connection!.db.delete(schema.organization).where(eq(schema.organization.id, id));
      await connection!.db.delete(schema.user).where(eq(schema.user.id, id));
    }
  });

  it("moves composite relationships atomically and serializes competing transfers", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const userId = crypto.randomUUID();
    const owner: Identity = { userId, workspaceId: `personal:${userId}`, source: "header" };
    await store.ensureIdentityUser(owner);
    const source = crypto.randomUUID(), destination = crypto.randomUUID(), alternative = crypto.randomUUID();
    const root = crypto.randomUUID(), child = crypto.randomUUID(), meeting = crypto.randomUUID();
    const now = new Date();
    for (const vault of [source, destination, alternative]) await store.sync.withIdentity(owner, (sync) => createVault(sync, vault));
    await store.sync.withIdentity(owner, (sync) => commit(sync, source, [
      { id: crypto.randomUUID(), entity: "project", action: "create", entityId: root, baseRevision: null,
        data: { parentProjectId: null, name: "Root", description: "", projectType: "undefined", createdAt: now } },
      { id: crypto.randomUUID(), entity: "project", action: "create", entityId: child, baseRevision: null,
        data: { parentProjectId: root, name: "Child", description: "", projectType: null, createdAt: now } },
      { id: crypto.randomUUID(), entity: "meeting", action: "create", entityId: meeting, baseRevision: null,
        data: meetingData(child, now, "Meeting", "") },
    ]));
    const request = { sourceVaultId: source, destinationVaultId: destination, sourceRevision: 1, destinationRevision: 1,
      idempotencyKey: crypto.randomUUID(), requestHash: "first" };
    const outcomes = await Promise.allSettled([request, { ...request, destinationVaultId: alternative,
      idempotencyKey: crypto.randomUUID(), requestHash: "second" }].map((input) => store.sync.withIdentity(owner, (sync) => sync.transferVault(input))));
    expect(outcomes.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(outcomes.filter((result) => result.status === "rejected")).toHaveLength(1);
    const resolved = await store.sync.withIdentity(owner, (sync) => sync.getVaultRelocations(source));
    const moved = resolved.items.find((item) => item.id === meeting)!;
    expect([destination, alternative]).toContain(moved.vaultId);
    expect(await store.sync.withIdentity(owner, (sync) => sync.getMeeting(moved.vaultId, meeting))).toMatchObject({ meetingId: meeting, projectId: child });
    expect(await store.sync.withIdentity(owner, (sync) => sync.getVault(source))).toMatchObject({ hasResources: false });
    expect(await connection!.db.select().from(schema.vaultTransfer)).toEqual([]);
  });

  it("derives recording scope from its meeting under FORCE RLS", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: `recording-owner-${suffix}`, workspaceId: `personal:recording-owner-${suffix}`, source: "header" };
    const member: Identity = { userId: `recording-member-${suffix}`, workspaceId: `personal:recording-member-${suffix}`, source: "header" };
    const vaultId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    const sessionId = crypto.randomUUID();
    const now = new Date();
    await store.ensureIdentityUser(owner);
    await store.ensureIdentityUser(member);
    try {
      await store.sync.withIdentity(owner, async (sync) => {
        await createVault(sync, vaultId, [{ id: crypto.randomUUID(), entity: "meeting", action: "create", entityId: meetingId,
          baseRevision: null, data: meetingData(null, now, "Recording", "") }]);
        for (const kind of ["recording_started", "recording_ended"]) {
          await commit(sync, vaultId, [{ id: crypto.randomUUID(), entity: "meeting_event", action: "create", entityId: crypto.randomUUID(),
            baseRevision: null, data: { meetingId, sessionId, kind, occurredAt: now } }]);
        }
        const record = await sync.reserveRecording(vaultId, meetingId, sessionId, "mic");
        expect(record).toMatchObject({ vaultId, meetingId, sessionId, number: 1 });
      });
      expect(await connection!.db.select().from(schema.syncedRecording).where(eq(schema.syncedRecording.sessionId, sessionId))).toEqual([]);
      expect(await store.sync.withIdentity(member, (sync) => sync.getRecording(meetingId, 1))).toBeNull();
      await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", "external"));
      expect(await store.sync.withIdentity(member, (sync) => sync.getRecording(meetingId, 1))).toMatchObject({ vaultId, meetingId });
      expect(await store.sync.withIdentity(member, (sync) => sync.getRecording(meetingId, 1, true))).toBeNull();
      await connection!.db.transaction(async (tx) => {
        await tx.execute(sql`select set_config('app.user_id', ${member.userId}, true)`);
        await tx.execute(sql`select set_config('app.sharing_enabled', 'true', true)`);
        expect(await tx.select().from(schema.syncedRecording).where(eq(schema.syncedRecording.sessionId, sessionId))).toHaveLength(1);
        expect(await tx.update(schema.syncedRecording).set({ revision: 99 })
          .where(eq(schema.syncedRecording.sessionId, sessionId)).returning()).toEqual([]);
      });
      await store.sync.withIdentity(owner, (sync) => sync.deleteMemberPermission(vaultId, "organization", "external"));
      expect(await store.sync.withIdentity(member, (sync) => sync.getRecording(meetingId, 1))).toBeNull();
      const record = await store.sync.withIdentity(owner, (sync) => sync.getRecording(meetingId, 1));
      await store.sync.withIdentity(owner, (sync) => commit(sync, vaultId, [{ id: crypto.randomUUID(), entity: "meeting", action: "delete",
        entityId: meetingId, baseRevision: 1, data: {} }]));
      expect(await store.sync.withIdentity(owner, (sync) => sync.markRecordingUploaded(sessionId, "mic", record!.audio.mic!.generation, 1, "SHA-256:test"))).toBeNull();
      expect(await store.sync.withIdentity(owner, (sync) => sync.getRecording(meetingId, 1))).toBeNull();
    } finally {
      await store.sync.withIdentity(owner, (sync) => resetVault(sync, vaultId));
    }
  });

  it("fails readiness when meeting event FORCE RLS is missing", async () => {
    expect(await createPostgresMeetingSyncStore(connection!.db).isAvailable()).toBe(true);
    try {
      await connection!.db.execute(sql`ALTER TABLE app.meeting_events NO FORCE ROW LEVEL SECURITY`);
      expect(await createPostgresMeetingSyncStore(connection!.db).isAvailable()).toBe(false);
    } finally {
      await connection!.db.execute(sql`ALTER TABLE app.meeting_events FORCE ROW LEVEL SECURITY`);
    }
    expect(await createPostgresMeetingSyncStore(connection!.db).isAvailable()).toBe(true);
  });

  it("authorizes summaries through meetings and separates generation from sync revision", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const userId = crypto.randomUUID();
    const owner: Identity = { userId, workspaceId: `personal:${userId}`, source: "header" };
    const reader: Identity = { userId: `reader-${userId}`, workspaceId: `personal:reader-${userId}`, source: "header" };
    const outsider: Identity = { userId: `other-${userId}`, workspaceId: `personal:other-${userId}`, source: "header" };
    for (const identity of [owner, reader, outsider]) await store.ensureIdentityUser(identity);
    const vaultId = crypto.randomUUID(); const meetingId = crypto.randomUUID(); const now = new Date();
    await store.sync.withIdentity(owner, (sync) => createVault(sync, vaultId, [{ id: crypto.randomUUID(), entity: "meeting",
      action: "create", entityId: meetingId, baseRevision: null, data: meetingData(null, now, "Meeting", "") }]));
    const save = (sync: IdentitySyncStore, baseRevision: number) => commit(sync, vaultId, [{ id: crypto.randomUUID(), entity: "summary",
      action: "upsert", entityId: meetingId, baseRevision, data: { title: "Summary", document: "{}", createdAt: now } }]);
    try {
      await store.sync.withIdentity(owner, (sync) => save(sync, 0));
      const first = await store.sync.withIdentity(owner, (sync) => sync.getSummaryVersion(vaultId, meetingId));
      expect(first).toMatchObject({ meetingId, version: 1, createdAt: now });
      expect(first).not.toHaveProperty("vaultId");
      expect(await connection!.db.select().from(schema.summary)).toEqual([]);
      await connection!.db.insert(schema.syncedVaultPermission).values({ vaultId, principalType: "user", principalId: reader.userId,
        role: "member", grantedByUserId: owner.userId });
      expect(await store.sync.withIdentity(reader, (sync) => sync.getSummaryVersion(vaultId, meetingId))).toEqual(first);
      expect(await store.sync.withIdentity(outsider, (sync) => sync.getSummaryVersion(vaultId, meetingId))).toBeNull();
      expect(await store.sync.withIdentity(owner, (sync) => sync.getSummaryVersion(crypto.randomUUID(), meetingId))).toBeNull();
      await expect(store.sync.withIdentity(reader, (sync) => save(sync, 1))).rejects.toMatchObject({ status: 409 });
      // Exercise SQL RLS directly as a shared member, bypassing the store's write checks.
      await expect(connection!.db.transaction(async (tx) => {
        await tx.execute(sql`select set_config('app.user_id', ${reader.userId}, true)`);
        await tx.execute(sql`select set_config('app.sharing_enabled', 'true', true)`);
        await tx.insert(schema.summary).values({ id: crypto.randomUUID(), meetingId, version: 2, title: "Denied", document: "{}", savedAt: now });
      })).rejects.toThrow();
      await connection!.db.delete(schema.syncedVaultPermission).where(eq(schema.syncedVaultPermission.principalId, reader.userId));
      expect(await store.sync.withIdentity(reader, (sync) => sync.getSummaryVersion(vaultId, meetingId))).toBeNull();
      const concurrent = await Promise.allSettled([1, 2].map(() => store.sync.withIdentity(owner, (sync) => save(sync, 1))));
      expect(concurrent.filter((result) => result.status === "fulfilled")).toHaveLength(1);
      await store.sync.withIdentity(owner, async (sync) => {
        expect((await sync.listSummaryVersions(vaultId, meetingId, 20)).map((row) => row.version)).toEqual([2, 1]);
        await commit(sync, vaultId, [{ id: crypto.randomUUID(), entity: "summary", action: "delete", entityId: meetingId, baseRevision: 2, data: {} }]);
        await save(sync, 3);
        expect(await sync.getSummaryVersion(vaultId, meetingId)).toMatchObject({ version: 1 });
        expect(await sync.getMeeting(vaultId, meetingId)).toMatchObject({ summaryRevision: 4, summaryTitle: "Summary", summaryCreatedAt: now });
        await commit(sync, vaultId, [{ id: crypto.randomUUID(), entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 1, data: {} }]);
        expect(await sync.getSummaryVersion(vaultId, meetingId)).toBeNull();
      });
    } finally {
      await store.sync.withIdentity(owner, (sync) => resetVault(sync, vaultId));
    }
  });

  it("projects recording history through an invoker view and enforces event RLS", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const userId = crypto.randomUUID();
    const identity: Identity = { userId, workspaceId: `personal:${userId}`, source: "header" };
    await store.ensureIdentityUser(identity);
    const vaultId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    const sessionId = crypto.randomUUID();
    const now = new Date();
    await store.sync.withIdentity(identity, async (sync) => {
      await createVault(sync, vaultId, [{ id: crypto.randomUUID(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: meetingData(null, now, "Meeting", "") }]);
      await commit(sync, vaultId, [{ id: crypto.randomUUID(), entity: "meeting_event", action: "create", entityId: crypto.randomUUID(), baseRevision: null, data: { meetingId, kind: "recording_started", sessionId, occurredAt: now } }]);
      expect(await sync.getMeeting(vaultId, meetingId)).toMatchObject({ isRecording: true });
    });
    // Even the table owner sees no history without a transaction-local identity.
    expect((await connection!.db.select().from(schema.meetingEvent).where(eq(schema.meetingEvent.vaultId, vaultId)))).toEqual([]);
    expect((await connection!.db.select().from(schema.recordingSession).where(eq(schema.recordingSession.vaultId, vaultId)))).toEqual([]);
    await store.sync.withIdentity(identity, async (sync) => {
      await commit(sync, vaultId, [{ id: crypto.randomUUID(), entity: "meeting_event", action: "create", entityId: crypto.randomUUID(), baseRevision: null, data: { meetingId, kind: "recording_ended", sessionId, occurredAt: new Date(now.getTime() + 60000) } }]);
      expect(await sync.getMeeting(vaultId, meetingId)).toMatchObject({ isRecording: false });
      await resetVault(sync, vaultId);
    });
  });

  it("runs the operator RLS probe against the application schema", async () => {
    const client = new Client({ connectionString: databaseUrl });
    await client.connect();
    try {
      const probe = readFileSync(new URL("../scripts/lakebase-rls-probe.sql", import.meta.url), "utf8");
      // pg rejects query errors directly; only psql needs ON_ERROR_STOP.
      await client.query(probe.replace("\\set ON_ERROR_STOP on\n", ""));
    } finally {
      await client.end();
    }
  });

  it("serializes optimistic transactions within a Vault", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const userId = crypto.randomUUID();
    const identity: Identity = { userId, workspaceId: `personal:${userId}`, source: "header" };
    const vaultId = crypto.randomUUID();
    expect(await store.ensureIdentityUser(identity)).toBe(true);
    await store.sync.withIdentity(identity, (sync) => createVault(sync, vaultId));
    const update = (name: string) => store.sync.withIdentity(identity, (sync) => sync.commitTransaction({
      schemaVersion: 2,
      id: crypto.randomUUID(),
      vaultId,
      createdAt: new Date(),
      requestHash: name,
      operations: [{
        id: crypto.randomUUID(),
        entity: "vault",
        action: "update",
        entityId: vaultId,
        baseRevision: 1,
        data: { name },
      }],
    }));

    const results = await Promise.allSettled([update("First"), update("Second")]);
    expect(results.filter(({ status }) => status === "fulfilled")).toHaveLength(1);
    const rejected = results.find((result) => result.status === "rejected");
    if (rejected?.status !== "rejected") throw new Error("expected one revision conflict");
    expect(rejected.reason).toBeInstanceOf(SyncTransactionError);
    expect(rejected.reason as SyncTransactionError).toMatchObject({ status: 409, code: "revision_conflict" });
    await store.sync.withIdentity(identity, (sync) => resetVault(sync, vaultId));
  });

  it("enforces FORCE RLS and does not leak transaction-local identity", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: suffix, workspaceId: `personal:${suffix}`, source: "header" };
    const other: Identity = { userId: `other-${suffix}`, workspaceId: `personal:other-${suffix}`, source: "header" };
    const vaultId = crypto.randomUUID();
    const projectId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    const role = await connection!.db.execute<{ rolsuper: boolean; rolbypassrls: boolean }>(sql`
      select rolsuper, rolbypassrls from pg_roles where rolname = current_user
    `);
    expect(role.rows[0]).toEqual({ rolsuper: false, rolbypassrls: false });
    const protectedTables = await connection!.db.execute<{
      schema_name: string;
      table_name: string;
      rls: boolean;
      force_rls: boolean;
    }>(sql`
      select namespace.nspname as schema_name, class.relname as table_name,
        class.relrowsecurity as rls, class.relforcerowsecurity as force_rls
      from pg_class as class
      join pg_namespace as namespace on namespace.oid = class.relnamespace
      where (namespace.nspname, class.relname) in (
        ('app', 'vaults'),
        ('app', 'projects'),
        ('app', 'transaction_receipts'),
        ('app', 'meetings'),
        ('app', 'transcripts'),
        ('app', 'transcript_segments'),
        ('app', 'transcript_patch_chunks'),
        ('app', 'files'),
        ('app', 'meeting_files'),
        ('app', 'meeting_events'),
        ('app', 'search_documents'),
        ('app', 'search_embeddings')
      )
      order by namespace.nspname, class.relname
    `);
    expect(protectedTables.rows).toHaveLength(12);
    expect(protectedTables.rows.every(({ rls, force_rls }) => rls && force_rls)).toBe(true);
    const legacyOwnerColumns = await connection!.db.execute(sql`
      select 1 from information_schema.columns
      where table_schema = 'app'
        and table_name in ('vaults', 'meetings', 'transcript_segments', 'files', 'meeting_files')
        and column_name = 'owner_workspace_id'
    `);
    expect(legacyOwnerColumns.rows).toEqual([]);
    const searchColumns = await connection!.db.execute<{ table_name: string; column_name: string }>(sql`
      select table_name, column_name from information_schema.columns
      where table_schema = 'app'
        and table_name in ('meetings', 'files', 'meeting_files')
        and column_name in ('search_text', 'search_vector')
      order by table_name, column_name
    `);
    expect(searchColumns.rows).toEqual([]);
    const projectionColumns = await connection!.db.execute<{ column_name: string }>(sql`
      select column_name from information_schema.columns
      where table_schema = 'app' and table_name = 'search_documents'
        and column_name in ('search_text', 'search_vector')
      order by column_name
    `);
    expect(projectionColumns.rows.map(({ column_name }) => column_name)).toEqual(["search_text", "search_vector"]);
    const searchIndexes = await connection!.db.execute<{ indexname: string; indexdef: string }>(sql`
      select indexname, indexdef from pg_indexes
      where schemaname = 'app'
        and (indexname = 'search_documents_search_gin' or indexdef like '%USING hnsw%')
      order by indexname
    `);
    expect(searchIndexes.rows.some(({ indexname }) => indexname === "search_documents_search_gin")).toBe(true);
    expect(searchIndexes.rows.some(({ indexdef }) => indexdef.includes("USING hnsw"))).toBe(true);
    expect(await store.sync.isAvailable()).toBe(true);
    expect(await store.ensureIdentityUser(owner)).toBe(true);
    expect(await store.ensureIdentityUser(other)).toBe(true);
    await store.sync.withIdentity(owner, (sync) => createVault(sync, vaultId, [{
      id: crypto.randomUUID(),
      entity: "project",
      action: "create",
      entityId: projectId,
      baseRevision: null,
      data: {
        parentProjectId: null,
        name: "Project",
        description: "",
        projectType: "internal",
        createdAt: new Date(),
      },
    }]));
    expect(await store.sync.withIdentity(owner, (sync) => sync.listProjects(vaultId))).toHaveLength(1);
    expect(await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(vaultId, meetingId))).toBe(false);
    await store.sync.withIdentity(owner, (sync) => commit(sync, vaultId, [{
      id: crypto.randomUUID(),
      entity: "meeting",
      action: "create",
      entityId: meetingId,
      baseRevision: null,
      data: {
        projectId,
        name: "PostgreSQL search",
        description: "projection",
        status: "COMPLETED",
        duration: null,
        recordingStartedAt: null,
        createdAt: new Date(),
        updatedAt: new Date(),
        searchText: "postgresql search projection",
        embeddingText: null,
        embeddingContentHash: null,
      },
    }]));
    expect(await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(vaultId, meetingId))).toBe(true);
    expect(await connection!.db.select().from(schema.syncedVaultPermission).where(eq(
      schema.syncedVaultPermission.vaultId,
      vaultId,
    ))).toEqual([expect.objectContaining({
      principalType: "user",
      principalId: owner.userId,
      grantedByUserId: owner.userId,
      role: "owner",
    })]);
    expect(await store.sync.withIdentity(other, (sync) => sync.getVault(vaultId))).toBeNull();
    expect(await store.sync.withIdentity(other, (sync) => sync.listProjects(vaultId))).toEqual([]);
    expect(await store.sync.withIdentity(other, (sync) => sync.listMeetings(vaultId, undefined, 10))).toEqual([]);
    await expect(store.sync.withIdentity(owner, async () => {
      throw new Error("rollback");
    })).rejects.toThrow("rollback");
    const withoutContext = await connection!.db.execute<{ count: string }>(sql`
      select count(*)::text as count from app.vaults where vault_id = ${vaultId}
    `);
    expect(withoutContext.rows[0]?.count).toBe("0");
    const searchWithoutContext = await connection!.db.execute<{ count: string }>(sql`
      select count(*)::text as count from app.search_documents where vault_id = ${vaultId}
    `);
    expect(searchWithoutContext.rows[0]?.count).toBe("0");
    const receiptsWithoutContext = await connection!.db.execute<{ count: string }>(sql`
      select count(*)::text as count from app.transaction_receipts where vault_id = ${vaultId}
    `);
    expect(receiptsWithoutContext.rows[0]?.count).toBe("0");
    await store.sync.withIdentity(owner, (sync) => resetVault(sync, vaultId));
  });

  it("persists Better Auth administrators", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const email = `${suffix}@example.com`;

    const identity: Identity = {
      userId: suffix,
      workspaceId: `personal:${suffix}`,
      email,
      source: "header",
    };
    expect(await store.ensureIdentityUser(identity)).toBe(true);
    expect(await store.addAdminUser(email)).toMatchObject({ id: suffix });
    expect(await store.isAdminUser(suffix)).toBe(true);
    expect(await store.removeAdminUser(email)).toBe("removed");
  });

  it("grants read-only Vault access through an explicit organization share", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: `owner-${suffix}`, workspaceId: `personal:owner-${suffix}`, source: "accounts" };
    const member: Identity = { userId: `member-${suffix}`, workspaceId: `personal:member-${suffix}`, source: "accounts" };
    const outsider: Identity = { userId: `outsider-${suffix}`, workspaceId: `personal:outsider-${suffix}`, source: "accounts" };
    const organizationId = `org-${suffix}`;
    const vaultId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    const segmentId = crypto.randomUUID();
    const screenshotId = crypto.randomUUID();
    const patchId = crypto.randomUUID();
    const chunkHash = "a".repeat(64);
    const screenshotHash = "b".repeat(64);
    const now = new Date();
    try {
      await connection!.db.insert(schema.user).values([
        { id: owner.userId, name: "Owner", email: `${owner.userId}@example.com`, emailVerified: true },
        { id: member.userId, name: "Member", email: `${member.userId}@example.com`, emailVerified: true },
      ]);
      await connection!.db.insert(schema.organization).values({
        id: organizationId,
        name: organizationId,
        slug: organizationId,
        createdAt: now,
      });
      await connection!.db.insert(schema.member).values([
        { id: `owner-membership-${suffix}`, organizationId, userId: owner.userId, role: "owner", createdAt: now },
        { id: `member-membership-${suffix}`, organizationId, userId: member.userId, role: "member", createdAt: now },
      ]);
      await store.sync.withIdentity(owner, (sync) => createVault(sync, vaultId));
      expect(await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(vaultId, meetingId))).toBe(false);
      await store.sync.withIdentity(owner, (sync) => commit(sync, vaultId, [{
        id: crypto.randomUUID(),
        entity: "meeting",
        action: "create",
        entityId: meetingId,
        baseRevision: null,
        data: meetingData(null, now, "Shared meeting", "shared meeting"),
      }]));
      await store.sync.withIdentity(owner, async (sync) => {
        expect(await sync.putTranscriptChunk(vaultId, meetingId, patchId, 0, chunkHash, [{
          segmentId,
          startedAt: now,
          endedAt: null,
          text: "original",
          createdAt: null,
          audioSource: "system",
          speakerLabel: null,
        }], [])).toBe(true);
        expect(await sync.reserveFile({ fileId: screenshotId, vaultId, uri: `/Volumes/test/app/files/files/${screenshotId}/original`,
          offset: 0, size: 1, contentType: "image/png", checksum: `SHA-256:${screenshotHash}`, name: "capture.png",
          metadata: { source: "screenshot", ocr_text: "screen" }, active: false, uploadedAt: now, revision: 0, createdAt: now, updatedAt: now,
        })).not.toBeNull();
        await commit(sync, vaultId, [{ id: crypto.randomUUID(), entity: "file", action: "upsert", entityId: screenshotId, baseRevision: null,
          data: { checksum: `SHA-256:${screenshotHash}`, metadata: {} },
        }, { id: crypto.randomUUID(), entity: "meeting_file", action: "upsert", entityId: screenshotId, baseRevision: null,
          data: { meetingId, fileId: screenshotId, capturedAt: now, sessionId: null, createdAt: now,
            searchText: "screen", embeddingText: "screen", embeddingContentHash: "screen-hash" },
        }, {
          id: patchId,
          entity: "transcript",
          action: "patch",
          entityId: meetingId,
          baseRevision: 0,
          data: {
            transcript: { id: patchId, startedAt: null, endedAt: null, metadata: null }, mode: "replace", patchId,
            segmentCount: 1,
            deletionCount: 0,
            chunks: [{ index: 0, sha256: chunkHash, segmentCount: 1, deletionCount: 0 }],
          },
        }]);
      });
      for (const table of ["meetings", "transcripts", "transcript_segments", "files", "meeting_files"] as const) {
        const hidden = await connection!.db.execute<{ count: string }>(
          sql.raw(`select count(*)::text as count from app.${table}`),
        );
        expect(hidden.rows[0]?.count).toBe("0");
      }
      expect(await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", organizationId)))
        .toBe(true);
      expect(await store.sync.withIdentity(member, (sync) => sync.getVault(vaultId)))
        .toMatchObject({ vaultId, role: "member" });
      await store.sync.withIdentity(member, async (sync) => {
        expect(await sync.getMeeting(vaultId, meetingId)).toMatchObject({ name: "Shared meeting" });
        expect(await sync.listMeetings(vaultId, { text: "shared", tokens: ["shared"] }, 10)).toHaveLength(1);
        expect(await sync.listMeetings(vaultId, { text: "missing", tokens: ["missing"] }, 10)).toEqual([]);
        expect(await sync.listTranscript(vaultId, meetingId, 10)).toHaveLength(1);
        expect(await sync.listScreenshots(vaultId, meetingId, undefined, 10)).toHaveLength(1);
        expect(await sync.listScreenshots(vaultId, meetingId, { text: "screen", tokens: ["screen"] }, 10))
          .toHaveLength(1);
      });
      expect(await store.sync.withIdentity(member, (sync) => sync.ensureUploadTarget(vaultId, meetingId))).toBe(false);
      expect(await store.sync.withIdentity(outsider, (sync) => sync.getVault(vaultId))).toBeNull();
      expect(await store.sync.withIdentity(
        outsider,
        (sync) => sync.listMeetings(vaultId, { text: "shared", tokens: ["shared"] }, 10),
      )).toEqual([]);
      await connection!.db.delete(schema.member).where(eq(schema.member.userId, member.userId));
      expect(await store.sync.withIdentity(member, (sync) => sync.getVault(vaultId))).toBeNull();
      await store.deleteVaultPermissionsForOrganization(organizationId);
      await connection!.db.delete(schema.organization).where(eq(schema.organization.id, organizationId));
      expect(await store.sync.withIdentity(owner, (sync) => sync.listPermissions(vaultId)))
        .toEqual([expect.objectContaining({ principalType: "user", role: "owner" })]);
    } finally {
      await store.sync.withIdentity(owner, async (sync) => {
        await sync.deleteMemberPermission(vaultId, "organization", organizationId);
        await resetVault(sync, vaultId);
      }).catch(() => undefined);
      await connection!.db.delete(schema.organization).where(eq(schema.organization.id, organizationId));
      await connection!.db.delete(schema.user).where(eq(schema.user.id, owner.userId));
      await connection!.db.delete(schema.user).where(eq(schema.user.id, member.userId));
    }
  });

  it("keeps header Vaults private until the owner shares with the external organization", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: `owner-${suffix}`, workspaceId: `personal:owner-${suffix}`, source: "header" };
    const member: Identity = { userId: `member-${suffix}`, workspaceId: `personal:member-${suffix}`, source: "header" };
    const vaultId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    const teamId = `team-${suffix}`;
    try {
      expect(await store.ensureIdentityUser(owner)).toBe(true);
      expect(await store.ensureIdentityUser(member)).toBe(true);
      await store.sync.withIdentity(owner, (sync) => createVault(sync, vaultId));
      expect(await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(vaultId, meetingId))).toBe(false);
      expect(await store.sync.withIdentity(member, (sync) => sync.getVault(vaultId))).toBeNull();
      expect(await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(
        vaultId,
        "organization",
        "external",
      ))).toBe(true);
      expect(await store.sync.withIdentity(member, (sync) => sync.getVault(vaultId)))
        .toMatchObject({ vaultId, role: "member" });
      expect(await store.sync.withIdentity(member, (sync) => sync.ensureUploadTarget(vaultId, meetingId))).toBe(false);
      await store.sync.withIdentity(owner, (sync) => sync.deleteMemberPermission(vaultId, "organization", "external"));
      expect(await store.sync.withIdentity(member, (sync) => sync.getVault(vaultId))).toBeNull();
      await connection!.db.insert(schema.team).values({
        id: teamId,
        name: "Readers",
        organizationId: "external",
        createdAt: new Date(),
        updatedAt: new Date(),
      });
      await connection!.db.insert(schema.teamMember).values({
        id: `${teamId}:${member.userId}`,
        teamId,
        userId: member.userId,
        createdAt: new Date(),
      });
      expect(await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "team", teamId))).toBe(true);
      expect(await store.sync.withIdentity(member, (sync) => sync.getVault(vaultId)))
        .toMatchObject({ vaultId, role: "member" });
      await connection!.db.delete(schema.teamMember).where(eq(schema.teamMember.teamId, teamId));
      expect(await store.sync.withIdentity(member, (sync) => sync.getVault(vaultId))).toBeNull();
    } finally {
      await store.sync.withIdentity(owner, async (sync) => {
        await sync.deleteMemberPermission(vaultId, "team", teamId);
        await sync.deleteMemberPermission(vaultId, "organization", "external");
        await resetVault(sync, vaultId);
      }).catch(() => undefined);
      await connection!.db.delete(schema.team).where(eq(schema.team.id, teamId));
    }
  });

  it("rejects non-owner restoration of a revision-zero Vault without side effects", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: `restore-owner-${suffix}`, workspaceId: `personal:restore-owner-${suffix}`, source: "header" };
    const member: Identity = { userId: `restore-member-${suffix}`, workspaceId: `personal:restore-member-${suffix}`, source: "header" };
    const vaultId = crypto.randomUUID();
    const projectId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    const id = crypto.randomUUID();
    const now = new Date();
    const restore: SyncTransaction = { schemaVersion: 2, id, vaultId, createdAt: now, requestHash: id, operations: [
      { id: crypto.randomUUID(), entity: "vault", action: "create", entityId: vaultId,
        baseRevision: null, data: { name: "Restored", createdAt: now } },
      { id: crypto.randomUUID(), entity: "project", action: "create", entityId: projectId,
        baseRevision: null, data: { parentProjectId: null, name: "Project", description: "", projectType: "internal", createdAt: now } },
      { id: crypto.randomUUID(), entity: "meeting", action: "create", entityId: meetingId,
        baseRevision: null, data: meetingData(null, now, "Meeting", "Meeting") },
    ] };
    try {
      await store.ensureIdentityUser(owner);
      await store.ensureIdentityUser(member);
      await store.sync.withIdentity(owner, async (sync) => {
        await createVault(sync, vaultId);
        await commit(sync, vaultId, [{ id: crypto.randomUUID(), entity: "vault", action: "reset", entityId: vaultId,
          baseRevision: 1, data: { preservePermissions: true } }]);
      });
      const before = await store.sync.withIdentity(owner, async (sync) => ({
        vault: await sync.getVault(vaultId), cursor: await sync.latestChangeSequence(vaultId),
      }));
      // RLS-hidden Vaults must fail with a non-retryable authorization error, not a raw constraint error.
      await expect(store.sync.withIdentity(member, (sync) => sync.commitTransaction(restore)))
        .rejects.toMatchObject({ status: 404, code: "vault_not_found", conflicts: [], operationId: restore.operations[0]!.id });
      await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", "external"));
      await expect(store.sync.withIdentity(member, (sync) => sync.commitTransaction(restore)))
        .rejects.toMatchObject({ status: 404, code: "vault_not_found", conflicts: [] });
      await store.sync.withIdentity(owner, async (sync) => {
        expect(await sync.getVault(vaultId)).toEqual(before.vault);
        expect(await sync.latestChangeSequence(vaultId)).toBe(before.cursor);
        expect(await sync.listProjects(vaultId)).toEqual([]);
        expect(await sync.getMeeting(vaultId, meetingId)).toBeNull();
      });
      expect(await store.sync.withIdentity(member, (sync) => sync.resolveTransaction(restore))).toBeNull();
      const receipt = await store.sync.withIdentity(owner, (sync) => sync.commitTransaction(restore));
      expect(await store.sync.withIdentity(owner, (sync) => sync.commitTransaction(restore))).toEqual(JSON.parse(JSON.stringify(receipt)));
      expect(await store.sync.withIdentity(member, (sync) => sync.getMeeting(vaultId, meetingId))).toMatchObject({ name: "Meeting" });
      await store.sync.withIdentity(owner, (sync) => sync.deleteMemberPermission(vaultId, "organization", "external"));
      expect(await store.sync.withIdentity(member, (sync) => sync.getMeeting(vaultId, meetingId))).toBeNull();
    } finally {
      await store.sync.withIdentity(owner, (sync) => resetVault(sync, vaultId));
    }
  });

  it("supports direct user members without granting writes or another owner", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: `owner-${suffix}`, workspaceId: `personal:owner-${suffix}`, source: "header" };
    const member: Identity = { userId: `member-${suffix}`, workspaceId: `personal:member-${suffix}`, source: "header" };
    const vaultId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    try {
      expect(await store.ensureIdentityUser(owner)).toBe(true);
      expect(await store.ensureIdentityUser(member)).toBe(true);
      await store.sync.withIdentity(owner, (sync) => createVault(sync, vaultId));
      expect(await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(vaultId, meetingId))).toBe(false);
      await connection!.db.insert(schema.syncedVaultPermission).values({
        vaultId,
        principalType: "user",
        principalId: member.userId,
        role: "member",
        grantedByUserId: owner.userId,
      });
      await expect(connection!.db.insert(schema.syncedVaultPermission).values({
        vaultId,
        principalType: "user",
        principalId: `second-owner-${suffix}`,
        role: "owner",
        grantedByUserId: owner.userId,
      })).rejects.toThrow();
      await expect(connection!.db.insert(schema.syncedVaultPermission).values({
        vaultId,
        principalType: "organization",
        principalId: `org-owner-${suffix}`,
        role: "owner",
        grantedByUserId: owner.userId,
      })).rejects.toThrow();

      await store.sync.withIdentity(member, async (sync) => {
        expect(await sync.getVault(vaultId)).toMatchObject({ role: "member" });
        expect(await sync.listPermissions(vaultId)).toEqual([
          expect.objectContaining({ principalType: "user", principalId: member.userId, role: "member" }),
        ]);
        expect(await sync.ensureUploadTarget(vaultId, meetingId)).toBe(false);
        await expect(resetVault(sync, vaultId)).rejects.toMatchObject({ status: 409, code: "revision_conflict" });
        expect(await sync.putMemberPermission(vaultId, "organization", "external")).toBe(false);
      });
    } finally {
      await connection!.db.delete(schema.syncedVaultPermission).where(eq(
        schema.syncedVaultPermission.principalId,
        member.userId,
      ));
      await store.sync.withIdentity(owner, async (sync) => {
        await resetVault(sync, vaultId);
      }).catch(() => undefined);
    }
  });

  it("copies full transcript versions under parent RLS and seals them immutably", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: `transcript-${suffix}`, workspaceId: `personal:transcript-${suffix}`, source: "header" };
    const vaultId = crypto.randomUUID(), meetingId = crypto.randomUUID(), firstId = crypto.randomUUID(), secondId = crypto.randomUUID();
    const now = new Date();
    await store.ensureIdentityUser(owner);
    await store.sync.withIdentity(owner, (sync) => createVault(sync, vaultId, [{ id: crypto.randomUUID(),
      entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: meetingData(null, now, "Versions", "") }]));
    const metadata = { provider: "apple", request: { model: "apple-speech-live" },
      runs: [{ generatedBy: "desktop", inputTypes: ["audio"], startedAt: null, completedAt: null }] };
    const write = (id: string, revision: number, status: string, text?: string) => store.sync.withIdentity(owner, async (sync) => {
      const patchId = crypto.randomUUID(), sha256 = "d".repeat(64);
      if (text) await sync.putTranscriptChunk(vaultId, meetingId, patchId, 0, sha256, [{ segmentId: crypto.randomUUID(),
        startedAt: now, endedAt: null, text, createdAt: null, audioSource: "mic", speakerLabel: null }], []);
      return commit(sync, vaultId, [{ id: patchId, entity: "transcript", action: "patch", entityId: meetingId, baseRevision: revision,
        data: { patchId, mode: "append", transcript: { id, startedAt: now, endedAt: status === "completed" ? now : null, metadata },
          segmentCount: text ? 1 : 0, deletionCount: 0,
          chunks: text ? [{ index: 0, sha256, segmentCount: 1, deletionCount: 0 }] : [] } }]);
    });
    try {
      await write(firstId, 0, "live", "first");
      await write(firstId, 1, "completed");
      await write(secondId, 2, "live", "second");
      await write(secondId, 3, "completed");
      await store.sync.withIdentity(owner, async (sync) => {
        expect(await sync.listTranscript(vaultId, meetingId, 10, undefined, 1)).toHaveLength(1);
        expect(await sync.listTranscript(vaultId, meetingId, 10, undefined, 2)).toHaveLength(2);
        expect(await sync.listTranscriptVersions(vaultId, meetingId, 10)).toHaveLength(2);
        expect(await sync.countTranscript(vaultId, meetingId)).toBe(2);
        expect(await sync.countTranscript(crypto.randomUUID(), meetingId)).toBe(0);
      });
      await expect(write(secondId, 4, "live", "overwrite")).rejects.toMatchObject({ code: "transcript_version_immutable" });
      expect((await connection!.db.execute(sql`SELECT * FROM app.transcripts WHERE meeting_id = ${meetingId}`)).rows).toEqual([]);
      expect((await connection!.db.execute(sql`SELECT * FROM app.transcript_segments WHERE transcript_id = ${secondId}`)).rows).toEqual([]);
    } finally { await store.sync.withIdentity(owner, (sync) => resetVault(sync, vaultId)); }
  });


});

function createVault(
  sync: IdentitySyncStore,
  vaultId: string,
  operations: SyncTransactionOperation[] = [],
) {
  return commit(sync, vaultId, [{
    id: crypto.randomUUID(),
    entity: "vault",
    action: "create",
    entityId: vaultId,
    baseRevision: null,
    data: { name: "Vault", createdAt: new Date() },
  }, ...operations]);
}

function commit(sync: IdentitySyncStore, vaultId: string, operations: SyncTransactionOperation[]) {
  const id = crypto.randomUUID();
  return sync.commitTransaction({
    schemaVersion: 2,
    id,
    vaultId,
    createdAt: new Date(),
    requestHash: id,
    operations,
  });
}

function meetingData(
  projectId: string | null,
  now: Date,
  name: string,
  searchText: string,
) {
  return {
    projectId,
    name,
    description: "",
    status: "READY",
    duration: 1,
    recordingStartedAt: now,
    createdAt: now,
    updatedAt: now,
    searchText,
    embeddingText: null,
    embeddingContentHash: null,
  };
}

async function resetVault(sync: IdentitySyncStore, vaultId: string) {
  const vault = await sync.getVault(vaultId);
  await commit(sync, vaultId, [{ id: crypto.randomUUID(), entity: "vault", action: "reset", entityId: vaultId,
    baseRevision: vault?.revision ?? null, data: { preservePermissions: true } }]);
  return commit(sync, vaultId, [{ id: crypto.randomUUID(), entity: "vault", action: "reset", entityId: vaultId,
    baseRevision: 0, data: {} }]);
}
