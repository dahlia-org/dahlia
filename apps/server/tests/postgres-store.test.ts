import { seedPostgresIdentity } from "./public-test-client";
import { testOrganizationID } from "./public-test-client";
import { testUserID } from "./public-test-client";
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
  it("maps concurrent normalized emails to one UUID user regardless of external subject", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const subject = `external-${crypto.randomUUID()}`;
    const identity: Identity = { userId: subject, email: `${subject}@example.com`,  source: "header" };
    const ids = await Promise.all(Array.from({ length: 12 }, () => store.resolveHeaderUser(identity)));
    expect(ids[0]).toMatch(/^[0-9a-f-]{14}7[0-9a-f-]{21}$/);
    expect(new Set(ids).size).toBe(1);
    expect(await store.resolveHeaderUser({ ...identity, userId: `${subject}-other` })).toBe(ids[0]);
    expect(await store.resolveHeaderUser(identity)).toBe(ids[0]);
    const rows = await connection!.db.select().from(schema.user).where(eq(schema.user.email, identity.email!));
    expect(rows).toHaveLength(1);
  });

  it.each(["app.workspace_permissions", "auth.member", "auth.team_member"])("holds %s membership writes until the transfer commits", async (table) => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const userId = crypto.randomUUID();
    const owner: Identity = { userId,  source: "header" };
    await seedPostgresIdentity(store, databaseUrl!, owner);
    const source = crypto.randomUUID(), destination = crypto.randomUUID();
    await store.sync.withIdentity(owner, (sync) => createWorkspace(sync, source));
    await store.sync.withIdentity(owner, (sync) => createWorkspace(sync, destination));
    const audience = await store.sync.withIdentity(owner, (sync) => sync.workspaceTransferAudience(source, destination));
    let markReady!: () => void, failReady!: (error: unknown) => void, release!: () => void;
    const ready = new Promise<void>((resolve, reject) => { markReady = resolve; failReady = reject; });
    const released = new Promise<void>((resolve) => { release = resolve; });
    const transfer = store.sync.withIdentity(owner, async (sync) => {
      await sync.transferWorkspace({ sourceWorkspaceId: source, destinationWorkspaceId: destination, sourceRevision: 1, destinationRevision: 1,
        audienceHash: audience.audienceHash, idempotencyKey: crypto.randomUUID(), requestHash: table });
      markReady();
      await released;
    }).catch((error: unknown) => { failReady(error); throw error; });
    const writer = new Client({ connectionString: databaseUrl });
    let write: Promise<unknown> | undefined;
    let settled = false;
    try {
      await ready;
      await writer.connect();
      const pid = (await writer.query<{ pid: number }>("SELECT pg_backend_pid() AS pid")).rows[0]!.pid;
      write = writer.query(`DELETE FROM ${table} WHERE false`).then(() => { settled = true; });
      await vi.waitFor(async () => {
        const waiting = await connection!.db.execute<{ waiting: boolean }>(sql`SELECT EXISTS (
          SELECT 1 FROM pg_stat_activity WHERE pid = ${pid} AND wait_event_type = 'Lock') AS waiting`);
        expect(settled || waiting.rows[0]?.waiting).toBe(true);
      });
      expect(settled).toBe(false);
    } finally {
      release();
      await transfer;
      await write;
      await writer.end();
    }
    expect(settled).toBe(true);
  });

  it.each(["file", "transcript", "expiry"])("serializes %s staging with the transfer lock", async (kind) => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const userId = crypto.randomUUID();
    const owner: Identity = { userId,  source: "header" };
    await seedPostgresIdentity(store, databaseUrl!, owner);
    const source = crypto.randomUUID(), destination = crypto.randomUUID(), meeting = crypto.randomUUID();
    const now = new Date();
    await store.sync.withIdentity(owner, (sync) => createWorkspace(sync, source, [{ id: crypto.randomUUID(), entity: "meeting",
      action: "create", entityId: meeting, baseRevision: null, data: meetingData(null, now, "Meeting", "") }]));
    await store.sync.withIdentity(owner, (sync) => createWorkspace(sync, destination));
    const blocker = new Client({ connectionString: databaseUrl });
    await blocker.connect();
    await blocker.query("BEGIN");
    await blocker.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [`workspace:${source}`]);
    let settled = false;
    const staging = store.sync.withIdentity(owner, async (sync) => {
      if (kind === "transcript") return sync.putTranscriptChunk(source, meeting, crypto.randomUUID(), 0, "hash", [], []);
      if (kind === "expiry") return sync.expireFileUploads(source, now);
      return sync.reserveFile({ fileId: crypto.randomUUID(), workspaceId: source, uri: "/Volumes/test/staged", offset: 0,
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
      await expect(store.sync.withIdentity(owner, async (sync) => sync.transferWorkspace({ sourceWorkspaceId: source, destinationWorkspaceId: destination,
        audienceHash: (await sync.workspaceTransferAudience(source, destination)).audienceHash,
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
      expect(await store.listServerOrganizations(1000, 0)).toContainEqual({ id, name: "Directory organization", slug: id, kind: "team", memberCount: 1, teamCount: 1 });
      expect(await store.getServerOrganization(id, 100, 0, 0)).toMatchObject({ id, name: "Directory organization", members: [{ userId: id, email: `${id}@example.com` }], teams: [{ id, name: "Directory team" }] });
      expect(await store.getServerOrganization(id, 100, 1, 1)).toMatchObject({ members: [], teams: [] });
      expect(await store.getServerOrganization(crypto.randomUUID(), 100, 0, 0)).toBeNull();
      expect(await store.listServerUsers(1000, 0)).toEqual(expect.arrayContaining([expect.objectContaining({ id, email: `${id}@example.com` })]));
    } finally {
      await connection!.db.delete(schema.organization).where(eq(schema.organization.id, id));
      await connection!.db.delete(schema.user).where(eq(schema.user.id, id));
    }
  });

  it("moves composite relationships atomically and serializes competing transfers", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const userId = crypto.randomUUID();
    const owner: Identity = { userId,  source: "header" };
    await seedPostgresIdentity(store, databaseUrl!, owner);
    const source = crypto.randomUUID(), destination = crypto.randomUUID(), alternative = crypto.randomUUID();
    const root = crypto.randomUUID(), child = crypto.randomUUID(), meeting = crypto.randomUUID();
    const now = new Date();
    for (const workspace of [source, destination, alternative]) await store.sync.withIdentity(owner, (sync) => createWorkspace(sync, workspace));
    await store.sync.withIdentity(owner, (sync) => commit(sync, source, [
      { id: crypto.randomUUID(), entity: "project", action: "create", entityId: root, baseRevision: null,
        data: { parentProjectId: null, name: "Root", description: "", projectType: "undefined", createdAt: now } },
      { id: crypto.randomUUID(), entity: "project", action: "create", entityId: child, baseRevision: null,
        data: { parentProjectId: root, name: "Child", description: "", projectType: null, createdAt: now } },
      { id: crypto.randomUUID(), entity: "meeting", action: "create", entityId: meeting, baseRevision: null,
        data: meetingData(child, now, "Meeting", "") },
    ]));
    const request = { sourceWorkspaceId: source, destinationWorkspaceId: destination, sourceRevision: 1, destinationRevision: 1,
      audienceHash: (await store.sync.withIdentity(owner, (sync) => sync.workspaceTransferAudience(source, destination))).audienceHash,
      idempotencyKey: crypto.randomUUID(), requestHash: "first" };
    const outcomes = await Promise.allSettled([request, { ...request, destinationWorkspaceId: alternative,
      audienceHash: (await store.sync.withIdentity(owner, (sync) => sync.workspaceTransferAudience(source, alternative))).audienceHash,
      idempotencyKey: crypto.randomUUID(), requestHash: "second" }].map((input) => store.sync.withIdentity(owner, (sync) => sync.transferWorkspace(input))));
    expect(outcomes.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(outcomes.filter((result) => result.status === "rejected")).toHaveLength(1);
    const resolved = await store.sync.withIdentity(owner, (sync) => sync.getWorkspaceRelocations(source));
    const moved = resolved.items.find((item) => item.id === meeting)!;
    expect([destination, alternative]).toContain(moved.workspaceId);
    expect(await store.sync.withIdentity(owner, (sync) => sync.getMeeting(moved.workspaceId, meeting))).toMatchObject({ meetingId: meeting, projectId: child });
    expect(await store.sync.withIdentity(owner, (sync) => sync.getWorkspace(source))).toMatchObject({ hasResources: false });
    expect(await connection!.db.select().from(schema.workspaceTransfer)).toEqual([]);
  });

  it("derives recording scope from its meeting under FORCE RLS", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: testUserID(`recording-owner-${suffix}`),  source: "header" };
    const member: Identity = { userId: testUserID(`recording-member-${suffix}`),  source: "header" };
    const workspaceId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    const sessionId = crypto.randomUUID();
    const now = new Date();
    await seedPostgresIdentity(store, databaseUrl!, owner);
    await seedPostgresIdentity(store, databaseUrl!, member);
    try {
      await store.sync.withIdentity(owner, async (sync) => {
        await createWorkspace(sync, workspaceId, [{ id: crypto.randomUUID(), entity: "meeting", action: "create", entityId: meetingId,
          baseRevision: null, data: meetingData(null, now, "Recording", "") }]);
        for (const kind of ["recording_started", "recording_ended"]) {
          await commit(sync, workspaceId, [{ id: crypto.randomUUID(), entity: "meeting_event", action: "create", entityId: crypto.randomUUID(),
            baseRevision: null, data: { meetingId, sessionId, kind, occurredAt: now } }]);
        }
        const record = await sync.reserveRecording(workspaceId, meetingId, sessionId, "mic");
        expect(record).toMatchObject({ workspaceId, meetingId, sessionId, number: 1 });
      });
      expect(await connection!.db.select().from(schema.syncedRecording).where(eq(schema.syncedRecording.sessionId, sessionId))).toEqual([]);
      expect(await store.sync.withIdentity(member, (sync) => sync.getRecording(meetingId, 1))).toBeNull();
      await store.sync.withIdentity(owner, (sync) => sync.putPermission(workspaceId, "organization", testOrganizationID, "viewer"));
      expect(await store.sync.withIdentity(member, (sync) => sync.getRecording(meetingId, 1))).toMatchObject({ workspaceId, meetingId });
      expect(await store.sync.withIdentity(member, (sync) => sync.getRecording(meetingId, 1, true))).toBeNull();
      await connection!.db.transaction(async (tx) => {
        await tx.execute(sql`select set_config('app.user_id', ${member.userId}, true)`);
        await tx.execute(sql`select set_config('app.sharing_enabled', 'true', true)`);
        expect(await tx.select().from(schema.syncedRecording).where(eq(schema.syncedRecording.sessionId, sessionId))).toHaveLength(1);
        expect(await tx.update(schema.syncedRecording).set({ revision: 99 })
          .where(eq(schema.syncedRecording.sessionId, sessionId)).returning()).toEqual([]);
      });
      await store.sync.withIdentity(owner, (sync) => sync.deletePermission(workspaceId, "organization", testOrganizationID));
      expect(await store.sync.withIdentity(member, (sync) => sync.getRecording(meetingId, 1))).toBeNull();
      const record = await store.sync.withIdentity(owner, (sync) => sync.getRecording(meetingId, 1));
      await store.sync.withIdentity(owner, (sync) => commit(sync, workspaceId, [{ id: crypto.randomUUID(), entity: "meeting", action: "delete",
        entityId: meetingId, baseRevision: 1, data: {} }]));
      expect(await store.sync.withIdentity(owner, (sync) => sync.markRecordingUploaded(sessionId, "mic", record!.audio.mic!.generation, 1, "SHA-256:test"))).toBeNull();
      expect(await store.sync.withIdentity(owner, (sync) => sync.getRecording(meetingId, 1))).toBeNull();
    } finally {
      await store.sync.withIdentity(owner, (sync) => resetWorkspace(sync, workspaceId));
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
    const owner: Identity = { userId,  source: "header" };
    const reader: Identity = { userId: testUserID(`reader-${userId}`),  source: "header" };
    const outsider: Identity = { userId: testUserID(`other-${userId}`),  source: "header" };
    for (const identity of [owner, reader, outsider]) await seedPostgresIdentity(store, databaseUrl!, identity);
    const workspaceId = crypto.randomUUID(); const meetingId = crypto.randomUUID(); const now = new Date();
    await store.sync.withIdentity(owner, (sync) => createWorkspace(sync, workspaceId, [{ id: crypto.randomUUID(), entity: "meeting",
      action: "create", entityId: meetingId, baseRevision: null, data: meetingData(null, now, "Meeting", "") }]));
    const save = (sync: IdentitySyncStore, baseRevision: number) => commit(sync, workspaceId, [{ id: crypto.randomUUID(), entity: "summary",
      action: "upsert", entityId: meetingId, baseRevision, data: { title: "Summary", document: "{}", createdAt: now } }]);
    try {
      await store.sync.withIdentity(owner, (sync) => save(sync, 0));
      const first = await store.sync.withIdentity(owner, (sync) => sync.getSummaryVersion(workspaceId, meetingId));
      expect(first).toMatchObject({ meetingId, version: 1, createdAt: now });
      expect(first).not.toHaveProperty("workspaceId");
      expect(await connection!.db.select().from(schema.summary)).toEqual([]);
      await connection!.db.insert(schema.syncedWorkspacePermission).values({ workspaceId, principalType: "user", principalId: reader.userId,
        role: "viewer", grantedByUserId: owner.userId });
      expect(await store.sync.withIdentity(reader, (sync) => sync.getSummaryVersion(workspaceId, meetingId))).toEqual(first);
      expect(await store.sync.withIdentity(outsider, (sync) => sync.getSummaryVersion(workspaceId, meetingId))).toBeNull();
      expect(await store.sync.withIdentity(owner, (sync) => sync.getSummaryVersion(crypto.randomUUID(), meetingId))).toBeNull();
      await expect(store.sync.withIdentity(reader, (sync) => save(sync, 1))).rejects.toMatchObject({ status: 409 });
      // Exercise SQL RLS directly as a shared member, bypassing the store's write checks.
      await expect(connection!.db.transaction(async (tx) => {
        await tx.execute(sql`select set_config('app.user_id', ${reader.userId}, true)`);
        await tx.execute(sql`select set_config('app.sharing_enabled', 'true', true)`);
        await tx.insert(schema.summary).values({ id: crypto.randomUUID(), meetingId, version: 2, title: "Denied", document: "{}", savedAt: now });
      })).rejects.toThrow();
      await store.sync.withIdentity(owner, (sync) => sync.deletePermission(workspaceId, "user", reader.userId));
      expect(await store.sync.withIdentity(reader, (sync) => sync.getSummaryVersion(workspaceId, meetingId))).toBeNull();
      const concurrent = await Promise.allSettled([1, 2].map(() => store.sync.withIdentity(owner, (sync) => save(sync, 1))));
      expect(concurrent.filter((result) => result.status === "fulfilled")).toHaveLength(1);
      await store.sync.withIdentity(owner, async (sync) => {
        expect((await sync.listSummaryVersions(workspaceId, meetingId, 20)).map((row) => row.version)).toEqual([2, 1]);
        await commit(sync, workspaceId, [{ id: crypto.randomUUID(), entity: "summary", action: "delete", entityId: meetingId, baseRevision: 2, data: {} }]);
        await save(sync, 3);
        expect(await sync.getSummaryVersion(workspaceId, meetingId)).toMatchObject({ version: 1 });
        expect(await sync.getMeeting(workspaceId, meetingId)).toMatchObject({ summaryRevision: 4, summaryTitle: "Summary", summaryCreatedAt: now });
        await commit(sync, workspaceId, [{ id: crypto.randomUUID(), entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 1, data: {} }]);
        expect(await sync.getSummaryVersion(workspaceId, meetingId)).toBeNull();
      });
    } finally {
      await store.sync.withIdentity(owner, (sync) => resetWorkspace(sync, workspaceId));
    }
  });

  it("projects recording history through an invoker view and enforces event RLS", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const userId = crypto.randomUUID();
    const identity: Identity = { userId,  source: "header" };
    await seedPostgresIdentity(store, databaseUrl!, identity);
    const workspaceId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    const sessionId = crypto.randomUUID();
    const now = new Date();
    await store.sync.withIdentity(identity, async (sync) => {
      await createWorkspace(sync, workspaceId, [{ id: crypto.randomUUID(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: meetingData(null, now, "Meeting", "") }]);
      await commit(sync, workspaceId, [{ id: crypto.randomUUID(), entity: "meeting_event", action: "create", entityId: crypto.randomUUID(), baseRevision: null, data: { meetingId, kind: "recording_started", sessionId, occurredAt: now } }]);
      expect(await sync.getMeeting(workspaceId, meetingId)).toMatchObject({ isRecording: true });
    });
    // Even the table owner sees no history without a transaction-local identity.
    expect((await connection!.db.select().from(schema.meetingEvent).where(eq(schema.meetingEvent.workspaceId, workspaceId)))).toEqual([]);
    expect((await connection!.db.select().from(schema.recordingSession).where(eq(schema.recordingSession.workspaceId, workspaceId)))).toEqual([]);
    await store.sync.withIdentity(identity, async (sync) => {
      await commit(sync, workspaceId, [{ id: crypto.randomUUID(), entity: "meeting_event", action: "create", entityId: crypto.randomUUID(), baseRevision: null, data: { meetingId, kind: "recording_ended", sessionId, occurredAt: new Date(now.getTime() + 60000) } }]);
      expect(await sync.getMeeting(workspaceId, meetingId)).toMatchObject({ isRecording: false });
      await resetWorkspace(sync, workspaceId);
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

  it("serializes optimistic transactions within a Workspace", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const userId = crypto.randomUUID();
    const identity: Identity = { userId,  source: "header" };
    const workspaceId = crypto.randomUUID();
    await seedPostgresIdentity(store, databaseUrl!, identity);
    await store.sync.withIdentity(identity, (sync) => createWorkspace(sync, workspaceId));
    const update = (name: string) => store.sync.withIdentity(identity, (sync) => sync.commitTransaction({
      schemaVersion: 3,
      id: crypto.randomUUID(),
      workspaceId,
      createdAt: new Date(),
      requestHash: name,
      operations: [{
        id: crypto.randomUUID(),
        entity: "workspace",
        action: "update",
        entityId: workspaceId,
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
    await store.sync.withIdentity(identity, (sync) => resetWorkspace(sync, workspaceId));
  });

  it("has the search indexes configured by the CI embedding migration", async () => {
    const searchIndexes = await connection!.db.execute<{ indexname: string; indexdef: string }>(sql`
      select indexname, indexdef from pg_indexes
      where schemaname = 'search'
        and (indexname = 'search_documents_search_gin' or indexdef like '%USING hnsw%')
      order by indexname
    `);
    expect(searchIndexes.rows.some(({ indexname }) => indexname === "search_documents_search_gin")).toBe(true);
    expect(searchIndexes.rows.some(({ indexdef }) => indexdef.includes("USING hnsw"))).toBe(true);
  });

  it("enforces FORCE RLS and does not leak transaction-local identity", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: suffix,  source: "header" };
    const other: Identity = { userId: testUserID(`other-${suffix}`),  source: "header" };
    const workspaceId = crypto.randomUUID();
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
        ('app', 'workspaces'),
        ('app', 'projects'),
        ('app', 'transaction_receipts'),
        ('app', 'meetings'),
        ('app', 'transcripts'),
        ('app', 'transcript_segments'),
        ('app', 'transcript_patch_chunks'),
        ('app', 'files'),
        ('app', 'meeting_attachments'),
        ('app', 'meeting_events'),
        ('search', 'documents'),
        ('jobs', 'summary')
      )
      order by namespace.nspname, class.relname
    `);
    expect(protectedTables.rows).toHaveLength(12);
    expect(protectedTables.rows.every(({ rls, force_rls }) => rls && force_rls)).toBe(true);
    const legacyOwnerColumns = await connection!.db.execute(sql`
      select 1 from information_schema.columns
      where table_schema = 'app'
        and table_name in ('workspaces', 'meetings', 'transcript_segments', 'files', 'meeting_attachments')
        and column_name = 'owner_workspace_id'
    `);
    expect(legacyOwnerColumns.rows).toEqual([]);
    const searchColumns = await connection!.db.execute<{ table_name: string; column_name: string }>(sql`
      select table_name, column_name from information_schema.columns
      where table_schema = 'app'
        and table_name in ('meetings', 'files', 'meeting_attachments')
        and column_name in ('search_text', 'search_vector')
      order by table_name, column_name
    `);
    expect(searchColumns.rows).toEqual([]);
    const projectionColumns = await connection!.db.execute<{ column_name: string }>(sql`
      select column_name from information_schema.columns
      where table_schema = 'search' and table_name = 'documents'
        and column_name in ('search_text', 'search_vector')
      order by column_name
    `);
    expect(projectionColumns.rows.map(({ column_name }) => column_name)).toEqual(["search_text", "search_vector"]);
    expect(await store.sync.isAvailable()).toBe(true);
    await seedPostgresIdentity(store, databaseUrl!, owner);
    await seedPostgresIdentity(store, databaseUrl!, other);
    await store.sync.withIdentity(owner, (sync) => createWorkspace(sync, workspaceId, [{
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
    expect(await store.sync.withIdentity(owner, (sync) => sync.listProjects(workspaceId))).toHaveLength(1);
    expect(await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(workspaceId, meetingId))).toBe(false);
    await store.sync.withIdentity(owner, (sync) => commit(sync, workspaceId, [{
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
        embeddingContentHash: null,
      },
    }]));
    expect(await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(workspaceId, meetingId))).toBe(true);
    expect(await connection!.db.select().from(schema.syncedWorkspacePermission).where(eq(
      schema.syncedWorkspacePermission.workspaceId,
      workspaceId,
    ))).toEqual([expect.objectContaining({
      principalType: "user",
      principalId: owner.userId,
      grantedByUserId: owner.userId,
      role: "admin",
    })]);
    expect(await store.sync.withIdentity(other, (sync) => sync.getWorkspace(workspaceId))).toBeNull();
    expect(await store.sync.withIdentity(other, (sync) => sync.listProjects(workspaceId))).toEqual([]);
    expect(await store.sync.withIdentity(other, (sync) => sync.listMeetings(workspaceId, undefined, 10))).toEqual([]);
    await expect(store.sync.withIdentity(owner, async () => {
      throw new Error("rollback");
    })).rejects.toThrow("rollback");
    const withoutContext = await connection!.db.execute<{ count: string }>(sql`
      select count(*)::text as count from app.workspaces where workspace_id = ${workspaceId}
    `);
    expect(withoutContext.rows[0]?.count).toBe("0");
    const searchWithoutContext = await connection!.db.execute<{ count: string }>(sql`
      select count(*)::text as count from search.documents where workspace_id = ${workspaceId}
    `);
    expect(searchWithoutContext.rows[0]?.count).toBe("0");
    const receiptsWithoutContext = await connection!.db.execute<{ count: string }>(sql`
      select count(*)::text as count from app.transaction_receipts where workspace_id = ${workspaceId}
    `);
    expect(receiptsWithoutContext.rows[0]?.count).toBe("0");
    await store.sync.withIdentity(owner, (sync) => resetWorkspace(sync, workspaceId));
  });

  it("persists Better Auth administrators", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const email = `${suffix}@example.com`;

    const identity: Identity = {
      userId: suffix,

      email,
      source: "header",
    };
    await seedPostgresIdentity(store, databaseUrl!, identity);
    expect(await store.addAdminUser(email)).toMatchObject({ id: suffix });
    expect(await store.isAdminUser(suffix)).toBe(true);
    const replacement = { ...identity, userId: crypto.randomUUID(), email: `${suffix}-replacement@example.com` };
    await seedPostgresIdentity(store, databaseUrl!, replacement);
    await store.addAdminUser(replacement.email);
    expect(await store.removeAdminUser(suffix)).toBe("removed");
  });

  it("grants read-only Workspace access through an explicit organization share", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: testUserID(`owner-${suffix}`),  source: "accounts" };
    const member: Identity = { userId: testUserID(`member-${suffix}`),  source: "accounts" };
    const outsider: Identity = { userId: testUserID(`outsider-${suffix}`),  source: "accounts" };
    const organizationId = testUserID(`org-${suffix}`);
    const workspaceId = crypto.randomUUID();
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
        { id: testUserID(`owner-membership-${suffix}`), organizationId, userId: owner.userId, role: "owner", createdAt: now },
        { id: testUserID(`member-membership-${suffix}`), organizationId, userId: member.userId, role: "member", createdAt: now },
      ]);
      await store.sync.withIdentity(owner, (sync) => createWorkspace(sync, workspaceId, [], organizationId));
      expect(await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(workspaceId, meetingId))).toBe(false);
      await store.sync.withIdentity(owner, (sync) => commit(sync, workspaceId, [{
        id: crypto.randomUUID(),
        entity: "meeting",
        action: "create",
        entityId: meetingId,
        baseRevision: null,
        data: meetingData(null, now, "Shared meeting", "shared meeting"),
      }]));
      await store.sync.withIdentity(owner, async (sync) => {
        expect(await sync.putTranscriptChunk(workspaceId, meetingId, patchId, 0, chunkHash, [{
          segmentId,
          startedAt: now,
          endedAt: null,
          text: "original",
          createdAt: null,
          audioSource: "system",
          speakerLabel: null,
        }], [])).toBe(true);
        expect(await sync.reserveFile({ fileId: screenshotId, workspaceId, uri: `/Volumes/test/app/files/files/${screenshotId}/original`,
          offset: 0, size: 1, contentType: "image/png", checksum: `SHA-256:${screenshotHash}`, name: "capture.png",
          metadata: { source: "screenshot", ocr_text: "screen" }, active: false, uploadedAt: now, revision: 0, createdAt: now, updatedAt: now,
        })).not.toBeNull();
        await commit(sync, workspaceId, [{ id: crypto.randomUUID(), entity: "file", action: "upsert", entityId: screenshotId, baseRevision: null,
          data: { checksum: `SHA-256:${screenshotHash}`, metadata: {} },
        }, { id: crypto.randomUUID(), entity: "meeting_attachment", action: "upsert", entityId: screenshotId, baseRevision: null,
          data: { meetingId, fileId: screenshotId, capturedAt: now, sessionId: null, createdAt: now,
            searchText: "screen", embeddingContentHash: "screen-hash" },
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
      for (const table of ["meetings", "transcripts", "transcript_segments", "files", "meeting_attachments"] as const) {
        const hidden = await connection!.db.execute<{ count: string }>(
          sql.raw(`select count(*)::text as count from app.${table}`),
        );
        expect(hidden.rows[0]?.count).toBe("0");
      }
      expect(await store.sync.withIdentity(owner, (sync) => sync.putPermission(workspaceId, "organization", organizationId, "viewer")))
        .toBe(true);
      expect(await store.sync.withIdentity(member, (sync) => sync.getWorkspace(workspaceId)))
        .toMatchObject({ workspaceId, role: "viewer" });
      await store.sync.withIdentity(member, async (sync) => {
        expect(await sync.getMeeting(workspaceId, meetingId)).toMatchObject({ name: "Shared meeting" });
        expect(await sync.listMeetings(workspaceId, { text: "shared", tokens: ["shared"] }, 10)).toHaveLength(1);
        expect(await sync.listMeetings(workspaceId, { text: "missing", tokens: ["missing"] }, 10)).toEqual([]);
        expect(await sync.listTranscript(workspaceId, meetingId, 10)).toHaveLength(1);
        expect(await sync.listScreenshots(workspaceId, meetingId, undefined, 10)).toHaveLength(1);
        expect(await sync.listScreenshots(workspaceId, meetingId, { text: "screen", tokens: ["screen"] }, 10))
          .toHaveLength(1);
      });
      expect(await store.sync.withIdentity(member, (sync) => sync.ensureUploadTarget(workspaceId, meetingId))).toBe(false);
      expect(await store.sync.withIdentity(outsider, (sync) => sync.getWorkspace(workspaceId))).toBeNull();
      expect(await store.sync.withIdentity(
        outsider,
        (sync) => sync.listMeetings(workspaceId, { text: "shared", tokens: ["shared"] }, 10),
      )).toEqual([]);
      await connection!.db.delete(schema.member).where(eq(schema.member.userId, member.userId));
      expect(await store.sync.withIdentity(member, (sync) => sync.getWorkspace(workspaceId))).toBeNull();
      await store.sync.withIdentity(owner, (sync) => sync.deletePermission(workspaceId, "organization", organizationId));
      await expect(connection!.db.delete(schema.organization).where(eq(schema.organization.id, organizationId))).rejects.toThrow();
      expect(await store.sync.withIdentity(owner, (sync) => sync.listPermissions(workspaceId)))
        .toEqual([expect.objectContaining({ principalType: "user", role: "admin" })]);
    } finally {
      await store.sync.withIdentity(owner, (sync) => resetWorkspace(sync, workspaceId));
      await connection!.db.delete(schema.organization).where(eq(schema.organization.id, organizationId));
      await connection!.db.delete(schema.user).where(eq(schema.user.id, owner.userId));
      await connection!.db.delete(schema.user).where(eq(schema.user.id, member.userId));
    }
  });

  it("keeps header Workspaces private until the owner shares with the external organization", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: testUserID(`owner-${suffix}`),  source: "header" };
    const member: Identity = { userId: testUserID(`member-${suffix}`),  source: "header" };
    const workspaceId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    const teamId = testUserID(`team-${suffix}`);
    try {
      await seedPostgresIdentity(store, databaseUrl!, owner);
      await seedPostgresIdentity(store, databaseUrl!, member);
      await store.sync.withIdentity(owner, (sync) => createWorkspace(sync, workspaceId));
      expect(await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(workspaceId, meetingId))).toBe(false);
      expect(await store.sync.withIdentity(member, (sync) => sync.getWorkspace(workspaceId))).toBeNull();
      expect(await store.sync.withIdentity(owner, (sync) => sync.putPermission(
        workspaceId,
        "organization",
        testOrganizationID,
        "viewer"))).toBe(true);
      expect(await store.sync.withIdentity(member, (sync) => sync.getWorkspace(workspaceId)))
        .toMatchObject({ workspaceId, role: "viewer" });
      expect(await store.sync.withIdentity(member, (sync) => sync.ensureUploadTarget(workspaceId, meetingId))).toBe(false);
      await store.sync.withIdentity(owner, (sync) => sync.deletePermission(workspaceId, "organization", testOrganizationID));
      expect(await store.sync.withIdentity(member, (sync) => sync.getWorkspace(workspaceId))).toBeNull();
      await connection!.db.insert(schema.team).values({
        id: teamId,
        name: "Readers",
        organizationId: testOrganizationID,
        createdAt: new Date(),
        updatedAt: new Date(),
      });
      await connection!.db.insert(schema.teamMember).values({
        id: crypto.randomUUID(),
        teamId,
        userId: member.userId,
        createdAt: new Date(),
      });
      expect(await store.sync.withIdentity(owner, (sync) => sync.putPermission(workspaceId, "team", teamId, "viewer"))).toBe(true);
      expect(await store.sync.withIdentity(member, (sync) => sync.getWorkspace(workspaceId)))
        .toMatchObject({ workspaceId, role: "viewer" });
      await connection!.db.delete(schema.teamMember).where(eq(schema.teamMember.teamId, teamId));
      expect(await store.sync.withIdentity(member, (sync) => sync.getWorkspace(workspaceId))).toBeNull();
    } finally {
      await store.sync.withIdentity(owner, async (sync) => {
        await sync.deletePermission(workspaceId, "team", teamId);
        await sync.deletePermission(workspaceId, "organization", testOrganizationID);
        await resetWorkspace(sync, workspaceId);
      }).catch(() => undefined);
      await connection!.db.delete(schema.team).where(eq(schema.team.id, teamId));
    }
  });

  it("rejects non-owner restoration of a revision-zero Workspace without side effects", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: testUserID(`restore-owner-${suffix}`),  source: "header" };
    const member: Identity = { userId: testUserID(`restore-member-${suffix}`),  source: "header" };
    const workspaceId = crypto.randomUUID();
    const projectId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    const id = crypto.randomUUID();
    const now = new Date();
    const restore: SyncTransaction = { schemaVersion: 3, id, workspaceId, createdAt: now, requestHash: id, operations: [
      { id: crypto.randomUUID(), entity: "workspace", action: "create", entityId: workspaceId,
        baseRevision: null, data: { organizationId: testOrganizationID, name: "Restored", createdAt: now } },
      { id: crypto.randomUUID(), entity: "project", action: "create", entityId: projectId,
        baseRevision: null, data: { parentProjectId: null, name: "Project", description: "", projectType: "internal", createdAt: now } },
      { id: crypto.randomUUID(), entity: "meeting", action: "create", entityId: meetingId,
        baseRevision: null, data: meetingData(null, now, "Meeting", "Meeting") },
    ] };
    try {
      await seedPostgresIdentity(store, databaseUrl!, owner);
      await seedPostgresIdentity(store, databaseUrl!, member);
      await store.sync.withIdentity(owner, async (sync) => {
        await createWorkspace(sync, workspaceId);
        await commit(sync, workspaceId, [{ id: crypto.randomUUID(), entity: "workspace", action: "reset", entityId: workspaceId,
          baseRevision: 1, data: { preservePermissions: true } }]);
      });
      const before = await store.sync.withIdentity(owner, async (sync) => ({
        workspace: await sync.getWorkspace(workspaceId), cursor: await sync.latestChangeSequence(workspaceId),
      }));
      // RLS-hidden Workspaces must fail with a non-retryable authorization error, not a raw constraint error.
      await expect(store.sync.withIdentity(member, (sync) => sync.commitTransaction(restore)))
        .rejects.toMatchObject({ status: 409, code: "workspace_id_reused" });
      await store.sync.withIdentity(owner, (sync) => sync.putPermission(workspaceId, "organization", testOrganizationID, "viewer"));
      await expect(store.sync.withIdentity(member, (sync) => sync.commitTransaction(restore)))
        .rejects.toMatchObject({ status: 404, code: "workspace_not_found" });
      await store.sync.withIdentity(owner, async (sync) => {
        expect(await sync.getWorkspace(workspaceId)).toEqual(before.workspace);
        expect(await sync.latestChangeSequence(workspaceId)).toBe(before.cursor);
        expect(await sync.listProjects(workspaceId)).toEqual([]);
        expect(await sync.getMeeting(workspaceId, meetingId)).toBeNull();
      });
      expect(await store.sync.withIdentity(member, (sync) => sync.resolveTransaction(restore))).toBeNull();
      const receipt = await store.sync.withIdentity(owner, (sync) => sync.commitTransaction(restore));
      expect(await store.sync.withIdentity(owner, (sync) => sync.commitTransaction(restore))).toEqual(JSON.parse(JSON.stringify(receipt)));
      expect(await store.sync.withIdentity(member, (sync) => sync.getMeeting(workspaceId, meetingId))).toMatchObject({ name: "Meeting" });
      await store.sync.withIdentity(owner, (sync) => sync.deletePermission(workspaceId, "organization", testOrganizationID));
      expect(await store.sync.withIdentity(member, (sync) => sync.getMeeting(workspaceId, meetingId))).toBeNull();
    } finally {
      await store.sync.withIdentity(owner, (sync) => resetWorkspace(sync, workspaceId));
    }
  });

  it("supports direct user Viewers without granting content or management writes", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: testUserID(`owner-${suffix}`),  source: "header" };
    const member: Identity = { userId: testUserID(`member-${suffix}`),  source: "header" };
    const workspaceId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    try {
      await seedPostgresIdentity(store, databaseUrl!, owner);
      await seedPostgresIdentity(store, databaseUrl!, member);
      await store.sync.withIdentity(owner, (sync) => createWorkspace(sync, workspaceId));
      expect(await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(workspaceId, meetingId))).toBe(false);
      await connection!.db.insert(schema.syncedWorkspacePermission).values({
        workspaceId,
        principalType: "user",
        principalId: member.userId,
        role: "viewer",
        grantedByUserId: owner.userId,
      });
      await store.sync.withIdentity(member, async (sync) => {
        expect(await sync.getWorkspace(workspaceId)).toMatchObject({ role: "viewer" });
        expect(await sync.listPermissions(workspaceId)).toEqual([
          expect.objectContaining({ principalType: "user", principalId: member.userId, role: "viewer" }),
        ]);
        expect(await sync.ensureUploadTarget(workspaceId, meetingId)).toBe(false);
        await expect(resetWorkspace(sync, workspaceId)).rejects.toMatchObject({ status: 403, code: "workspace_admin_required" });
        expect(await sync.putPermission(workspaceId, "organization", testOrganizationID, "viewer")).toBe(false);
      });
    } finally {
      await store.sync.withIdentity(owner, (sync) => sync.deletePermission(workspaceId, "user", member.userId));
      await store.sync.withIdentity(owner, async (sync) => {
        await resetWorkspace(sync, workspaceId);
      }).catch(() => undefined);
    }
  });

  it("copies full transcript versions under parent RLS and seals them immutably", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres");
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: testUserID(`transcript-${suffix}`),  source: "header" };
    const workspaceId = crypto.randomUUID(), meetingId = crypto.randomUUID(), firstId = crypto.randomUUID(), secondId = crypto.randomUUID();
    const now = new Date();
    await seedPostgresIdentity(store, databaseUrl!, owner);
    await store.sync.withIdentity(owner, (sync) => createWorkspace(sync, workspaceId, [{ id: crypto.randomUUID(),
      entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: meetingData(null, now, "Versions", "") }]));
    const metadata = { provider: "apple", request: { model: "apple-speech-live" },
      runs: [{ generatedBy: "desktop", inputTypes: ["audio"], startedAt: null, completedAt: null }] };
    const write = (id: string, revision: number, status: string, text?: string) => store.sync.withIdentity(owner, async (sync) => {
      const patchId = crypto.randomUUID(), sha256 = "d".repeat(64);
      if (text) await sync.putTranscriptChunk(workspaceId, meetingId, patchId, 0, sha256, [{ segmentId: crypto.randomUUID(),
        startedAt: now, endedAt: null, text, createdAt: null, audioSource: "mic", speakerLabel: null }], []);
      return commit(sync, workspaceId, [{ id: patchId, entity: "transcript", action: "patch", entityId: meetingId, baseRevision: revision,
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
        expect(await sync.listTranscript(workspaceId, meetingId, 10, undefined, 1)).toHaveLength(1);
        expect(await sync.listTranscript(workspaceId, meetingId, 10, undefined, 2)).toHaveLength(2);
        expect(await sync.listTranscriptVersions(workspaceId, meetingId, 10)).toHaveLength(2);
        expect(await sync.countTranscript(workspaceId, meetingId)).toBe(2);
        expect(await sync.countTranscript(crypto.randomUUID(), meetingId)).toBe(0);
      });
      await expect(write(secondId, 4, "live", "overwrite")).rejects.toMatchObject({ code: "transcript_version_immutable" });
      expect((await connection!.db.execute(sql`SELECT * FROM app.transcripts WHERE meeting_id = ${meetingId}`)).rows).toEqual([]);
      expect((await connection!.db.execute(sql`SELECT * FROM app.transcript_segments WHERE transcript_id = ${secondId}`)).rows).toEqual([]);
    } finally { await store.sync.withIdentity(owner, (sync) => resetWorkspace(sync, workspaceId)); }
  });


});

function createWorkspace(
  sync: IdentitySyncStore,
  workspaceId: string,
  operations: SyncTransactionOperation[] = [],
  organizationId = testOrganizationID,
) {
  return commit(sync, workspaceId, [{
    id: crypto.randomUUID(),
    entity: "workspace",
    action: "create",
    entityId: workspaceId,
    baseRevision: null,
    data: { organizationId, name: "Workspace", createdAt: new Date() },
  }, ...operations]);
}

function commit(sync: IdentitySyncStore, workspaceId: string, operations: SyncTransactionOperation[]) {
  const id = crypto.randomUUID();
  return sync.commitTransaction({
    schemaVersion: 3,
    id,
    workspaceId,
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
    embeddingContentHash: null,
  };
}

async function resetWorkspace(sync: IdentitySyncStore, workspaceId: string) {
  const workspace = await sync.getWorkspace(workspaceId);
  await commit(sync, workspaceId, [{ id: crypto.randomUUID(), entity: "workspace", action: "reset", entityId: workspaceId,
    baseRevision: workspace?.revision ?? null, data: { preservePermissions: true } }]);
  return commit(sync, workspaceId, [{ id: crypto.randomUUID(), entity: "workspace", action: "reset", entityId: workspaceId,
    baseRevision: 0, data: {} }]);
}
