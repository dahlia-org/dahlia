import { afterAll, describe, expect, it, vi } from "vitest";
import { sql } from "drizzle-orm";
import { createPostgresAuthStore } from "../src/auth/store";
import { connectPostgresUrl } from "../src/db/postgres";
import { MeetingSyncService } from "../src/sync/service";
import { uuidV7 } from "../src/id";
import { seedPostgresIdentity, testOrganizationID } from "./public-test-client";
import type { Identity } from "../src/auth/identity";

const url = process.env.TEST_DATABASE_URL;
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
    const note = await memory.saveNote(owner.userId, owner.userId, { id: uuidV7(), revision: 0, content: "Private lesson" }, "human", true, true);
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
  it("isolates content, resolves a live worker admin and clears transaction-local identity on a shared pool", async () => {
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
    await memory.configure(owner.userId, workspaceId, `test-workspace-${workspaceId}`, true);
    const note = await memory.saveNote(owner.userId, workspaceId, { id: uuidV7(), content: "Private Workspace evidence", revision: 0 });
    expect(await memory.exists(workspaceId)).toBe(true);
    expect(await memory.workerUser(workspaceId)).toBe(owner.userId);
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
    const pending = (await memory.pending(workspaceId))!;
    await memory.setOperation(pending, { id: uuidV7(), generation: pending.generation,
      source: { kind: "shared", id: note.id, revision: "1", projectId: null }, contentHash: "hash", attempts: 0 });
    await memory.saveNote(owner.userId, workspaceId, { id: note.id, revision: 1, content: "Updated evidence" });
    expect((await memory.pending(workspaceId))!.operation?.generation).toBe(pending.generation);
    await memory.finishSource(pending);
    const updated = (await memory.pending(workspaceId))!;
    expect(updated.generation).toBe(pending.generation + 1);
    expect(updated.operation).toBeNull();
    await memory.finishSource(updated);
    expect(await memory.pending(workspaceId)).toBeUndefined();
    await memory.deleteNote(owner.userId, workspaceId, note.id, 2);
  });
  it.each(["purge", "pause"])("serializes a pending save against %s and rejects late retries", async (action) => {
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
    const memory = app.memory!, bankId = `test-workspace-${workspaceId}`;
    await memory.configure(owner.userId, workspaceId, bankId, true);
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
      changing = action === "purge" ? memory.purge(owner.userId, workspaceId)
        : memory.configure(owner.userId, workspaceId, bankId, false);
      // Both lifecycle operations must wait for the canonical write, not commit ahead of it.
      await vi.waitFor(async () => {
        expect((await pool.query("SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND objid <> 899178")).rowCount).toBeGreaterThan(0);
      });
      await blocker.query("SELECT pg_advisory_unlock(899178)");
      await saving; await changing;
      expect(await memory.listNotes(owner.userId, workspaceId)).toHaveLength(action === "purge" ? 0 : 1);
      await expect(memory.saveNote(owner.userId, workspaceId, input)).rejects.toMatchObject({ status: 409 });
      if (action === "pause") {
        await memory.configure(owner.userId, workspaceId, bankId, true);
        expect((await memory.saveNote(owner.userId, workspaceId, input)).revision).toBe(1);
      }
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
