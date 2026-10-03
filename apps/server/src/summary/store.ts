import { workspacePermissions } from "../auth/workspace-permissions";
import { createContentEncryption } from "../encryption/store";
import type { EncryptionConfig } from "../encryption/crypto";
import { and, asc, eq, exists, gt, inArray, lte, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as postgresSchema from "../db/auth-schema";
import * as sqliteSchema from "../db/sqlite-schema";
import { claimKey, executionState, lockJob, settleJob } from "../jobs/state";
import { createJobStore, type BackgroundJob } from "../jobs/store";
import { defaultJobLimits } from "../jobs/model";
import { isRateLimited, RATE_LIMIT_COOLDOWN_MS } from "../jobs/rate-limit";
import { storedTranscriptSettingsSchema, type SummaryJob, type SummaryStage } from "./model";

export type SummaryJobReference = Pick<SummaryJob, "id" | "ownerUserId">;
export interface SummaryJobStore {
  claim(reference?: SummaryJobReference | BackgroundJob): Promise<SummaryJob | null>;
  advance(job: SummaryJob, stage: SummaryStage): Promise<boolean>;
  fail(job: SummaryJob, code: string, retryable: boolean): Promise<void>;
}
export interface SummaryJobQueueStore extends SummaryJobStore {
  due(ownerUserId: string, after?: string): Promise<SummaryJobReference[]>;
}
export function createSummaryJobStore(database: PostgresDatabase | SQLiteDatabase, isPostgres: boolean, encryption?: EncryptionConfig): SummaryJobQueueStore {
  const db = database as NodePgDatabase;
  const schema = (isPostgres ? postgresSchema : sqliteSchema) as typeof postgresSchema;
  const jobs = schema.summaryJob, q = schema.backgroundJob;
  const queue = createJobStore(database, isPostgres, defaultJobLimits);
  const withOwner = <T>(userId: string, action: (connection: NodePgDatabase) => Promise<T>) => db.transaction(async (connection) => {
    if (isPostgres) await connection.execute(sql`select set_config('app.user_id', ${userId}, true)`);
    return action(connection);
  });
  return {
    due(ownerUserId, after) {
      return withOwner(ownerUserId, (tx) => tx.select({ id: jobs.id, ownerUserId: jobs.ownerUserId }).from(jobs)
        .innerJoin(q, eq(q.id, jobs.queueId)).where(and(eq(jobs.ownerUserId, ownerUserId), after ? gt(jobs.id, after) : undefined,
          inArray(q.status, ["pending", "processing"]), lte(q.availableAt, new Date())))
        .orderBy(asc(jobs.id)).limit(100));
    },
    async claim(reference) {
      // Direct store consumers use the same scheduler; executors always supply their existing claim.
      if (reference && !("dedupeKey" in reference) && !(await db.select({ id: q.id }).from(q)
        .where(and(eq(q.dedupeKey, `summary:${reference.id}`), eq(q.owner, reference.ownerUserId)))).length) return null;
      const dispatch = reference && "dedupeKey" in reference ? reference
        : await queue.claim(["summary", "audio-summary"], reference ? [`summary:${reference.id}`] : undefined);
      if (!dispatch) return null;
      return withOwner(dispatch.payload.ownerUserId!, async (tx) => {
        if (!await lockJob(tx, schema, dispatch)) return null;
        const [stored] = await tx.select().from(jobs).where(eq(jobs.queueId, dispatch.id));
        if (!stored) return null;
        const [writable] = await tx.select({ id: schema.syncedWorkspace.workspaceId }).from(schema.syncedWorkspace)
          .where(and(eq(schema.syncedWorkspace.workspaceId, stored.workspaceId), workspacePermissions(tx, schema, stored.ownerUserId).write(schema.syncedWorkspace.workspaceId))).limit(1);
        if (!writable || dispatch.attempts > 3) {
          await settleJob(tx, schema, dispatch, { status: "failed", lastError: writable ? "summary_retry_exhausted" : "summary_meeting_unavailable" });
          return null;
        }
        const [row] = await createContentEncryption(tx, schema, stored.ownerUserId, encryption).read(jobs, [stored]);
        return row ? { ...row, ...executionState(dispatch), settings: storedTranscriptSettingsSchema.parse(row.settings) } : null;
      });
    },
    advance(job, stage) {
      return withOwner(job.ownerUserId, async (tx) => {
        if (!job.queue || !await lockJob(tx, schema, job.queue)) return false;
        return (await tx.update(jobs).set({ stage }).where(and(eq(jobs.id, job.id), eq(jobs.ownerUserId, job.ownerUserId),
          exists(tx.select({ id: q.id }).from(q).where(claimKey(schema, job.queue))))).returning()).length > 0;
      });
    },
    async fail(job, code, retryable) {
      if (!job.queue) return;
      const throttled = isRateLimited(code);
      const refunded = throttled && Date.now() - job.createdAt.getTime() < 60 * 60_000;
      await withOwner(job.ownerUserId, async (tx) => {
        await settleJob(tx, schema, job.queue!, { status: refunded || (retryable && job.attempts < 3) ? "pending" : "failed",
          attempts: refunded ? job.attempts - 1 : job.attempts, lastError: code,
          availableAt: new Date(Date.now() + (throttled ? RATE_LIMIT_COOLDOWN_MS : 5_000 * 2 ** job.attempts)) });
      });
      if (throttled) await queue.cooldown(job.queue.kind, Date.now() + RATE_LIMIT_COOLDOWN_MS);
    },
  };
}
