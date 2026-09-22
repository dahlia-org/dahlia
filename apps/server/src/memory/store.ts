import { and, asc, eq, gt, isNull, lt, lte, ne, or, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as pg from "../db/auth-schema";
import * as sqlite from "../db/sqlite-schema";
import { workspacePermissions } from "../auth/workspace-permissions";
import { lockAuthorization } from "../auth/authorization";
import { RequestError } from "../storage/upload";
import { uuidV7 } from "../id";
import type { MemorySource } from "./model";

export type MemoryState = typeof pg.workspaceMemoryState.$inferSelect;
export type SharedMemory = typeof pg.sharedMemory.$inferSelect;
export type MemoryStore = ReturnType<typeof createMemoryStore>;

export function createMemoryStore(database: PostgresDatabase | SQLiteDatabase | NodePgDatabase, isPostgres: boolean) {
  const db = database as NodePgDatabase;
  const schema = (isPostgres ? pg : sqlite) as typeof pg;
  const state = schema.workspaceMemoryState;
  const docs = schema.memoryDocument;
  const notes = schema.sharedMemory;
  const scoped = <T>(userId: string, workspaceId: string, role: "read" | "write" | "admin", fn: (tx: NodePgDatabase) => Promise<T>) =>
    db.transaction(async (tx) => {
      if (isPostgres) await tx.execute(sql`select set_config('app.user_id', ${userId}, true)`);
      // ponytail: reuse the global mutation lock; split by workspace if write throughput requires it.
      if (role !== "read") await lockAuthorization(tx, schema, isPostgres);
      const w = schema.syncedWorkspace;
      const [workspace] = await tx.select({ encryption: w.encryption }).from(w).where(and(eq(w.workspaceId, workspaceId),
        isNull(w.deletingAt), workspacePermissions(tx, schema, userId)[role](w.workspaceId)));
      if (!workspace) throw new RequestError(404, "workspace_not_found");
      if (workspace.encryption === "server") throw new RequestError(409, "memory_encrypted_workspace_unsupported");
      return fn(tx);
    });
  const invalidate = (tx: NodePgDatabase, workspaceId: string) => tx.update(state).set({
    generation: sql`${state.generation} + 1`, status: "pending", availableAt: new Date(), attempts: 0, errorCode: null,
  }).where(eq(state.workspaceId, workspaceId));
  return {
    async status(userId: string, workspaceId: string) {
      return scoped(userId, workspaceId, "read", async (tx) => {
        const [row] = await tx.select().from(state).where(eq(state.workspaceId, workspaceId));
        return row ?? null;
      });
    },
    async configure(userId: string, workspaceId: string, bankId: string, enabled: boolean) {
      return scoped(userId, workspaceId, "admin", async (tx) => {
        const [current] = await tx.select().from(state).where(eq(state.workspaceId, workspaceId));
        if (current && (current.bankId !== bankId || current.purge)) throw new RequestError(409, "memory_cleanup_required");
        await tx.insert(state).values({ workspaceId, requestedBy: userId, bankId, enabled, availableAt: new Date() })
          .onConflictDoUpdate({ target: state.workspaceId, set: { enabled, requestedBy: userId, availableAt: new Date(),
            generation: sql`${state.generation} + 1`, status: enabled ? "pending" : "paused", attempts: 0, errorCode: null } });
      });
    },
    async purge(userId: string, workspaceId: string) {
      await scoped(userId, workspaceId, "admin", async (tx) => {
        await tx.delete(notes).where(eq(notes.workspaceId, workspaceId));
        await tx.update(state).set({ enabled: false, purge: true, status: "deleting", availableAt: new Date(),
          generation: sql`${state.generation} + 1` }).where(eq(state.workspaceId, workspaceId));
      });
    },
    async listNotes(userId: string, workspaceId: string, after?: string) {
      return scoped(userId, workspaceId, "read", (tx) => tx.select().from(notes).where(and(eq(notes.workspaceId, workspaceId),
        after ? gt(notes.id, after) : undefined)).orderBy(asc(notes.id)).limit(100));
    },
    async getNote(userId: string, workspaceId: string, id: string) {
      return scoped(userId, workspaceId, "read", async (tx) => (await tx.select().from(notes)
        .where(and(eq(notes.workspaceId, workspaceId), eq(notes.id, id))))[0] ?? null);
    },
    async saveNote(userId: string, workspaceId: string, input: { id: string; revision: number; content: string }) {
      return scoped(userId, workspaceId, "write", async (tx) => {
        const [setting] = await tx.select().from(state).where(eq(state.workspaceId, workspaceId));
        if (!setting || setting.purge || (!setting.enabled && input.revision === 0)) throw new RequestError(409, "memory_disabled");
        const [existing] = await tx.select().from(notes).where(eq(notes.id, input.id));
        if (existing && existing.workspaceId !== workspaceId) throw new RequestError(409, "memory_revision_conflict");
        if (existing?.content === input.content && existing.revision === input.revision + 1) return existing;
        let result: SharedMemory | undefined;
        if (input.revision === 0) {
          [result] = await tx.insert(notes).values({ id: input.id, workspaceId, createdBy: userId, content: input.content, updatedAt: new Date() })
            .onConflictDoNothing().returning();
        } else {
          [result] = await tx.update(notes).set({ content: input.content, revision: input.revision + 1, updatedAt: new Date() })
            .where(and(eq(notes.id, input.id), eq(notes.workspaceId, workspaceId), eq(notes.revision, input.revision))).returning();
        }
        if (!result) throw new RequestError(409, "memory_revision_conflict");
        await invalidate(tx, workspaceId);
        return result;
      });
    },
    async deleteNote(userId: string, workspaceId: string, id: string, revision: number) {
      await scoped(userId, workspaceId, "write", async (tx) => {
        const rows = await tx.delete(notes).where(and(eq(notes.workspaceId, workspaceId), eq(notes.id, id), eq(notes.revision, revision))).returning();
        if (!rows.length) throw new RequestError(409, "memory_revision_conflict");
        await invalidate(tx, workspaceId);
      });
    },
    async nextDelay(workspaceId: string) {
      const [row] = await db.select().from(state).where(eq(state.workspaceId, workspaceId));
      return row && (row.purge || (row.enabled && row.generation !== row.indexedGeneration))
        ? Math.max(5, Math.ceil((row.availableAt.getTime() - Date.now()) / 1000)) : undefined;
    },
    async due(after?: string) {
      return (await db.select({ id: state.workspaceId }).from(state).where(and(after ? gt(state.workspaceId, after) : undefined,
        lte(state.availableAt, new Date()), or(isNull(state.leaseUntil), lt(state.leaseUntil, new Date()))))
        .orderBy(asc(state.workspaceId)).limit(100)).map((row) => row.id);
    },
    async workerUser(workspaceId: string) {
      return db.transaction(async (tx) => {
        if (isPostgres) await tx.execute(sql`select set_config('app.maintenance', 'search', true), set_config('app.maintenance_workspace_id', ${workspaceId}, true)`);
        const [user] = await tx.select({ id: schema.user.id }).from(schema.user)
          .innerJoin(state, eq(state.workspaceId, workspaceId))
          .where(workspacePermissions(tx, schema, schema.user.id).admin(state.workspaceId)).orderBy(asc(schema.user.id)).limit(1);
        return user?.id;
      });
    },
    async exists(workspaceId: string) {
      return db.transaction(async (tx) => {
        if (isPostgres) await tx.execute(sql`select set_config('app.maintenance', 'search', true), set_config('app.maintenance_workspace_id', ${workspaceId}, true)`);
        return (await tx.select({ id: schema.syncedWorkspace.workspaceId }).from(schema.syncedWorkspace)
          .where(and(eq(schema.syncedWorkspace.workspaceId, workspaceId), isNull(schema.syncedWorkspace.deletingAt)))).length > 0;
      });
    },
    async claim(workspaceId: string) {
      const [row] = await db.update(state).set({ lease: uuidV7(), leaseUntil: new Date(Date.now() + 120_000) })
        .where(and(eq(state.workspaceId, workspaceId), lte(state.availableAt, new Date()),
          or(isNull(state.leaseUntil), lt(state.leaseUntil, new Date())))).returning();
      return row;
    },
    async release(job: MemoryState, patch: Partial<MemoryState> = {}) {
      // Never overwrite an invalidation committed while the external request was running.
      await db.update(state).set({ lease: null, leaseUntil: null, availableAt: new Date(Date.now() + 5_000), ...patch })
        .where(and(eq(state.workspaceId, job.workspaceId), eq(state.lease, job.lease!), eq(state.generation, job.generation)));
      await db.update(state).set({ lease: null, leaseUntil: null }).where(and(eq(state.workspaceId, job.workspaceId), eq(state.lease, job.lease!)));
    },
    async setProgress(job: MemoryState, progress: MemoryState["progress"]) {
      const rows = await db.update(state).set({ progress }).where(and(eq(state.workspaceId, job.workspaceId),
        eq(state.lease, job.lease!), eq(state.generation, job.generation))).returning();
      if (!rows.length) throw new RequestError(409, "memory_generation_changed");
    },
    async documents(workspaceId: string, after?: string) {
      return db.select().from(docs).where(and(eq(docs.workspaceId, workspaceId), after ? gt(docs.documentId, after) : undefined))
        .orderBy(asc(docs.documentId)).limit(100);
    },
    async document(workspaceId: string, id: string) {
      return (await db.select().from(docs).where(and(eq(docs.workspaceId, workspaceId), eq(docs.documentId, id))))[0];
    },
    async confirmDocument(workspaceId: string, id: string, generation: number) {
      await db.update(docs).set({ generation }).where(and(eq(docs.workspaceId, workspaceId), eq(docs.documentId, id), eq(docs.generation, -generation)));
    },
    async saveDocument(job: MemoryState, id: string, source: MemorySource, contentHash: string, pending = false) {
      await db.insert(docs).values({ workspaceId: job.workspaceId, documentId: id, source, contentHash, generation: pending ? -job.generation : job.generation })
        .onConflictDoUpdate({ target: [docs.workspaceId, docs.documentId], set: { source, contentHash, generation: pending ? -job.generation : job.generation } });
    },
    async obsolete(job: MemoryState) {
      return db.select().from(docs).where(and(eq(docs.workspaceId, job.workspaceId), ne(docs.generation, job.generation))).limit(1);
    },
    async forgetDocument(workspaceId: string, id: string) {
      await db.delete(docs).where(and(eq(docs.workspaceId, workspaceId), eq(docs.documentId, id)));
    },
    async purged(job: MemoryState) {
      await db.transaction(async (tx) => {
        await tx.delete(docs).where(eq(docs.workspaceId, job.workspaceId));
        await tx.delete(state).where(and(eq(state.workspaceId, job.workspaceId), eq(state.lease, job.lease!)));
      });
    },
  };
}
