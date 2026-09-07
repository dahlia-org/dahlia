import { and, asc, eq, exists, gt, inArray, isNotNull, isNull, lte, ne, or, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";

import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as postgresSchema from "../db/auth-schema";
import * as sqliteSchema from "../db/sqlite-schema";
import { imageContentTypes } from "../files/model";
import { needsImageAnalysis, type ImageAnalysisClaim } from "./model";

export interface ImageAnalysisStore {
  reconcile(model: string): Promise<void>;
  claim(model: string): Promise<ImageAnalysisClaim | null>;
  finish(claim: ImageAnalysisClaim, error?: { code: string; retryAt?: Date }): Promise<void>;
}

export function createImageAnalysisStore(database: PostgresDatabase | SQLiteDatabase, isPostgres: boolean): ImageAnalysisStore {
  const db = database as NodePgDatabase;
  const schema = (isPostgres ? postgresSchema : sqliteSchema) as typeof postgresSchema;
  const jobs = schema.imageAnalysisJob;
  const files = schema.syncedFile;
  const withOwner = <T>(userId: string, action: (transaction: NodePgDatabase) => Promise<T>) =>
    db.transaction(async (transaction) => {
      if (isPostgres) await transaction.execute(sql`select set_config('app.user_id', ${userId}, true)`);
      return action(transaction);
    });
  return {
    async reconcile(model) {
      const owners = await db.selectDistinct({ userId: schema.syncedVaultPermission.principalId })
        .from(schema.syncedVaultPermission).where(and(
          eq(schema.syncedVaultPermission.principalType, "user"), eq(schema.syncedVaultPermission.role, "owner"),
        ));
      for (const { userId } of owners) {
        let after: string | undefined;
        while (true) {
          const rows = await withOwner(userId, async (transaction) => {
            const page = await transaction.select({ fileId: files.fileId, vaultId: files.vaultId, metadata: files.metadata })
              .from(files).leftJoin(jobs, eq(jobs.fileId, files.fileId))
              .where(and(
                eq(files.active, true), isNotNull(files.uploadedAt), inArray(files.contentType, [...imageContentTypes]),
                after ? gt(files.fileId, after) : undefined,
                or(isNull(jobs.fileId), ne(jobs.model, model)),
                exists(transaction.select({ id: schema.syncedVaultPermission.vaultId }).from(schema.syncedVaultPermission).where(and(
                  eq(schema.syncedVaultPermission.vaultId, files.vaultId), eq(schema.syncedVaultPermission.principalType, "user"),
                  eq(schema.syncedVaultPermission.principalId, userId), eq(schema.syncedVaultPermission.role, "owner"),
                ))),
                exists(transaction.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault).where(and(
                  eq(schema.syncedVault.vaultId, files.vaultId), isNull(schema.syncedVault.deletingAt),
                ))),
                exists(transaction.select({ id: schema.meetingFile.id }).from(schema.meetingFile)
                  .innerJoin(schema.syncedMeeting, and(
                    eq(schema.syncedMeeting.vaultId, schema.meetingFile.vaultId),
                    eq(schema.syncedMeeting.meetingId, schema.meetingFile.meetingId),
                  )).where(and(eq(schema.meetingFile.fileId, files.fileId), isNull(schema.syncedMeeting.deletingAt)))),
              )).orderBy(asc(files.fileId)).limit(200);
            const missing = page.filter((row) => needsImageAnalysis(row.metadata));
            if (missing.length) {
              await transaction.insert(jobs).values(missing.map(({ fileId, vaultId }) => ({
                fileId, vaultId, ownerUserId: userId, model,
              }))).onConflictDoUpdate({
                target: jobs.fileId,
                set: { model, status: "pending", attempts: 0, availableAt: new Date(), claimedAt: null, leaseExpiresAt: null, lastErrorCode: null },
                setWhere: ne(jobs.model, model),
              });
            }
            return page;
          });
          if (rows.length < 200) break;
          after = rows.at(-1)!.fileId;
        }
      }
    },
    claim(model) {
      return db.transaction(async (transaction) => {
        const now = new Date();
        const query = transaction.select().from(jobs).where(and(
          eq(jobs.model, model), lte(jobs.availableAt, now),
          or(eq(jobs.status, "pending"), and(eq(jobs.status, "processing"), lte(jobs.leaseExpiresAt, now))),
        )).orderBy(asc(jobs.availableAt), asc(jobs.fileId)).limit(1);
        const [row] = isPostgres ? await query.for("update", { skipLocked: true }) : await query;
        if (!row) return null;
        await transaction.update(jobs).set({
          status: "processing", claimedAt: now, leaseExpiresAt: new Date(now.getTime() + 300_000),
        }).where(eq(jobs.fileId, row.fileId));
        return { ...row, claimedAt: now };
      });
    },
    async finish(claim, error) {
      const filter = and(eq(jobs.fileId, claim.fileId), eq(jobs.ownerUserId, claim.ownerUserId),
        eq(jobs.model, claim.model), eq(jobs.claimedAt, claim.claimedAt));
      if (!error) await db.delete(jobs).where(filter);
      else await db.update(jobs).set({
        status: error.retryAt ? "pending" : "failed", attempts: claim.attempts + 1,
        availableAt: error.retryAt ?? new Date(), claimedAt: null, leaseExpiresAt: null, lastErrorCode: error.code,
      }).where(filter);
    },
  };
}
