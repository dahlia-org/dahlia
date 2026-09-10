import { createContentEncryption } from "../encryption/store";
import type { EncryptionConfig } from "../encryption/crypto";
import { and, asc, eq, exists, gt, inArray, isNotNull, isNull, lte, ne, or, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";

import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as postgresSchema from "../db/auth-schema";
import * as sqliteSchema from "../db/sqlite-schema";
import { imageContentTypes } from "../files/model";
import { needsImageAnalysis, type ImageAnalysisClaim } from "./model";

export type ImageAnalysisReference = Pick<ImageAnalysisClaim, "fileId" | "ownerUserId" | "model">;

export interface ImageAnalysisStore {
  reconcile(model: string): Promise<void>;
  claim(model: string, reference?: ImageAnalysisReference): Promise<ImageAnalysisClaim | null>;
  finish(claim: ImageAnalysisClaim, error?: { code: string; retryAt?: Date }): Promise<void>;
}

export interface ImageAnalysisQueueStore extends ImageAnalysisStore {
  reconcilePage(model: string, ownerUserId: string, after?: string): Promise<string | undefined>;
  due(model: string, ownerUserId: string, after?: string): Promise<ImageAnalysisReference[]>;
}

export function createImageAnalysisStore(database: PostgresDatabase | SQLiteDatabase, isPostgres: boolean, encryption?: EncryptionConfig): ImageAnalysisQueueStore {
  const db = database as NodePgDatabase;
  const schema = (isPostgres ? postgresSchema : sqliteSchema) as typeof postgresSchema;
  const jobs = schema.imageAnalysisJob;
  const files = schema.syncedFile;
  const withOwner = <T>(userId: string, action: (transaction: NodePgDatabase) => Promise<T>) =>
    db.transaction(async (transaction) => {
      if (isPostgres) await transaction.execute(sql`select set_config('app.user_id', ${userId}, true)`);
      return action(transaction);
    });
  async function reconcilePage(model: string, userId: string, after?: string, batchSize = 100): Promise<string | undefined> {
    const rows = await withOwner(userId, async (transaction) => {
      const content = createContentEncryption(transaction, schema, userId, encryption);
      const page = await content.read(files, await transaction.select({ encryptedPayload: files.encryptedPayload, fileId: files.fileId, vaultId: files.vaultId, metadata: files.metadata })
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
          exists(transaction.select({ id: schema.meetingAttachment.id }).from(schema.meetingAttachment)
            .innerJoin(schema.syncedMeeting, and(
              eq(schema.syncedMeeting.vaultId, schema.meetingAttachment.vaultId),
              eq(schema.syncedMeeting.meetingId, schema.meetingAttachment.meetingId),
            )).where(and(eq(schema.meetingAttachment.fileId, files.fileId), isNull(schema.syncedMeeting.deletingAt)))),
        )).orderBy(asc(files.fileId)).limit(batchSize));
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
    return rows.length === batchSize ? rows.at(-1)!.fileId : undefined;
  }
  return {
    reconcilePage,
    due(model, ownerUserId, after) {
      return db.select({ fileId: jobs.fileId, ownerUserId: jobs.ownerUserId, model: jobs.model }).from(jobs)
        .where(and(eq(jobs.model, model), eq(jobs.ownerUserId, ownerUserId), after ? gt(jobs.fileId, after) : undefined,
          lte(jobs.availableAt, new Date()), or(eq(jobs.status, "pending"),
            and(eq(jobs.status, "processing"), lte(jobs.leaseExpiresAt, new Date())))))
        .orderBy(asc(jobs.fileId)).limit(100);
    },
    async reconcile(model) {
      const owners = await db.selectDistinct({ userId: schema.syncedVaultPermission.principalId })
        .from(schema.syncedVaultPermission).where(and(
          eq(schema.syncedVaultPermission.principalType, "user"), eq(schema.syncedVaultPermission.role, "owner"),
        ));
      for (const { userId } of owners) {
        let after: string | undefined;
        while (true) {
          const next = await reconcilePage(model, userId, after, 200);
          if (!next) break;
          after = next;
        }
      }
    },
    claim(model, reference) {
      return db.transaction(async (transaction) => {
        const now = new Date();
        const query = transaction.select().from(jobs).where(and(
          reference ? and(eq(jobs.fileId, reference.fileId), eq(jobs.ownerUserId, reference.ownerUserId), eq(jobs.model, reference.model)) : undefined,
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
