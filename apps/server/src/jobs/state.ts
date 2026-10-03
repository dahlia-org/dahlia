import { and, eq, gt, sql } from "drizzle-orm";
import type { SQL } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type * as Schema from "../db/auth-schema";
import { uuidV7 } from "@dahlia-ai/ui/model/id";
import { jobPayloadSchema, type JobKind, type JobPayload } from "./model";
import type { BackgroundJob } from "./store";

export type JobSchema = Pick<typeof Schema, "backgroundJob">;
export function payloadField(schema: JobSchema, name: keyof JobPayload, uuid = false): SQL<string> {
  const field = sql<string>`${schema.backgroundJob.payload} ->> ${name}`;
  return uuid && schema.backgroundJob.id.getSQLType() === "uuid" ? sql<string>`(${field})::uuid` : field;
}
export function claimKey(schema: JobSchema, job: BackgroundJob) {
  const q = schema.backgroundJob;
  return and(eq(q.id, job.id), eq(q.lease, job.lease!), eq(q.generation, job.generation),
    eq(q.status, "processing"), gt(q.leaseUntil, new Date()));
}
export async function lockJob(db: NodePgDatabase, schema: JobSchema, job: BackgroundJob) {
  const query = db.select().from(schema.backgroundJob).where(claimKey(schema, job));
  const [row] = schema.backgroundJob.id.getSQLType() === "uuid" ? await query.for("update") : await query;
  return row;
}
// Call with the canonical mutation's transaction, never a separate connection.
export async function enqueueJob(db: NodePgDatabase, schema: JobSchema, dedupeKey: string,
  kind: JobKind, owner: string, target: string, payload: JobPayload, availableAt = new Date(), replace = true, preserveAttempts = false) {
  const q = schema.backgroundJob;
  const parsed = jobPayloadSchema.parse({ kind, payload }).payload;
  const values = { id: uuidV7(), dedupeKey, kind, owner, target, payload: parsed, availableAt, createdAt: new Date() };
  const insert = db.insert(q).values(values);
  let attempts: number | SQL = 0;
  if (preserveAttempts) {
    attempts = sql`CASE WHEN ${q.status} = 'processing' AND ${q.dispatchAttempts} > 0 AND ${q.attempts} > 0 THEN ${q.attempts} - 1 ELSE ${q.attempts} END`;
  } else if (!replace) {
    attempts = sql`CASE WHEN ${q.lastError} IN ('job_execution_failed', 'job_source_not_ready') THEN ${q.attempts} ELSE 0 END`;
  }
  const rows = await insert.onConflictDoUpdate({ target: q.dedupeKey,
    set: { kind, owner, target, payload: parsed, availableAt, generation: sql`${q.generation} + 1`, attempts,
      dispatchAttempts: 0, lastError: null, retainCancelled: false,
      status: sql`CASE WHEN ${q.leaseUntil} > ${sql.param(new Date(), q.leaseUntil)} THEN 'processing' ELSE 'pending' END` },
    setWhere: replace ? undefined : eq(q.status, "failed"),
  }).returning();
  return rows[0];
}
export async function settleJob(db: NodePgDatabase, schema: JobSchema, job: BackgroundJob,
  patch?: Partial<BackgroundJob>) {
  const q = schema.backgroundJob;
  const current = claimKey(schema, job);
  let settled: { id: string }[];
  if (patch) settled = await db.update(q).set({ dispatchAttempts: 0, ...patch, lease: null, leaseUntil: null }).where(current).returning({ id: q.id });
  else if (job.kind === "summary" || job.kind === "audio-summary") {
    settled = await db.update(q).set({ status: "succeeded", dispatchAttempts: 0, lease: null, leaseUntil: null, lastError: null }).where(current).returning({ id: q.id });
  } else settled = await db.delete(q).where(current).returning({ id: q.id });
  // A superseding update or cancellation keeps the old lease until its executor settles.
  await db.update(q).set({ lease: null, leaseUntil: null,
    status: sql`CASE WHEN ${q.status} = 'processing' THEN 'pending' ELSE ${q.status} END` })
    .where(and(eq(q.id, job.id), eq(q.lease, job.lease!), sql`(${q.generation} > ${job.generation} OR ${q.status} <> 'processing')`));
  await db.delete(q).where(and(eq(q.id, job.id), eq(q.status, "cancelled"), eq(q.retainCancelled, false), sql`${q.lease} IS NULL`));
  return settled.length > 0;
}
export function retryJob(db: NodePgDatabase, schema: JobSchema, job: BackgroundJob,
  deferred?: { delayMs: number; errorCode: string }) {
  return settleJob(db, schema, job, { status: job.dispatchAttempts >= 3 ? "failed" : "pending",
    dispatchAttempts: job.dispatchAttempts, attempts: Math.max(0, job.attempts - 1),
    availableAt: new Date(deferred ? Date.now() + Math.max(60_000, deferred.delayMs)
      : Math.max(Date.now() + Math.min(300_000, 1000 * 2 ** job.dispatchAttempts), (job.leaseUntil?.getTime() ?? 0) + 1000)),
    lastError: deferred?.errorCode ?? "job_execution_failed" });
}
export function executionState(job: BackgroundJob) {
  return { queueId: job.id, queue: job, status: job.status, attempts: job.attempts, availableAt: job.availableAt,
    claimedAt: job.claimedAt, leaseExpiresAt: job.leaseUntil, lastErrorCode: job.lastError };
}
export async function cancelJobs(db: NodePgDatabase, schema: JobSchema, filter: SQL | undefined, retain = false) {
  const q = schema.backgroundJob;
  // A physical purge releases retention even after an API cancellation kept the live lease.
  await db.update(q).set({ status: "cancelled", generation: sql`${q.generation} + 1`,
    retainCancelled: retain ? sql`${q.kind} IN ('summary', 'audio-summary')` : false })
    .where(and(filter, sql`${q.status} IN ('pending', 'processing', 'cancelled')`));
  if (!retain) await db.delete(q).where(and(filter, sql`(${q.leaseUntil} IS NULL OR ${q.leaseUntil} <= ${sql.param(new Date(), q.leaseUntil)})`));
}
export async function enqueueStorageDelete(db: NodePgDatabase, schema: JobSchema, storageKey: string) {
  return enqueueJob(db, schema, `storage-delete:${storageKey}`, "storage-delete", "", `storage:${storageKey}`, { storageKey }, new Date(), false);
}
