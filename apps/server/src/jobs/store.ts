import { and, asc, eq, gt, inArray, lte, notInArray, or, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as pg from "../db/auth-schema";
import * as sqlite from "../db/sqlite-schema";
import { uuidV7 } from "../id";
import { groupsForJob, JOB_LEASE_MS, jobKinds, type JobKind, type JobLimits, type JobReference } from "./model";

export type BackgroundJob = typeof pg.backgroundJob.$inferSelect;
export type JobStore = ReturnType<typeof createJobStore>;
export function createJobStore(database: PostgresDatabase | SQLiteDatabase, isPostgres: boolean, limits: JobLimits) {
  const db = database as NodePgDatabase;
  const schema = (isPostgres ? pg : sqlite) as typeof pg;
  const jobs = schema.backgroundJob, dispatch = schema.jobDispatch;
  const key = (job: BackgroundJob) => and(eq(jobs.id, job.id), eq(jobs.lease, job.lease!), eq(jobs.status, "processing"));
  return {
    async enqueue(id: string, kind: JobKind, owner: string, target: string, reference: JobReference, availableAt = new Date()) {
      const values = { id, kind, owner, target, reference, availableAt, createdAt: new Date() };
      await db.insert(jobs).values(values).onConflictDoUpdate({ target: jobs.id,
        set: { ...values, status: "pending", attempts: 0, lastError: null, lease: null, leaseUntil: null,
          generation: sql`${jobs.generation} + 1` }, setWhere: eq(jobs.status, "failed") });
    },
    claim(kinds: readonly JobKind[]) {
      if (!kinds.length) return Promise.resolve(null);
      return db.transaction(async (tx) => {
        // ponytail: one short dispatch lock makes cross-process caps atomic; shard only if claim throughput becomes a bottleneck.
        await tx.insert(dispatch).values({ id: 1, cooldowns: {} }).onConflictDoNothing();
        const query = tx.select().from(dispatch).where(eq(dispatch.id, 1));
        const [state] = isPostgres ? await query.for("update") : await query;
        const now = new Date();
        const active = await tx.select({ kind: jobs.kind, target: jobs.target, lease: jobs.lease }).from(jobs)
          .where(and(eq(jobs.status, "processing"), gt(jobs.leaseUntil, now)));
        const allowed = kinds.filter((kind) => groupsForJob[kind].every((group) =>
          (state!.cooldowns[group] ?? 0) <= now.getTime()
          && new Set(active.filter((job) => groupsForJob[job.kind].includes(group)).map((job) => job.lease)).size < limits[group]));
        if (!allowed.length) return null;
        const eligible = and(lte(jobs.availableAt, now),
          or(eq(jobs.status, "pending"), and(eq(jobs.status, "processing"), lte(jobs.leaseUntil, now))),
          active.length ? notInArray(jobs.target, active.map((item) => item.target)) : undefined);
        const [job] = await tx.select().from(jobs).where(and(inArray(jobs.kind, allowed), eligible))
          .orderBy(sql`CASE WHEN ${jobs.owner} > ${state!.lastOwner} THEN 0 ELSE 1 END`, asc(jobs.owner), asc(jobs.availableAt), asc(jobs.createdAt), asc(jobs.id)).limit(1);
        if (!job) return null;
        const batch = job.kind === "search" ? await tx.select().from(jobs).where(and(eq(jobs.kind, "search"), eq(jobs.owner, job.owner), eligible))
          .orderBy(asc(jobs.availableAt), asc(jobs.createdAt), asc(jobs.id)).limit(16) : [job];
        const lease = uuidV7(), leaseUntil = new Date(now.getTime() + JOB_LEASE_MS);
        const claimed = batch.map((item) => ({ ...item, status: "processing", lease, leaseUntil, attempts: item.attempts + 1 }));
        await tx.update(jobs).set({ status: "processing", lease, leaseUntil, attempts: sql`${jobs.attempts} + 1` })
          .where(inArray(jobs.id, batch.map((item) => item.id)));
        await tx.update(dispatch).set({ lastOwner: job.owner }).where(eq(dispatch.id, 1));
        return { ...claimed[0]!, batch: claimed };
      });
    },
    async complete(job: BackgroundJob) {
      await db.transaction(async (tx) => {
        await tx.delete(jobs).where(and(key(job), eq(jobs.generation, job.generation)));
        await tx.update(jobs).set({ status: "pending", lease: null, leaseUntil: null, attempts: 0, lastError: null })
          .where(and(key(job), gt(jobs.generation, job.generation)));
      });
    },
    async retry(job: BackgroundJob, deferred?: { delayMs: number; errorCode: string }) {
      const terminal = job.attempts >= 3;
      await db.update(jobs).set({ status: terminal ? "failed" : "pending", lease: null, leaseUntil: null,
        availableAt: new Date(deferred ? Date.now() + deferred.delayMs
          : Math.max(Date.now() + Math.min(300_000, 1000 * 2 ** job.attempts), (job.leaseUntil?.getTime() ?? 0) + 1000)),
        lastError: deferred?.errorCode ?? "job_execution_failed" }).where(and(key(job), eq(jobs.generation, job.generation)));
      await this.complete(job);
    },
    async reschedule(job: BackgroundJob, reference: JobReference, delayMs: number) {
      await db.update(jobs).set({ reference, status: "pending", lease: null, leaseUntil: null,
        attempts: 0, availableAt: new Date(Date.now() + delayMs) }).where(and(key(job), eq(jobs.generation, job.generation)));
      await this.complete(job);
    },
    async cooldown(kind: JobKind, until: number) {
      await db.transaction(async (tx) => {
        await tx.insert(dispatch).values({ id: 1, cooldowns: {} }).onConflictDoNothing();
        const query = tx.select().from(dispatch).where(eq(dispatch.id, 1));
        const [state] = isPostgres ? await query.for("update") : await query;
        const cooldowns = { ...state!.cooldowns };
        for (const group of groupsForJob[kind]) cooldowns[group] = Math.max(cooldowns[group] ?? 0, until);
        await tx.update(dispatch).set({ cooldowns }).where(eq(dispatch.id, 1));
      });
    },
    async scheduleMaintenance() {
      await this.enqueue("maintenance", "maintenance", "", "maintenance", {});
      for (const kind of ["image", "search"] as const) {
        await this.enqueue(`reconcile:${kind}`, "reconcile", "", `reconcile:${kind}`, { kind, phase: "scopes" });
      }
    },
    async listScopes(kind: "image" | "search", after?: string) {
      if (kind === "image") return (await db.select({ id: schema.user.id }).from(schema.user)
        .where(after ? gt(schema.user.id, after) : undefined).orderBy(asc(schema.user.id)).limit(100)).map((row) => row.id);
      const scopes = schema.syncedWorkspacePermission;
      return (await db.selectDistinct({ id: scopes.workspaceId }).from(scopes).where(after ? gt(scopes.workspaceId, after) : undefined)
        .orderBy(asc(scopes.workspaceId)).limit(100)).map((row) => row.id);
    },
    async nextDelay(kinds: readonly JobKind[]) {
      const [row] = await db.select({ at: sql<Date | number | string>`min(CASE WHEN ${jobs.status} = 'processing' THEN ${jobs.leaseUntil} ELSE ${jobs.availableAt} END)` })
        .from(jobs).where(and(inArray(jobs.kind, kinds), inArray(jobs.status, ["pending", "processing"])));
      return row?.at == null ? undefined : Math.max(1, Math.min(60, Math.ceil((new Date(row.at).getTime() - Date.now()) / 1000)));
    },
    async sourceAvailableAt(job: BackgroundJob) {
      return db.transaction(async (tx) => {
        if (isPostgres && job.reference.ownerUserId) await tx.execute(sql`select set_config('app.user_id', ${job.reference.ownerUserId}, true)`);
        const source = job.kind === "search" ? schema.searchIndexJob : job.kind === "image" ? schema.imageAnalysisJob : schema.summaryJob;
        const filter = job.kind === "search" ? and(eq(schema.searchIndexJob.workspaceId, job.reference.workspaceId!), eq(schema.searchIndexJob.documentId, job.reference.documentId!))
          : job.kind === "image" ? eq(schema.imageAnalysisJob.fileId, job.reference.fileId!) : eq(schema.summaryJob.id, job.reference.id!);
        const [row] = await tx.select({ availableAt: source.availableAt, leaseUntil: source.leaseExpiresAt, status: source.status }).from(source).where(filter);
        if (!row || !["pending", "processing"].includes(row.status)) return undefined;
        return new Date(Math.max(row.availableAt.getTime(), row.status === "processing" ? row.leaseUntil?.getTime() ?? 0 : 0));
      });
    },
  };
}

export { jobKinds };
