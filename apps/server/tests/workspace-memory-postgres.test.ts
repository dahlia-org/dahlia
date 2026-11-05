import { afterAll, describe, expect, it, vi } from "vitest";
import { and, eq, sql } from "drizzle-orm";
import * as schema from "../src/db/auth-schema";
import { applicationAnalyzer, LAKEBASE_JAPANESE_CONFIG, LAKEBASE_TOKENIZER_VERSION_SQL, TEXT_SEARCH_CONFIG_SQL } from "../src/search/lexical";
import { createNodeSearchTokenizer } from "../src/search/node-tokenizer";
import { createPostgresAuthStore } from "../src/auth/store";
import { connectPostgresUrl } from "../src/db/postgres";
import { MeetingSyncService } from "../src/sync/service";
import { uuidV7 } from "@dahlia-ai/ui/model/id";
import { seedPostgresIdentity, testOrganizationID } from "./public-test-client";
import type { Identity } from "../src/auth/identity";

const url = process.env.TEST_DATABASE_URL;
const lindera = applicationAnalyzer(createNodeSearchTokenizer());
const connection = url ? connectPostgresUrl(url, 1) : undefined;
afterAll(async () => connection?.close());
describe.runIf(url)("Workspace memory PostgreSQL RLS", () => {
  it("forces personal owner RLS even for the table owner, with no pool identity leakage", async () => {
    const { db, pool } = connection!;
    const roles = await pool.query("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user");
    expect(roles.rows[0]).toEqual({ rolsuper: false, rolbypassrls: false });
    const app = createPostgresAuthStore(db, "postgres");
    const owner: Identity = { userId: uuidV7(), source: "header" };
    const stranger: Identity = { userId: uuidV7(), source: "header" };
    await seedPostgresIdentity(app, url!, owner); await seedPostgresIdentity(app, url!, stranger);
    const memory = app.personalMemory!;
    const note = await memory.saveNote(owner.userId, owner.userId, { id: uuidV7(), revision: 0, content: "Private lesson" }, "human", true);
    expect(await memory.getNote(owner.userId, owner.userId, note.id)).toMatchObject({ content: "Private lesson", protected: true });
    await expect(memory.listNotes(stranger.userId, owner.userId)).rejects.toMatchObject({ status: 404 });
    expect(await memory.listNotes(stranger.userId, stranger.userId)).toEqual([]);
    const state = await pool.query("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = 'app.personal_memories'::regclass");
    expect(state.rows[0]).toEqual({ relrowsecurity: true, relforcerowsecurity: true });
    await db.transaction(async (tx) => {
      await tx.execute(sql`select set_config('app.user_id', ${owner.userId}, true)`);
      expect((await tx.execute(sql`select id from app.personal_memories where id = ${note.id}`)).rows).toHaveLength(1);
    });
    await db.transaction(async (tx) => {
      await tx.execute(sql`select set_config('app.user_id', ${stranger.userId}, true)`);
      expect((await tx.execute(sql`select id from app.personal_memories where id = ${note.id}`)).rows).toEqual([]);
      expect((await tx.execute(sql`update app.personal_memories set content = 'forbidden' where id = ${note.id} returning id`)).rows).toEqual([]);
    });
    expect((await pool.query("SELECT * FROM app.personal_memories WHERE id = $1", [note.id])).rows).toEqual([]);
    await expect(pool.query("INSERT INTO app.personal_memories (id, user_id, created_by, content, updated_at) VALUES ($1,$2,$2,'forbidden',now())", [uuidV7(), owner.userId])).rejects.toThrow();
    await memory.deleteNote(owner.userId, owner.userId, note.id, 1);
  });
  it("isolates Workspace memories and clears transaction-local identity on a shared pool", async () => {
    const { db, pool } = connection!;
    const roles = await pool.query<{ rolsuper: boolean; rolbypassrls: boolean }>("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user");
    expect(roles.rows[0]).toEqual({ rolsuper: false, rolbypassrls: false });
    const app = createPostgresAuthStore(db, "postgres");
    const owner: Identity = { userId: uuidV7(), source: "header" };
    const stranger: Identity = { userId: uuidV7(), source: "header" };
    await seedPostgresIdentity(app, url!, owner); await seedPostgresIdentity(app, url!, stranger);
    const sync = new MeetingSyncService(app.sync); const workspaceId = uuidV7();
    await sync.commitTransaction(owner, { schemaVersion: 3, workspaceId, id: uuidV7(), createdAt: new Date().toISOString(), operations: [{
      id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null,
      data: { organizationId: testOrganizationID, name: "Memory RLS", createdAt: new Date().toISOString() },
    }] });
    const memory = app.memory!;
    const note = await memory.saveNote(owner.userId, workspaceId, { id: uuidV7(), content: "Private Workspace evidence", revision: 0 }, "human", false, lindera);
    await expect(memory.listNotes(stranger.userId, workspaceId)).rejects.toMatchObject({ status: 404 });
    expect((await memory.listNotes(owner.userId, workspaceId))[0]?.id).toBe(note.id);
    expect((await pool.query("SELECT * FROM app.shared_memories WHERE id = $1", [note.id])).rows).toEqual([]);
    await expect(pool.query("INSERT INTO app.shared_memories (id, workspace_id, created_by, content, updated_at) VALUES ($1,$2,$3,'forbidden',now())", [uuidV7(), workspaceId, stranger.userId])).rejects.toThrow();
    const state = await pool.query<{ relrowsecurity: boolean; relforcerowsecurity: boolean }>("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = 'app.shared_memories'::regclass");
    expect(state.rows[0]).toEqual({ relrowsecurity: true, relforcerowsecurity: true });
    await db.transaction(async (tx) => {
      await tx.execute(sql`select set_config('app.user_id', ${owner.userId}, true)`);
      expect((await tx.execute(sql`select id from app.shared_memories where id = ${note.id}`)).rows).toHaveLength(1);
    });
    expect((await pool.query("SELECT * FROM app.shared_memories WHERE id = $1", [note.id])).rows).toEqual([]);
    const recall = (userId: string, query: string) => memory.recall(userId, workspaceId, query, lindera, 20).then(({ hits }) => hits.map((row) => row.id));
    expect(await recall(owner.userId, "evidence")).toEqual([note.id]);
    // The tokenizer applies NFKC, so full-width and half-width kana match like their normal forms.
    const variant = await memory.saveNote(owner.userId, workspaceId, { id: uuidV7(), content: "ＡＰＩとｶﾀｶﾅの共有メモ", revision: 0 }, "human", false, lindera);
    for (const term of ["api", "カタカナ", "カタカナの共有について"]) expect(await recall(owner.userId, term)).toEqual([variant.id]);
    await memory.deleteNote(owner.userId, workspaceId, variant.id, 1);
    await expect(memory.recall(stranger.userId, workspaceId, "evidence", lindera, 20)).rejects.toMatchObject({ status: 404 });
    // The projection is FORCE RLS like the canonical table; a pool without identity sees no chunks.
    // The tokenizer checks are valid SQL and select nothing without lakebase_tokenizer.
    expect((await pool.query(LAKEBASE_TOKENIZER_VERSION_SQL)).rows).toEqual([]);
    expect((await pool.query(TEXT_SEARCH_CONFIG_SQL, [LAKEBASE_JAPANESE_CONFIG])).rows).toEqual([]);
    expect((await pool.query(TEXT_SEARCH_CONFIG_SQL, ["pg_catalog.simple"])).rows).toHaveLength(1);
    const chunkState = await pool.query("SELECT relname, relforcerowsecurity FROM pg_class WHERE oid IN ('search.shared_memory_chunks'::regclass, 'search.personal_memory_chunks'::regclass) ORDER BY relname");
    expect(chunkState.rows).toEqual([{ relname: "personal_memory_chunks", relforcerowsecurity: true }, { relname: "shared_memory_chunks", relforcerowsecurity: true }]);
    expect((await pool.query("SELECT * FROM search.shared_memory_chunks WHERE memory_id = $1", [note.id])).rows).toEqual([]);
    await db.transaction(async (tx) => {
      await tx.execute(sql`select set_config('app.user_id', ${stranger.userId}, true)`);
      expect((await tx.execute(sql`select memory_id from search.shared_memory_chunks where memory_id = ${note.id}`)).rows).toEqual([]);
    });
    // A viewer can recall but not change shared memories or their chunks.
    await db.insert(schema.syncedWorkspacePermission).values({ workspaceId, principalType: "user", principalId: stranger.userId, role: "viewer", grantedByUserId: owner.userId });
    expect(await recall(stranger.userId, "evidence")).toEqual([note.id]);
    await expect(memory.saveNote(stranger.userId, workspaceId, { id: uuidV7(), content: "viewer write", revision: 0 })).rejects.toMatchObject({ status: 404 });
    await db.transaction(async (tx) => {
      await tx.execute(sql`select set_config('app.user_id', ${stranger.userId}, true)`);
      expect((await tx.execute(sql`update search.shared_memory_chunks set chunk_text = 'x' where memory_id = ${note.id} returning memory_id`)).rows).toEqual([]);
    });
    await db.delete(schema.syncedWorkspacePermission).where(and(eq(schema.syncedWorkspacePermission.workspaceId, workspaceId), eq(schema.syncedWorkspacePermission.principalId, stranger.userId)));
    await expect(memory.recall(stranger.userId, workspaceId, "evidence", lindera, 20)).rejects.toMatchObject({ status: 404 });
    await memory.saveNote(owner.userId, workspaceId, { id: note.id, revision: 1, content: "Updated evidence" }, "human", false, lindera);
    await memory.deleteNote(owner.userId, workspaceId, note.id, 2);
  });
  it("ranks Japanese chunks with pgvector and rebuilds them under Workspace search maintenance", async () => {
    const { db } = connection!;
    const embedding = { model: "test-embedding", dimensions: 32 };
    const app = createPostgresAuthStore(db, "postgres", embedding);
    const owner: Identity = { userId: uuidV7(), source: "header" };
    await seedPostgresIdentity(app, url!, owner);
    const workspaceId = uuidV7();
    await new MeetingSyncService(app.sync).commitTransaction(owner, { schemaVersion: 3, workspaceId, id: uuidV7(), createdAt: new Date().toISOString(), operations: [{
      id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null,
      data: { organizationId: testOrganizationID, name: "Hybrid memory", createdAt: new Date().toISOString() } }] });
    const memory = app.memory!;
    const axis = (index: number) => Array.from({ length: 32 }, (_, i) => i === index ? 1 : 0.01);
    const budget = await memory.saveNote(owner.userId, workspaceId, { id: uuidV7(), content: "来期の予算は300万円で確定した", revision: 0 }, "human", false, lindera);
    const lunch = await memory.saveNote(owner.userId, workspaceId, { id: uuidV7(), content: "Lunch order", revision: 0 }, "human", false, lindera);
    const queued = await db.select().from(schema.backgroundJob).where(eq(schema.backgroundJob.dedupeKey, `memory-index:workspace:${budget.id}`));
    expect(queued[0]?.payload).toMatchObject({ source: "workspace", scopeId: workspaceId, documentId: budget.id, ...embedding });
    for (const [note, vector] of [[budget, axis(0)], [lunch, axis(1)]] as const) {
      const pending = await memory.pendingEmbeddings(workspaceId, note.id, embedding);
      expect(pending).toHaveLength(1);
      // Maintenance writes ignore a vector computed for an older text.
      await memory.saveEmbeddings(workspaceId, note.id, embedding.model, [{ ...pending[0]!, hash: "stale", vector }]);
      expect(await memory.pendingEmbeddings(workspaceId, note.id, embedding)).toHaveLength(1);
      await memory.saveEmbeddings(workspaceId, note.id, embedding.model, [{ ...pending[0]!, vector }]);
      expect(await memory.pendingEmbeddings(workspaceId, note.id, embedding)).toEqual([]);
    }
    const ids = (query: string, vector?: number[]) => memory.recall(owner.userId, workspaceId, query, lindera, 20, vector).then(({ hits }) => hits.map((row) => row.id));
    expect(await ids("予算はいくらで確定しましたか")).toEqual([budget.id]);
    expect(await ids("cost", axis(0))).toEqual([budget.id, lunch.id]);
    // A word match plus a weaker vector match outranks a vector-only match.
    expect(await ids("lunch", axis(0))).toEqual([lunch.id, budget.id]);
    // Another model's vectors are not used, and reconciliation queues the current model.
    const other = createPostgresAuthStore(db, "postgres", { model: "next-model", dimensions: 32 }).memory!;
    expect((await other.recall(owner.userId, workspaceId, "cost", lindera, 20, axis(0))).hits).toEqual([]);
    await other.reconcilePage(workspaceId, lindera);
    expect((await db.select().from(schema.backgroundJob).where(eq(schema.backgroundJob.dedupeKey, `memory-index:workspace:${budget.id}`)))[0]?.payload)
      .toMatchObject({ model: "next-model" });
    // An analyzer change rewrites chunks through the Workspace maintenance context, without a user identity.
    const intl = applicationAnalyzer((await import("../src/search/tokenizer")).createIntlSearchTokenizer());
    expect(await memory.reconcilePage(workspaceId, intl)).toBeUndefined();
    expect((await memory.recall(owner.userId, workspaceId, "予算", intl, 20)).hits.map((row) => row.id)).toEqual([budget.id]);
  });
  it.each(["personal", "workspace"] as const)("does not let an analyzer rebuild overwrite a concurrent save (%s)", async (kind) => {
    const concurrent = connectPostgresUrl(url!, 4);
    const { db, pool } = concurrent;
    const app = createPostgresAuthStore(db, "postgres");
    const owner: Identity = { userId: uuidV7(), source: "header" };
    await seedPostgresIdentity(app, url!, owner);
    let scopeId = owner.userId;
    if (kind === "workspace") {
      scopeId = uuidV7();
      await new MeetingSyncService(app.sync).commitTransaction(owner, { schemaVersion: 3, workspaceId: scopeId, id: uuidV7(), createdAt: new Date().toISOString(),
        operations: [{ id: uuidV7(), entity: "workspace", action: "create", entityId: scopeId, baseRevision: null,
          data: { organizationId: testOrganizationID, name: "Rebuild race", createdAt: new Date().toISOString() } }] });
    }
    const memory = kind === "personal" ? app.personalMemory! : app.memory!;
    const table = kind === "personal" ? "personal_memory_chunks" : "shared_memory_chunks";
    const intl = applicationAnalyzer((await import("../src/search/tokenizer")).createIntlSearchTokenizer());
    const note = await memory.saveNote(owner.userId, scopeId, { id: uuidV7(), revision: 0, content: "古い予算の記録" }, "human", false, intl);
    const blocker = await pool.connect();
    let rebuilding: Promise<unknown> | undefined, saving: Promise<unknown> | undefined;
    try {
      // Hold the rebuild after it read the old content and before it writes the old chunks.
      await blocker.query(`CREATE FUNCTION pg_temp.rebuild_barrier() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN IF NEW.chunk_text LIKE '%古い%' AND NEW.analyzer = TG_ARGV[0] THEN PERFORM pg_advisory_xact_lock(899179); END IF; RETURN NEW; END $$`);
      await blocker.query(`CREATE TRIGGER rebuild_barrier BEFORE INSERT ON search.${table} FOR EACH ROW EXECUTE FUNCTION pg_temp.rebuild_barrier('${lindera.id}')`);
      await blocker.query("SELECT pg_advisory_lock(899179)");
      rebuilding = memory.reconcilePage(scopeId, lindera);
      await vi.waitFor(async () => {
        expect((await pool.query("SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND objid = 899179 AND NOT granted")).rowCount).toBe(1);
      });
      saving = memory.saveNote(owner.userId, scopeId, { id: note.id, revision: 1, content: "新しい休暇の記録" }, "human", false, lindera);
      // The save must wait for the rebuild instead of committing underneath it.
      await vi.waitFor(async () => {
        expect((await pool.query("SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND objid <> 899179")).rowCount).toBeGreaterThan(0);
      });
      await blocker.query("SELECT pg_advisory_unlock(899179)");
      await rebuilding; await saving;
      const ids = (query: string) => memory.recall(owner.userId, scopeId, query, lindera, 20).then(({ hits }) => hits.map((row) => row.id));
      expect(await ids("休暇")).toEqual([note.id]);
      expect(await ids("古い")).toEqual([]);
      // Reconciling again keeps the projection consistent.
      await memory.reconcilePage(scopeId, lindera);
      expect(await ids("休暇")).toEqual([note.id]);
      expect(await ids("古い")).toEqual([]);
      // A projection left stale by an earlier version (old text, older revision, current analyzer) is repaired too.
      await db.transaction(async (tx) => {
        await tx.execute(kind === "personal" ? sql`select set_config('app.user_id', ${owner.userId}, true)`
          : sql`select set_config('app.maintenance', 'search', true), set_config('app.maintenance_workspace_id', ${scopeId}, true)`);
        await tx.execute(sql`update ${sql.raw(`search.${table}`)} set chunk_text = '古い予算の記録', search_text = '古い', search_vector = to_tsvector('simple', '古い'),
          memory_revision = memory_revision - 1 where memory_id = ${note.id}`);
      });
      expect(await ids("古い")).toEqual([note.id]);
      await memory.reconcilePage(scopeId, lindera);
      expect(await ids("休暇")).toEqual([note.id]);
      expect(await ids("古い")).toEqual([]);
    } finally {
      await blocker.query("SELECT pg_advisory_unlock(899179)");
      await Promise.allSettled([rebuilding, saving]);
      await blocker.query(`DROP TRIGGER IF EXISTS rebuild_barrier ON search.${table}`);
      await blocker.query("DROP FUNCTION IF EXISTS pg_temp.rebuild_barrier()");
      blocker.release();
      await concurrent.close();
    }
  });
  it("splits unbroken Japanese runs over the parser token limit for a database-side analyzer", async () => {
    const { db } = connection!;
    const app = createPostgresAuthStore(db, "postgres");
    const owner: Identity = { userId: uuidV7(), source: "header" };
    await seedPostgresIdentity(app, url!, owner);
    // PostgreSQL's parser skips tokens over 2,047 bytes like Lakebase's; the simple configuration stands in for tokenizer_japanese.
    const databaseSide = { id: "test-database-side/simple", config: "simple", matchAll: false };
    const run = ["ア", "か", "ア"].map((char) => char.repeat(600));
    const memory = app.personalMemory!;
    const note = await memory.saveNote(owner.userId, owner.userId, { id: uuidV7(), revision: 0, content: run.join("") }, "human", false, databaseSide);
    expect((await memory.recall(owner.userId, owner.userId, run[1]!, databaseSide, 20)).hits.map((row) => row.id)).toEqual([note.id]);
  });
  it("serializes a pending save against purge", async () => {
    const concurrent = connectPostgresUrl(url!, 4);
    const { db, pool } = concurrent;
    const app = createPostgresAuthStore(db, "postgres");
    const owner: Identity = { userId: uuidV7(), source: "header" };
    await seedPostgresIdentity(app, url!, owner);
    const workspaceId = uuidV7(), noteId = uuidV7();
    await new MeetingSyncService(app.sync).commitTransaction(owner, { schemaVersion: 3, workspaceId,
      id: uuidV7(), createdAt: new Date().toISOString(), operations: [{ id: uuidV7(), entity: "workspace",
        action: "create", entityId: workspaceId, baseRevision: null,
        data: { organizationId: testOrganizationID, name: "Concurrent memory", createdAt: new Date().toISOString() } }] });
    const memory = app.memory!;
    const blocker = await pool.connect();
    const input = { id: noteId, revision: 0, content: "Confirmed shared note" };
    let saving: Promise<unknown> | undefined, changing: Promise<unknown> | undefined;
    try {
      await blocker.query(`CREATE FUNCTION pg_temp.memory_save_barrier() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN IF NEW.id::text = TG_ARGV[0] THEN PERFORM pg_advisory_xact_lock(899178); END IF; RETURN NEW; END $$`);
      await blocker.query(`CREATE TRIGGER memory_save_barrier BEFORE INSERT ON app.shared_memories
        FOR EACH ROW EXECUTE FUNCTION pg_temp.memory_save_barrier('${noteId}')`);
      await blocker.query("SELECT pg_advisory_lock(899178)");
      saving = memory.saveNote(owner.userId, workspaceId, input);
      await vi.waitFor(async () => {
        expect((await pool.query("SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND objid = 899178 AND NOT granted")).rowCount).toBe(1);
      });
      changing = memory.purge(owner.userId, workspaceId);
      // Purge must wait for the canonical write, not commit ahead of it and leave the late note behind.
      await vi.waitFor(async () => {
        expect((await pool.query("SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND objid <> 899178")).rowCount).toBeGreaterThan(0);
      });
      await blocker.query("SELECT pg_advisory_unlock(899178)");
      await saving; await changing;
      expect(await memory.listNotes(owner.userId, workspaceId)).toHaveLength(0);
    } finally {
      await blocker.query("SELECT pg_advisory_unlock(899178)");
      await Promise.allSettled([saving, changing]);
      await blocker.query("DROP TRIGGER IF EXISTS memory_save_barrier ON app.shared_memories");
      await blocker.query("DROP FUNCTION IF EXISTS pg_temp.memory_save_barrier()");
      blocker.release();
      await concurrent.close();
    }
  });

});
