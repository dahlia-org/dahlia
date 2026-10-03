import { createJobStore, type BackgroundJob } from "../jobs/store";
import { claimKey, lockJob, settleJob } from "../jobs/state";
import { defaultJobLimits } from "../jobs/model";
import { and, exists, asc, eq, gt, inArray, isNull, lte, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as pg from "../db/auth-schema";
import * as sqlite from "../db/sqlite-schema";
import { workspacePermissions } from "../auth/workspace-permissions";
import { lockAuthorization } from "../auth/authorization";
import { RequestError } from "../storage/upload";
import { enqueueMemoryScope, enqueueMemorySource } from "./enqueue";
import type { MemoryProgress, MemoryOperation, MemorySource } from "./model";
import type { PageSnapshot, PageStatus, PageOperation } from "./pages-model";

export type KnowledgePageRecord = typeof pg.knowledgePage.$inferSelect;
export type MemoryState = typeof pg.workspaceMemoryState.$inferSelect & {
  queue?: BackgroundJob; lease: string | null; leaseUntil: Date | null; availableAt: Date; attempts: number; errorCode: string | null;
};
export type MemorySourceJob = typeof pg.memorySourceJob.$inferSelect;
export type SharedMemory = typeof pg.sharedMemory.$inferSelect;
export type MemoryStore = ReturnType<typeof createMemoryStore>;

export function createMemoryStore(database: PostgresDatabase | SQLiteDatabase | NodePgDatabase, isPostgres: boolean, personal = false) {
  const db = database as NodePgDatabase;
  const base = (isPostgres ? pg : sqlite) as typeof pg;
  const schema = (personal ? { ...base, workspaceMemoryState: base.personalMemoryState,
    memoryDocument: base.personalMemoryDocument, memorySourceJob: base.personalMemorySourceJob, sharedMemory: base.personalMemory } : base) as typeof pg;
  const state = schema.workspaceMemoryState;
  const q = schema.backgroundJob;
  const queue = createJobStore(database, isPostgres, defaultJobLimits);
  const dispatchKind = personal ? "personal-memory" : "workspace-memory";
  const leaseKey = (job: MemoryState) => exists(db.select({ id: q.id }).from(q).where(and(eq(q.id, job.queue!.id),
    eq(q.lease, job.lease!), gt(q.leaseUntil, new Date()))));
  const decorate = (row: typeof state.$inferSelect, job: BackgroundJob): MemoryState => ({ ...row, queue: job,
    lease: job.lease, leaseUntil: job.leaseUntil, availableAt: job.availableAt, attempts: Math.max(0, job.attempts - 1), errorCode: job.lastError });
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
    async ensurePages(userId: string, scopeId: string) {
      return scoped(userId, scopeId, "admin", async (tx) => {
        const projects = await tx.select({ id: base.syncedProject.projectId }).from(base.syncedProject).where(eq(base.syncedProject.workspaceId, scopeId));
        const values = [{ scopeId, id: "workspace-insights", projectId: null as string | null },
          ...projects.map(({ id }) => ({ scopeId, id: `project-${id}`, projectId: id }))];
        for (const value of values) await tx.insert(base.knowledgePage).values(value).onConflictDoNothing();
      });
    },
    async pages(userId: string, scopeId: string, after?: string, projectId?: string, limit = 20) {
      const p = base.knowledgePage;
      return scoped(userId, scopeId, "read", (tx) => tx.select().from(p).where(and(eq(p.scopeId, scopeId),
        after ? gt(p.id, after) : undefined, projectId ? eq(p.projectId, projectId) : undefined)).orderBy(asc(p.id)).limit(limit));
    },
    async page(userId: string, scopeId: string, id: string) {
      const p = base.knowledgePage;
      return scoped(userId, scopeId, "read", async (tx) => (await tx.select().from(p).where(and(eq(p.scopeId, scopeId), eq(p.id, id))))[0]);
    },
    async publications(userId: string, scopeId: string, generation: number, ids: string[]) {
      if (!ids.length) return [];
      const p = base.knowledgePage, w = base.syncedWorkspace;
      // One final statement fences the response against canonical mutations and regeneration requests.
      return scoped(userId, scopeId, "read", (tx) => tx.select({ id: p.id, snapshot: p.snapshot }).from(p)
        .innerJoin(state, eq(state.scopeId, p.scopeId)).innerJoin(w, eq(w.workspaceId, p.scopeId))
        .where(and(eq(p.scopeId, scopeId), inArray(p.id, ids), eq(p.status, "ready"), isNull(p.operation),
          eq(p.requestVersion, p.completedVersion), eq(p.generation, generation), eq(state.generation, generation),
          eq(state.indexedGeneration, generation), eq(state.reconcile, false), eq(state.enabled, true), eq(state.purge, false),
          isNull(w.deletingAt), eq(w.encryption, "none"), workspacePermissions(tx, base, userId).read(w.workspaceId))));
    },
    async requestPage(userId: string, scopeId: string, id: string) {
      const p = base.knowledgePage;
      return scoped(userId, scopeId, "admin", async (tx) => {
        const [current] = await tx.select().from(state).where(eq(state.scopeId, scopeId));
        if (!current?.enabled || current.purge) throw new RequestError(409, "memory_disabled");
        const rows = await tx.update(p).set({ requestVersion: sql`CASE WHEN ${p.requestVersion} = ${p.completedVersion} THEN ${p.requestVersion} + 1 ELSE ${p.requestVersion} END`, operation: sql`CASE WHEN ${p.status} = 'error' AND ${p.requestVersion} = ${p.completedVersion} THEN NULL ELSE ${p.operation} END`, status: "generating" })
          .where(and(eq(p.scopeId, scopeId), eq(p.id, id))).returning();
        if (!rows.length) throw new RequestError(404, "knowledge_page_not_found");
        await enqueueMemoryScope(tx, schema, scopeId);
      });
    },
    async savePage(userId: string, job: MemoryState, page: KnowledgePageRecord,
      patch: { snapshot?: PageSnapshot | null; status?: PageStatus; operation?: PageOperation | null; completedVersion?: number }) {
      const p = base.knowledgePage;
      return scoped(userId, job.scopeId, "admin", async (tx) => {
        if (!await lockJob(tx, schema, job.queue!)) return false;
        const [current] = await tx.select().from(state).where(and(eq(state.scopeId, job.scopeId), leaseKey(job),
          eq(state.generation, job.generation), eq(state.enabled, true), eq(state.purge, false), exists(tx.select({ id: q.id }).from(q).where(claimKey(schema, job.queue!)))));
        if (!current) return false;
        return (await tx.update(p).set({ ...patch, generation: job.generation })
          .where(and(eq(p.scopeId, job.scopeId), eq(p.id, page.id), eq(p.requestVersion, page.requestVersion))).returning()).length > 0;
      });
    },
    async status(userId: string, scopeId: string) {
      return scoped(userId, scopeId, "read", async (tx) => {
        const [row] = await tx.select().from(state).where(eq(state.scopeId, scopeId));
        if (!row) return null;
        const [dispatch] = await tx.select().from(q).where(eq(q.dedupeKey, `${dispatchKind}:${scopeId}`));
        return dispatch ? { ...decorate(row, dispatch), attempts: dispatch.attempts } : { ...row, attempts: 0, errorCode: null, availableAt: new Date(), lease: null, leaseUntil: null };
      });
    },
    async configure(userId: string, scopeId: string, bankId: string, enabled: boolean, imagesEnabled?: boolean) {
      return scoped(userId, scopeId, "admin", async (tx) => {
        const [current] = await tx.select().from(state).where(eq(state.scopeId, scopeId));
        if (current && (current.bankId !== bankId || current.purge)) throw new RequestError(409, "memory_cleanup_required");
        await tx.insert(state).values({ scopeId, requestedBy: userId, bankId, enabled, ...(!personal ? { imagesEnabled: imagesEnabled ?? false } : {}) })
          .onConflictDoUpdate({ target: state.scopeId, set: { enabled, ...(!personal && imagesEnabled !== undefined ? { imagesEnabled } : {}), reconcile: true, requestedBy: userId,
            generation: sql`${state.generation} + 1`, status: enabled ? "pending" : "paused" } });
        await enqueueMemoryScope(tx, schema, scopeId);
      });
    },
    async purge(userId: string, scopeId: string) {
      await scoped(userId, scopeId, "admin", async (tx) => {
        await tx.delete(notes).where(eq(notes.scopeId, scopeId));
        if (!personal) await tx.delete(base.knowledgePage).where(eq(base.knowledgePage.scopeId, scopeId));
        await tx.update(state).set({ enabled: false, purge: true, status: "deleting",
          generation: sql`${state.generation} + 1` }).where(eq(state.scopeId, scopeId));
        await enqueueMemoryScope(tx, schema, scopeId);
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
      const [row] = await db.select().from(q).where(eq(q.dedupeKey, `${dispatchKind}:${scopeId}`));
      return row && ["pending", "processing"].includes(row.status) ? Math.max(5, Math.ceil((row.availableAt.getTime() - Date.now()) / 1000)) : undefined;
    },
    async due(after?: string) {
      return (await db.select().from(q).where(and(eq(q.kind, dispatchKind), lte(q.availableAt, new Date()),
        after ? gt(q.dedupeKey, `${dispatchKind}:${after}`) : undefined, inArray(q.status, ["pending", "processing"])))
        .orderBy(asc(q.dedupeKey)).limit(100)).map((row) => row.payload.scopeId!);
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
    async claim(scopeId: string, supplied?: BackgroundJob) {
      const dispatch = supplied ?? await queue.claim([dispatchKind], [`${dispatchKind}:${scopeId}`]);
      if (!dispatch || dispatch.kind !== dispatchKind || dispatch.payload.scopeId !== scopeId) return undefined;
      return db.transaction(async (tx) => {
        if (!await lockJob(tx, schema, dispatch)) return undefined;
        const [row] = await tx.select().from(state).where(eq(state.scopeId, scopeId));
        if (!row) await settleJob(tx, schema, dispatch);
        return row ? decorate(row, dispatch) : undefined;
      });
    },
    async release(job: MemoryState, patch: Partial<MemoryState> = {}) {
      const { availableAt, attempts, errorCode } = patch;
      const domain = { ...patch };
      for (const key of ["availableAt", "attempts", "errorCode", "lease", "leaseUntil", "queue"] as const) delete domain[key];
      await db.transaction(async (tx) => {
        const [lease] = await tx.select().from(q).where(and(eq(q.id, job.queue!.id), eq(q.lease, job.lease!), gt(q.leaseUntil, new Date())));
        if (!lease) return;
        if (Object.keys(domain).length) await tx.update(state).set(domain).where(and(eq(state.scopeId, job.scopeId), eq(state.generation, job.generation)));
        if (patch.progress !== undefined) await tx.update(state).set({ progress: patch.progress }).where(eq(state.scopeId, job.scopeId));
        await settleJob(tx, schema, job.queue!, { status: "pending", availableAt: availableAt ?? new Date(Date.now() + 5_000),
          attempts: attempts ?? 0, lastError: errorCode ?? null });
      });
    },
    async setProgress(job: MemoryState, progress: MemoryState["progress"]) {
      const rows = await db.update(state).set({ progress }).where(and(eq(state.scopeId, job.scopeId),
        leaseKey(job))).returning();
      if (!rows.length) throw new RequestError(409, "memory_lease_changed");
    },
    async changeIngestionPolicy(job: MemoryState, progress: MemoryProgress) {
      // Advance the publication fence without dropping durable in-flight source operations.
      const [updated] = await db.update(state).set({ progress, generation: sql`${state.generation} + 1`,
        reconcile: true, status: "indexing" }).where(and(eq(state.scopeId, job.scopeId), leaseKey(job))).returning();
      if (!updated) throw new RequestError(409, "memory_lease_changed");
      return decorate(updated, job.queue!);
    },
    async startScan(job: MemoryState, progress: NonNullable<MemoryState["progress"]>) {
      await db.update(state).set({ reconcile: false, progress }).where(and(eq(state.scopeId, job.scopeId),
        leaseKey(job), eq(state.generation, job.generation)));
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
    async saveDocument(job: MemoryState, id: string, source: MemorySource, contentHash: string, ingestionFingerprint: string) {
      await db.transaction(async (tx) => {
        if (!await lockJob(tx, schema, job.queue!)) return;
        const [current] = await tx.select().from(state).where(and(eq(state.scopeId, job.scopeId), eq(state.generation, job.generation)));
        if (!current) return;
        await tx.insert(docs).values({ scopeId: job.scopeId, documentId: id, source, contentHash, ingestionFingerprint, generation: job.generation })
        .onConflictDoUpdate({ target: [docs.scopeId, docs.documentId], set: { source, contentHash, ingestionFingerprint, generation: job.generation } });
      });
    },
    async forgetDocument(scopeId: string, id: string) {
      await db.delete(docs).where(and(eq(docs.scopeId, scopeId), eq(docs.documentId, id)));
    },
    async purged(job: MemoryState) {
      await db.transaction(async (tx) => {
        if (!await lockJob(tx, schema, job.queue!)) return;
        const [current] = await tx.select().from(state).where(and(eq(state.scopeId, job.scopeId), eq(state.generation, job.generation)));
        if (!current) return;
        await tx.delete(docs).where(eq(docs.scopeId, job.scopeId));
        await tx.delete(jobs).where(eq(jobs.scopeId, job.scopeId));
        await tx.delete(state).where(eq(state.scopeId, job.scopeId));
        if (!await settleJob(tx, schema, job.queue!)) throw new RequestError(409, "job_lease_changed");
      });
    },
  };
}
