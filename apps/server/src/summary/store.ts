import { and, asc, eq, lte, gt, or, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as postgresSchema from "../db/auth-schema";
import * as sqliteSchema from "../db/sqlite-schema";
import { transcriptSettingsSchema, type SummaryJob, type SummaryStage } from "./model";

export interface SummaryJobStore {
  claim(): Promise<SummaryJob | null>;
  advance(job: SummaryJob, stage: SummaryStage): Promise<boolean>;
  fail(job: SummaryJob, code: string, retryable: boolean): Promise<void>;
}
export function createSummaryJobStore(database: PostgresDatabase | SQLiteDatabase, isPostgres: boolean): SummaryJobStore {
  const db = database as NodePgDatabase;
  const schema = (isPostgres ? postgresSchema : sqliteSchema) as typeof postgresSchema;
  const jobs = schema.summaryJob;
  const withOwner = <T>(userId: string, action: (connection: NodePgDatabase) => Promise<T>) => db.transaction(async (connection) => {
    if (isPostgres) await connection.execute(sql`select set_config('app.user_id', ${userId}, true)`);
    return action(connection);
  });
  return {
    async claim() {
      const owners = await db.selectDistinct({ id: schema.syncedVaultPermission.principalId }).from(schema.syncedVaultPermission)
        .where(and(eq(schema.syncedVaultPermission.principalType, "user"), eq(schema.syncedVaultPermission.role, "owner")));
      for (const owner of owners) {
        const job = await withOwner(owner.id, async (connection) => {
          const now = new Date();
          const eligible = and(eq(jobs.ownerUserId, owner.id), lte(jobs.availableAt, now),
            or(eq(jobs.status, "pending"), and(eq(jobs.status, "processing"), lte(jobs.leaseExpiresAt, now))));
          const query = connection.select().from(jobs).where(eligible).orderBy(asc(jobs.availableAt)).limit(1);
          const [row] = isPostgres ? await query.for("update", { skipLocked: true }) : await query;
          if (!row) return null;
          if (row.attempts >= 3) {
            await connection.update(jobs).set({ status: "failed", lastErrorCode: "summary_retry_exhausted", claimedAt: null, leaseExpiresAt: null })
              .where(eq(jobs.id, row.id));
            return null;
          }
          const claimed = { ...row, settings: transcriptSettingsSchema.parse(row.settings), status: "processing", attempts: row.attempts + 1, claimedAt: now, leaseExpiresAt: new Date(now.getTime() + 300_000) };
          await connection.update(jobs).set(claimed).where(eq(jobs.id, row.id));
          return claimed;
        });
        if (job) return job;
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
      await withOwner(job.ownerUserId, async (connection) => {
        await connection.update(jobs).set({ status: retryable && job.attempts < 3 ? "pending" : "failed",
          lastErrorCode: code, claimedAt: null, leaseExpiresAt: null,
          availableAt: new Date(Date.now() + 5_000 * 2 ** job.attempts),
        }).where(and(eq(jobs.id, job.id), eq(jobs.ownerUserId, job.ownerUserId), eq(jobs.status, "processing"), eq(jobs.claimedAt, job.claimedAt!)));
      });
    },
  };
}
