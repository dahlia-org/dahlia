import { workspacePermissions } from "../auth/workspace-permissions";
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
  /** Claims first-attempt jobs of the same owner and meeting, in capture order, to analyze with `claim`. */
  claimBatch(claim: ImageAnalysisClaim, limit: number): Promise<{ meetingId: string | null; claims: ImageAnalysisClaim[] }>;
  /** Returns a claimed job to the queue without counting an attempt. */
  release(claim: ImageAnalysisClaim): Promise<void>;
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
  const assessments = schema.screenshotAssessment;
  const withOwner = <T>(userId: string, action: (transaction: NodePgDatabase) => Promise<T>) =>
    db.transaction(async (transaction) => {
      if (isPostgres) await transaction.execute(sql`select set_config('app.user_id', ${userId}, true)`);
      return action(transaction);
    });
  async function reconcilePage(model: string, userId: string, after?: string, batchSize = 100): Promise<string | undefined> {
    const rows = await withOwner(userId, async (transaction) => {
      const content = createContentEncryption(transaction, schema, userId, encryption);
      const page = await content.read(files, await transaction.select({ encryptedPayload: files.encryptedPayload, fileId: files.fileId, workspaceId: files.workspaceId, metadata: files.metadata, mode: jobs.mode, assessed: assessments.fileId })
        .from(files).leftJoin(jobs, eq(jobs.fileId, files.fileId)).leftJoin(assessments, eq(assessments.fileId, files.fileId))
        .where(and(
          eq(files.active, true), isNotNull(files.uploadedAt), inArray(files.contentType, [...imageContentTypes]),
          after ? gt(files.fileId, after) : undefined,
          or(isNull(jobs.fileId), ne(jobs.model, model)),
          workspacePermissions(transaction, schema, userId).write(files.workspaceId),
          exists(transaction.select({ id: schema.syncedWorkspace.workspaceId }).from(schema.syncedWorkspace).where(and(
            eq(schema.syncedWorkspace.workspaceId, files.workspaceId), isNull(schema.syncedWorkspace.deletingAt),
          ))),
          exists(transaction.select({ id: schema.meetingAttachment.id }).from(schema.meetingAttachment)
            .innerJoin(schema.syncedMeeting, and(
              eq(schema.syncedMeeting.workspaceId, schema.meetingAttachment.workspaceId),
              eq(schema.syncedMeeting.meetingId, schema.meetingAttachment.meetingId),
            )).where(and(eq(schema.meetingAttachment.fileId, files.fileId), isNull(schema.syncedMeeting.deletingAt), isNull(schema.syncedMeeting.deletedAt)))),
        )).orderBy(asc(files.fileId)).limit(batchSize));
      const missing = page.filter((row) => needsImageAnalysis(row.metadata, row.mode ?? "fill_missing", row.assessed !== null));
      if (missing.length) {
        await transaction.insert(jobs).values(missing.map(({ fileId, workspaceId, mode }) => ({
          fileId, workspaceId, ownerUserId: userId, model, mode: mode ?? "fill_missing",
        }))).onConflictDoUpdate({
          target: jobs.fileId,
          set: { model, outputLanguage: null, status: "pending", attempts: 0, availableAt: new Date(), claimedAt: null, leaseExpiresAt: null, lastErrorCode: null },
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
      const owners = await db.select({ userId: schema.user.id }).from(schema.user);
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
        const due = and(
          reference ? and(eq(jobs.fileId, reference.fileId), eq(jobs.ownerUserId, reference.ownerUserId), eq(jobs.model, reference.model)) : undefined,
          eq(jobs.model, model), lte(jobs.availableAt, now),
          or(eq(jobs.status, "pending"), and(eq(jobs.status, "processing"), lte(jobs.leaseExpiresAt, now))),
        );
        const owners = reference ? [reference.ownerUserId] : (await transaction.select({ ownerUserId: jobs.ownerUserId }).from(jobs).where(due)
          .groupBy(jobs.ownerUserId).orderBy(sql`min(${jobs.availableAt})`, asc(jobs.ownerUserId)).limit(100)).map((row) => row.ownerUserId);
        for (const ownerUserId of owners) {
          // Forced RLS hides files and attachments until the job owner's identity is set.
          if (isPostgres) await transaction.execute(sql`select set_config('app.user_id', ${ownerUserId}, true)`);
          const ready = exists(transaction.select({ id: files.fileId }).from(files).where(and(
            eq(files.fileId, jobs.fileId), eq(files.workspaceId, jobs.workspaceId), eq(files.active, true),
            isNotNull(files.uploadedAt), inArray(files.contentType, [...imageContentTypes]),
            exists(transaction.select({ id: schema.meetingAttachment.id }).from(schema.meetingAttachment)
              .innerJoin(schema.syncedMeeting, and(
                eq(schema.syncedMeeting.workspaceId, schema.meetingAttachment.workspaceId),
                eq(schema.syncedMeeting.meetingId, schema.meetingAttachment.meetingId),
              )).where(and(eq(schema.meetingAttachment.fileId, jobs.fileId),
                isNull(schema.syncedMeeting.deletingAt), isNull(schema.syncedMeeting.deletedAt)))),
          )));
          const query = transaction.select().from(jobs).where(and(due, eq(jobs.ownerUserId, ownerUserId), ready))
            .orderBy(asc(jobs.availableAt), asc(jobs.fileId)).limit(1);
          const [row] = isPostgres ? await query.for("update", { skipLocked: true }) : await query;
          if (!row) continue;
          const [workspace] = await transaction.select({ settings: schema.syncedWorkspace.generationSettings })
            .from(schema.syncedWorkspace).where(eq(schema.syncedWorkspace.workspaceId, row.workspaceId));
          if (!workspace) { await transaction.delete(jobs).where(eq(jobs.fileId, row.fileId)); return null; }
          const outputLanguage = row.outputLanguage ?? workspace.settings.outputLanguage;
          await transaction.update(jobs).set({
            outputLanguage, status: "processing", claimedAt: now, leaseExpiresAt: new Date(now.getTime() + 300_000),
          }).where(eq(jobs.fileId, row.fileId));
          return { ...row, outputLanguage, claimedAt: now };
        }
        return null;
      });
    },
    claimBatch(claim, limit) {
      return db.transaction(async (transaction) => {
        if (isPostgres) await transaction.execute(sql`select set_config('app.user_id', ${claim.ownerUserId}, true)`);
        const attachments = schema.meetingAttachment;
        const [attachment] = await transaction.select({ meetingId: attachments.meetingId }).from(attachments)
          .innerJoin(schema.syncedMeeting, and(eq(schema.syncedMeeting.workspaceId, attachments.workspaceId),
            eq(schema.syncedMeeting.meetingId, attachments.meetingId)))
          .where(and(eq(attachments.fileId, claim.fileId), eq(attachments.workspaceId, claim.workspaceId),
            isNull(schema.syncedMeeting.deletingAt), isNull(schema.syncedMeeting.deletedAt)))
          .orderBy(asc(attachments.meetingId)).limit(1);
        if (!attachment || limit <= 0) return { meetingId: attachment?.meetingId ?? null, claims: [] };
        const now = new Date();
        const query = transaction.select({ job: jobs }).from(jobs)
          .innerJoin(attachments, and(eq(attachments.fileId, jobs.fileId), eq(attachments.workspaceId, jobs.workspaceId)))
          .innerJoin(files, and(eq(files.fileId, jobs.fileId), eq(files.workspaceId, jobs.workspaceId)))
          .where(and(
            eq(attachments.meetingId, attachment.meetingId), ne(jobs.fileId, claim.fileId),
            eq(jobs.workspaceId, claim.workspaceId), eq(jobs.ownerUserId, claim.ownerUserId), eq(jobs.model, claim.model),
            eq(jobs.attempts, 0), lte(jobs.availableAt, now), eq(files.active, true), isNotNull(files.uploadedAt),
            inArray(files.contentType, [...imageContentTypes]),
            or(eq(jobs.status, "pending"), and(eq(jobs.status, "processing"), lte(jobs.leaseExpiresAt, now))),
          )).orderBy(asc(sql`coalesce(${attachments.capturedAt}, ${attachments.createdAt})`), asc(jobs.fileId)).limit(limit);
        const rows = isPostgres ? await query.for("update", { of: jobs, skipLocked: true }) : await query;
        const siblings = [...new Map(rows.map(({ job }) => [job.fileId, job])).values()];
        if (siblings.length) {
          await transaction.update(jobs).set({
            outputLanguage: claim.outputLanguage, status: "processing", claimedAt: claim.claimedAt,
            leaseExpiresAt: new Date(claim.claimedAt.getTime() + 300_000),
          }).where(inArray(jobs.fileId, siblings.map((job) => job.fileId)));
        }
        return { meetingId: attachment.meetingId, claims: siblings.map((job) => ({ ...job, outputLanguage: claim.outputLanguage, claimedAt: claim.claimedAt })) };
      });
    },
    async release(claim) {
      await db.update(jobs).set({ status: "pending", claimedAt: null, leaseExpiresAt: null }).where(and(
        eq(jobs.fileId, claim.fileId), eq(jobs.ownerUserId, claim.ownerUserId),
        eq(jobs.model, claim.model), eq(jobs.claimedAt, claim.claimedAt)));
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
