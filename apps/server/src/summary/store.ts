import { workspacePermissions } from "../auth/workspace-permissions";
import { createContentEncryption } from "../encryption/store";
import type { EncryptionConfig } from "../encryption/crypto";
import { and, asc, eq, lte, gt, or, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as postgresSchema from "../db/auth-schema";
import * as sqliteSchema from "../db/sqlite-schema";
import { isRateLimited, RATE_LIMIT_COOLDOWN_MS } from "../jobs/rate-limit";
import { storedTranscriptSettingsSchema, type SummaryJob, type SummaryStage } from "./model";

export type SummaryJobReference = Pick<SummaryJob, "id" | "ownerUserId">;

export interface SummaryJobStore {
  claim(reference?: SummaryJobReference): Promise<SummaryJob | null>;
  advance(job: SummaryJob, stage: SummaryStage): Promise<boolean>;
  fail(job: SummaryJob, code: string, retryable: boolean): Promise<void>;
}
export interface SummaryJobQueueStore extends SummaryJobStore {
  due(ownerUserId: string, after?: string): Promise<SummaryJobReference[]>;
}

export function createSummaryJobStore(database: PostgresDatabase | SQLiteDatabase, isPostgres: boolean, encryption?: EncryptionConfig): SummaryJobQueueStore {
  const db = database as NodePgDatabase;
  const schema = (isPostgres ? postgresSchema : sqliteSchema) as typeof postgresSchema;
  const jobs = schema.summaryJob;
  const withOwner = <T>(userId: string, action: (connection: NodePgDatabase) => Promise<T>) => db.transaction(async (connection) => {
    if (isPostgres) await connection.execute(sql`select set_config('app.user_id', ${userId}, true)`);
    return action(connection);
  });
  // Per process: rotation keeps one owner's backlog from starving others; SKIP LOCKED still prevents double claims.
  let lastOwner = "";
  let cooldownUntil = 0;
  return {
    due(ownerUserId, after) {
      return withOwner(ownerUserId, (connection) => connection.select({ id: jobs.id, ownerUserId: jobs.ownerUserId }).from(jobs)
        .where(and(eq(jobs.ownerUserId, ownerUserId), after ? gt(jobs.id, after) : undefined,
          lte(jobs.availableAt, new Date()), or(eq(jobs.status, "pending"),
            and(eq(jobs.status, "processing"), lte(jobs.leaseExpiresAt, new Date())))))
        .orderBy(asc(jobs.id)).limit(100));
    },
    async claim(reference) {
      if (!reference && Date.now() < cooldownUntil) return null;
      // Idle polling must scale with due jobs, not with every registered user.
      const owners = reference ? [{ id: reference.ownerUserId }] : await db.transaction(async (connection) => {
        if (isPostgres) await connection.execute(sql`select set_config('app.maintenance', 'summary-dispatch', true)`);
        const now = new Date();
        return connection.selectDistinct({ id: jobs.ownerUserId }).from(jobs).where(and(lte(jobs.availableAt, now),
          or(eq(jobs.status, "pending"), and(eq(jobs.status, "processing"), lte(jobs.leaseExpiresAt, now)))))
          .orderBy(asc(jobs.ownerUserId));
      });
      const start = reference ? 0 : owners.findIndex((owner) => owner.id > lastOwner);
      for (const owner of start > 0 ? [...owners.slice(start), ...owners.slice(0, start)] : owners) {
        const job = await withOwner(owner.id, async (connection) => {
          const now = new Date();
          const eligible = and(eq(jobs.ownerUserId, owner.id), reference ? eq(jobs.id, reference.id) : undefined, lte(jobs.availableAt, now),
            or(eq(jobs.status, "pending"), and(eq(jobs.status, "processing"), lte(jobs.leaseExpiresAt, now))));
          const query = connection.select().from(jobs).where(eligible).orderBy(asc(jobs.availableAt)).limit(1);
          const [stored] = isPostgres ? await query.for("update", { skipLocked: true }) : await query;
          if (!stored) return null;
          const [writable] = await connection.select({ id: schema.syncedWorkspace.workspaceId }).from(schema.syncedWorkspace)
            .where(and(eq(schema.syncedWorkspace.workspaceId, stored.workspaceId), workspacePermissions(connection, schema, owner.id).write(schema.syncedWorkspace.workspaceId))).limit(1);
          if (!writable) {
            await connection.update(jobs).set({ status: "failed", lastErrorCode: "summary_meeting_unavailable", claimedAt: null, leaseExpiresAt: null }).where(eq(jobs.id, stored.id));
            return null;
          }
          const [row] = await createContentEncryption(connection, schema, owner.id, encryption).read(jobs, [stored]);
          if (!row) return null;
          if (row.attempts >= 3) {
            await connection.update(jobs).set({ status: "failed", lastErrorCode: "summary_retry_exhausted", claimedAt: null, leaseExpiresAt: null })
              .where(eq(jobs.id, row.id));
            return null;
          }
          const claimed = { ...row, settings: storedTranscriptSettingsSchema.parse(row.settings), status: "processing", attempts: row.attempts + 1, claimedAt: now, leaseExpiresAt: new Date(now.getTime() + 300_000) };
          await connection.update(jobs).set({ status: claimed.status, attempts: claimed.attempts, claimedAt: claimed.claimedAt, leaseExpiresAt: claimed.leaseExpiresAt }).where(eq(jobs.id, row.id));
          return claimed;
        });
        if (!job) continue;
        if (!reference) lastOwner = owner.id;
        return job;
      }
      return null;
    },
    async advance(job, stage) {
      return withOwner(job.ownerUserId, async (connection) => {
        const updated = await connection.update(jobs).set({ stage }).where(and(
          eq(jobs.id, job.id), eq(jobs.ownerUserId, job.ownerUserId), eq(jobs.status, "processing"),
          eq(jobs.claimedAt, job.claimedAt!), gt(jobs.leaseExpiresAt, new Date()),
        )).returning({ id: jobs.id });
        return updated.length > 0;
      });
    },
    async fail(job, code, retryable) {
      // A 429 is refunded for an hour; later ones spend attempts so a persistent limit still fails visibly.
      const throttled = isRateLimited(code);
      const refunded = throttled && Date.now() - job.createdAt.getTime() < 60 * 60_000;
      if (throttled) cooldownUntil = Date.now() + RATE_LIMIT_COOLDOWN_MS;
      await withOwner(job.ownerUserId, async (connection) => {
        await connection.update(jobs).set({ status: refunded || (retryable && job.attempts < 3) ? "pending" : "failed",
          ...(refunded ? { attempts: job.attempts - 1 } : {}),
          lastErrorCode: code, claimedAt: null, leaseExpiresAt: null,
          availableAt: new Date(Math.max(throttled ? cooldownUntil : 0, Date.now() + (refunded ? 0 : 5_000 * 2 ** job.attempts))),
        }).where(and(eq(jobs.id, job.id), eq(jobs.ownerUserId, job.ownerUserId), eq(jobs.status, "processing"), eq(jobs.claimedAt, job.claimedAt!)));
      });
    },
  };
}
