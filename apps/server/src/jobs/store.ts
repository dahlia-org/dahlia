import { and, asc, eq, gt, inArray, lte, notInArray, or, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as pg from "../db/auth-schema";
import * as sqlite from "../db/sqlite-schema";
import { enqueueJob, retryJob, settleJob } from "./state";
import { uuidV7 } from "@dahlia-ai/ui/model/id";
import { groupsForJob, JOB_LEASE_MS, jobKinds, jobPayloadSchema, type JobKind, type JobLimits, type JobPayload } from "./model";

export type BackgroundJob = typeof pg.backgroundJob.$inferSelect;
export type JobStore = ReturnType<typeof createJobStore>;
export function createJobStore(database: PostgresDatabase | SQLiteDatabase | NodePgDatabase, isPostgres: boolean, limits: JobLimits) {
  const db = database as NodePgDatabase;
  const schema = (isPostgres ? pg : sqlite) as typeof pg;
  const jobs = schema.backgroundJob, dispatch = schema.jobDispatch;
  return {
    enqueue(dedupeKey: string, kind: JobKind, owner: string, target: string, payload: JobPayload, availableAt = new Date(), replace = false) {
      return enqueueJob(db, schema, dedupeKey, kind, owner, target, payload, availableAt, replace);
    },
    claim(kinds: readonly JobKind[], dedupeKeys?: readonly string[]) {
      if (!kinds.length) return Promise.resolve(null);
      return db.transaction(async (tx) => {
        // ponytail: one short dispatch lock makes cross-process caps atomic; shard only if claim throughput becomes a bottleneck.
        await tx.insert(dispatch).values({ id: 1, cooldowns: {} }).onConflictDoNothing();
        const query = tx.select().from(dispatch).where(eq(dispatch.id, 1));
        const [state] = isPostgres ? await query.for("update") : await query;
        const now = new Date();
        await tx.delete(jobs).where(and(eq(jobs.status, "cancelled"), eq(jobs.retainCancelled, false),
          or(sql`${jobs.leaseUntil} IS NULL`, lte(jobs.leaseUntil, now))));
        const active = await tx.select({ kind: jobs.kind, target: jobs.target, lease: jobs.lease }).from(jobs)
          .where(gt(jobs.leaseUntil, now));
        const allowed = kinds.filter((kind) => groupsForJob[kind].every((group) =>
          (state!.cooldowns[group] ?? 0) <= now.getTime()
          && new Set(active.filter((job) => groupsForJob[job.kind].includes(group)).map((job) => job.lease)).size < limits[group]));
        if (!allowed.length) return null;
        const eligible = and(dedupeKeys ? inArray(jobs.dedupeKey, [...dedupeKeys]) : undefined, lte(jobs.availableAt, now),
          or(eq(jobs.status, "pending"), and(eq(jobs.status, "processing"), lte(jobs.leaseUntil, now))),
          or(sql`${jobs.leaseUntil} IS NULL`, lte(jobs.leaseUntil, now)),
          active.length ? notInArray(jobs.target, active.map((item) => item.target)) : undefined);
        // Canonical writers can enqueue or cancel without the dispatch lock; protect each selected row until its lease is written.
        const candidate = tx.select().from(jobs).where(and(inArray(jobs.kind, allowed), eligible))
          .orderBy(sql`CASE WHEN ${jobs.owner} > ${state!.lastOwner} THEN 0 ELSE 1 END`, asc(jobs.owner), asc(jobs.availableAt), asc(jobs.createdAt), asc(jobs.dedupeKey)).limit(1);
        const [job] = isPostgres ? await candidate.for("update", { skipLocked: true }) : await candidate;
        if (!job) return null;
        let batch = [job];
        if (job.kind === "search") {
          const candidates = tx.select().from(jobs).where(and(eq(jobs.kind, "search"), eq(jobs.owner, job.owner), eligible))
            .orderBy(asc(jobs.availableAt), asc(jobs.createdAt), asc(jobs.dedupeKey)).limit(16);
          batch = isPostgres ? await candidates.for("update", { skipLocked: true }) : await candidates;
        }
        const valid = batch.filter((item) => jobPayloadSchema.safeParse(item).success);
        for (const item of batch.filter((item) => !valid.includes(item))) {
          await tx.update(jobs).set({ status: "failed", lastError: "job_payload_invalid", lease: null, leaseUntil: null }).where(eq(jobs.id, item.id));
        }
        if (!valid.length) return null;
        const lease = uuidV7(), leaseUntil = new Date(now.getTime() + JOB_LEASE_MS);
        const claimed = valid.map((item) => ({ ...item, status: "processing", claimedAt: now, lease, leaseUntil, attempts: item.attempts + 1, dispatchAttempts: item.dispatchAttempts + 1 }));
        await tx.update(jobs).set({ status: "processing", claimedAt: now, lease, leaseUntil, attempts: sql`${jobs.attempts} + 1`, dispatchAttempts: sql`${jobs.dispatchAttempts} + 1` })
          .where(inArray(jobs.id, valid.map((item) => item.id)));
        await tx.update(dispatch).set({ lastOwner: job.owner }).where(eq(dispatch.id, 1));
        return { ...claimed[0]!, batch: claimed };
      });
    },
    async complete(job: BackgroundJob) {
      await db.transaction((tx) => settleJob(tx, schema, job));
    },
    async retry(job: BackgroundJob, deferred?: { delayMs: number; errorCode: string }) {
      await db.transaction((tx) => retryJob(tx, schema, job, deferred));
    },
    async reschedule(job: BackgroundJob, payload: JobPayload, delayMs: number) {
      payload = jobPayloadSchema.parse({ kind: job.kind, payload }).payload;
      await db.transaction((tx) => settleJob(tx, schema, job, { payload, status: "pending", attempts: 0,
        availableAt: new Date(Date.now() + delayMs) }));
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

  };
}

export { jobKinds };
