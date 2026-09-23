import { and, asc, eq, gt, isNull, lt, lte, or, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as pg from "../db/auth-schema";
import * as sqlite from "../db/sqlite-schema";
import { workspacePermissions } from "../auth/workspace-permissions";
import { lockAuthorization } from "../auth/authorization";
import { RequestError } from "../storage/upload";
import { uuidV7 } from "../id";
import { enqueueMemorySource } from "./enqueue";
import type { MemoryOperation, MemorySource } from "./model";

export type MemoryState = typeof pg.workspaceMemoryState.$inferSelect;
export type MemorySourceJob = typeof pg.memorySourceJob.$inferSelect;
export type SharedMemory = typeof pg.sharedMemory.$inferSelect;
export type MemoryStore = ReturnType<typeof createMemoryStore>;

export function createMemoryStore(database: PostgresDatabase | SQLiteDatabase | NodePgDatabase, isPostgres: boolean, personal = false) {
  const db = database as NodePgDatabase;
  const base = (isPostgres ? pg : sqlite) as typeof pg;
  const schema = (personal ? { ...base, workspaceMemoryState: base.personalMemoryState,
    memoryDocument: base.personalMemoryDocument, memorySourceJob: base.personalMemorySourceJob, sharedMemory: base.personalMemory } : base) as typeof pg;
  const state = schema.workspaceMemoryState;
  const docs = schema.memoryDocument;
  const notes = schema.sharedMemory;
  const jobs = schema.memorySourceJob;
  const scoped = <T>(userId: string, scopeId: string, role: "read" | "write" | "admin", fn: (tx: NodePgDatabase) => Promise<T>) =>
    db.transaction(async (tx) => {
      if (isPostgres) await tx.execute(sql`select set_config('app.user_id', ${userId}, true)`);
      // ponytail: reuse the global mutation lock; split by workspace if write throughput requires it.
      if (role !== "read") await lockAuthorization(tx, schema, isPostgres);
      if (personal) {
        if (scopeId !== userId || !(await tx.select({ id: schema.user.id }).from(schema.user).where(eq(schema.user.id, userId))).length) {
          throw new RequestError(404, "memory_scope_not_found");
        }
        return fn(tx);
      }
      const w = schema.syncedWorkspace;
      const [workspace] = await tx.select({ encryption: w.encryption }).from(w).where(and(eq(w.workspaceId, scopeId),
        isNull(w.deletingAt), workspacePermissions(tx, schema, userId)[role](w.workspaceId)));
      if (!workspace) throw new RequestError(404, "workspace_not_found");
      if (workspace.encryption === "server") throw new RequestError(409, "memory_encrypted_workspace_unsupported");
      return fn(tx);
    });
  return {
    personal,
    async status(userId: string, scopeId: string) {
      return scoped(userId, scopeId, "read", async (tx) => {
        const [row] = await tx.select().from(state).where(eq(state.scopeId, scopeId));
        return row ?? null;
      });
    },
    async configure(userId: string, scopeId: string, bankId: string, enabled: boolean) {
      return scoped(userId, scopeId, "admin", async (tx) => {
        const [current] = await tx.select().from(state).where(eq(state.scopeId, scopeId));
        if (current && (current.bankId !== bankId || current.purge)) throw new RequestError(409, "memory_cleanup_required");
        await tx.insert(state).values({ scopeId, requestedBy: userId, bankId, enabled, availableAt: new Date() })
          .onConflictDoUpdate({ target: state.scopeId, set: { enabled, reconcile: true, requestedBy: userId, availableAt: new Date(),
            generation: sql`${state.generation} + 1`, status: enabled ? "pending" : "paused", attempts: 0, errorCode: null } });
      });
    },
    async purge(userId: string, scopeId: string) {
      await scoped(userId, scopeId, "admin", async (tx) => {
        await tx.delete(notes).where(eq(notes.scopeId, scopeId));
        await tx.update(state).set({ enabled: false, purge: true, status: "deleting", availableAt: new Date(),
          generation: sql`${state.generation} + 1` }).where(eq(state.scopeId, scopeId));
      });
    },
    async listNotes(userId: string, scopeId: string, after?: string, query?: string) {
      return scoped(userId, scopeId, "read", (tx) => tx.select().from(notes).where(and(eq(notes.scopeId, scopeId),
        query ? (isPostgres ? sql`strpos(lower(${notes.content}), lower(${query})) > 0` : sql`instr(lower(${notes.content}), lower(${query})) > 0`) : undefined,
        after ? gt(notes.id, after) : undefined)).orderBy(asc(notes.id)).limit(100));
    },
    async getNote(userId: string, scopeId: string, id: string) {
      return scoped(userId, scopeId, "read", async (tx) => (await tx.select().from(notes)
        .where(and(eq(notes.scopeId, scopeId), eq(notes.id, id))))[0] ?? null);
    },
    async saveNote(userId: string, scopeId: string, input: { id: string; revision: number; content: string }, actor: "human" | "agent" = "human", explicit = false, canonical = false) {
      return scoped(userId, scopeId, "write", async (tx) => {
        const [setting] = await tx.select().from(state).where(eq(state.scopeId, scopeId));
        if (setting?.purge || (!canonical && (!setting || (!setting.enabled && input.revision === 0)))) throw new RequestError(409, "memory_disabled");
        const [existing] = await tx.select().from(notes).where(eq(notes.id, input.id));
        if (existing && existing.scopeId !== scopeId) throw new RequestError(409, "memory_revision_conflict");
        if (actor === "agent" && existing?.protected && !explicit) throw new RequestError(409, "memory_human_edit_protected");
        if (existing?.content === input.content && existing.revision === input.revision + 1
          && (actor !== "human" || existing.protected)) return existing;
        let result: SharedMemory | undefined;
        if (input.revision === 0) {
          [result] = await tx.insert(notes).values({ id: input.id, scopeId, createdBy: userId, content: input.content, protected: actor === "human", updatedAt: new Date() })
            .onConflictDoNothing().returning();
        } else {
          [result] = await tx.update(notes).set({ content: input.content, revision: input.revision + 1, protected: actor === "human" || existing?.protected === true, updatedAt: new Date() })
            .where(and(eq(notes.id, input.id), eq(notes.scopeId, scopeId), eq(notes.revision, input.revision))).returning();
        }
        if (!result) throw new RequestError(409, "memory_revision_conflict");
        await enqueueMemorySource(tx, schema, scopeId, "shared", input.id);
        return result;
      });
    },
    async deleteNote(userId: string, scopeId: string, id: string, revision: number) {
      await scoped(userId, scopeId, "write", async (tx) => {
        const rows = await tx.delete(notes).where(and(eq(notes.scopeId, scopeId), eq(notes.id, id), eq(notes.revision, revision))).returning();
        if (!rows.length) throw new RequestError(409, "memory_revision_conflict");
        await enqueueMemorySource(tx, schema, scopeId, "shared", id);
      });
    },
    async nextDelay(scopeId: string) {
      const [row] = await db.select().from(state).where(eq(state.scopeId, scopeId));
      return row && (row.purge || (row.enabled && (row.reconcile || row.generation !== row.indexedGeneration)))
        ? Math.max(5, Math.ceil((row.availableAt.getTime() - Date.now()) / 1000)) : undefined;
    },
    async due(after?: string) {
      return (await db.select({ id: state.scopeId }).from(state).where(and(after ? gt(state.scopeId, after) : undefined,
        lte(state.availableAt, new Date()), or(isNull(state.leaseUntil), lt(state.leaseUntil, new Date()))))
        .orderBy(asc(state.scopeId)).limit(100)).map((row) => row.id);
    },
    async workerUser(scopeId: string) {
      if (personal) return await this.exists(scopeId) ? scopeId : undefined;
      return db.transaction(async (tx) => {
        if (isPostgres) await tx.execute(sql`select set_config('app.maintenance', 'search', true), set_config('app.maintenance_workspace_id', ${scopeId}, true)`);
        const [user] = await tx.select({ id: schema.user.id }).from(schema.user)
          .innerJoin(state, eq(state.scopeId, scopeId))
          .where(workspacePermissions(tx, schema, schema.user.id).admin(state.scopeId)).orderBy(asc(schema.user.id)).limit(1);
        return user?.id;
      });
    },
    async exists(scopeId: string) {
      if (personal) return (await db.select({ id: schema.user.id }).from(schema.user).where(eq(schema.user.id, scopeId))).length > 0;
      return db.transaction(async (tx) => {
        if (isPostgres) await tx.execute(sql`select set_config('app.maintenance', 'search', true), set_config('app.maintenance_workspace_id', ${scopeId}, true)`);
        return (await tx.select({ id: schema.syncedWorkspace.workspaceId }).from(schema.syncedWorkspace)
          .where(and(eq(schema.syncedWorkspace.workspaceId, scopeId), isNull(schema.syncedWorkspace.deletingAt)))).length > 0;
      });
    },
    async claim(scopeId: string) {
      const [row] = await db.update(state).set({ lease: uuidV7(), leaseUntil: new Date(Date.now() + 120_000) })
        .where(and(eq(state.scopeId, scopeId), lte(state.availableAt, new Date()),
          or(isNull(state.leaseUntil), lt(state.leaseUntil, new Date())))).returning();
      return row;
    },
    async release(job: MemoryState, patch: Partial<MemoryState> = {}) {
      // Source edits may advance generation, but must not discard a scan or an in-flight operation.
      await db.update(state).set({ availableAt: new Date(Date.now() + 5_000), ...patch })
        .where(and(eq(state.scopeId, job.scopeId), eq(state.lease, job.lease!), eq(state.generation, job.generation)));
      await db.update(state).set({ ...(patch.progress !== undefined ? { progress: patch.progress } : {}), lease: null, leaseUntil: null })
        .where(and(eq(state.scopeId, job.scopeId), eq(state.lease, job.lease!)));
    },
    async setProgress(job: MemoryState, progress: MemoryState["progress"]) {
      const rows = await db.update(state).set({ progress }).where(and(eq(state.scopeId, job.scopeId),
        eq(state.lease, job.lease!))).returning();
      if (!rows.length) throw new RequestError(409, "memory_lease_changed");
    },
    async startScan(job: MemoryState, progress: NonNullable<MemoryState["progress"]>) {
      await db.update(state).set({ reconcile: false, progress }).where(and(eq(state.scopeId, job.scopeId),
        eq(state.lease, job.lease!), eq(state.generation, job.generation)));
    },
    enqueue(scopeId: string, kind: "meeting" | "shared", sourceId: string) {
      return db.transaction((tx) => enqueueMemorySource(tx, schema, scopeId, kind, sourceId, true));
    },
    async pending(scopeId: string, documentId?: string) {
      return (await db.select().from(jobs).where(and(eq(jobs.scopeId, scopeId),
        documentId ? eq(jobs.documentId, documentId) : undefined)).orderBy(sql`${jobs.operation} IS NOT NULL DESC`, asc(jobs.documentId)).limit(1))[0];
    },
    async setOperation(job: MemorySourceJob, operation: MemoryOperation | null) {
      await db.update(jobs).set({ operation }).where(and(eq(jobs.scopeId, job.scopeId), eq(jobs.documentId, job.documentId)));
    },
    async finishSource(job: MemorySourceJob) {
      await db.delete(jobs).where(and(eq(jobs.scopeId, job.scopeId), eq(jobs.documentId, job.documentId), eq(jobs.generation, job.generation)));
      await db.update(jobs).set({ operation: null }).where(and(eq(jobs.scopeId, job.scopeId), eq(jobs.documentId, job.documentId)));
    },
    async documents(scopeId: string, after?: string) {
      return db.select().from(docs).where(and(eq(docs.scopeId, scopeId), after ? gt(docs.documentId, after) : undefined))
        .orderBy(asc(docs.documentId)).limit(100);
    },
    async document(scopeId: string, id: string) {
      return (await db.select().from(docs).where(and(eq(docs.scopeId, scopeId), eq(docs.documentId, id))))[0];
    },
    async saveDocument(job: MemoryState, id: string, source: MemorySource, contentHash: string) {
      await db.insert(docs).values({ scopeId: job.scopeId, documentId: id, source, contentHash, generation: job.generation })
        .onConflictDoUpdate({ target: [docs.scopeId, docs.documentId], set: { source, contentHash, generation: job.generation } });
    },
    async forgetDocument(scopeId: string, id: string) {
      await db.delete(docs).where(and(eq(docs.scopeId, scopeId), eq(docs.documentId, id)));
    },
    async purged(job: MemoryState) {
      await db.transaction(async (tx) => {
        await tx.delete(docs).where(eq(docs.scopeId, job.scopeId));
        await tx.delete(jobs).where(eq(jobs.scopeId, job.scopeId));
        await tx.delete(state).where(and(eq(state.scopeId, job.scopeId), eq(state.lease, job.lease!)));
      });
    },
  };
}
