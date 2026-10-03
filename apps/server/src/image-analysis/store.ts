import { workspacePermissions } from "../auth/workspace-permissions";
import { and, asc, eq, exists, gt, inArray, isNotNull, isNull, ne, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as postgresSchema from "../db/auth-schema";
import * as sqliteSchema from "../db/sqlite-schema";
import type { EncryptionConfig } from "../encryption/crypto";
import { createContentEncryption } from "../encryption/store";
import { imageContentTypes } from "../files/model";
import { createJobStore, type BackgroundJob } from "../jobs/store";
import { enqueueJob, lockJob, payloadField, retryJob, settleJob } from "../jobs/state";
import { defaultJobLimits } from "../jobs/model";
import { isRateLimited } from "../jobs/rate-limit";
import type { ImageAnalysisClaim } from "./model";

export type ImageAnalysisReference = Pick<ImageAnalysisClaim, "fileId" | "ownerUserId" | "model">;
export interface ImageAnalysisStore {
  reconcile(model: string): Promise<void>;
  claim(model: string, reference?: ImageAnalysisReference | BackgroundJob): Promise<ImageAnalysisClaim | null>;
  finish(claim: ImageAnalysisClaim, error?: { code: string; retryAt?: Date }): Promise<void>;
}
export interface ImageAnalysisQueueStore extends ImageAnalysisStore {
  reconcilePage(model: string, ownerUserId: string, after?: string): Promise<string | undefined>;
  due(model: string, ownerUserId: string, after?: string): Promise<ImageAnalysisReference[]>;
}
export function createImageAnalysisStore(database: PostgresDatabase | SQLiteDatabase, isPostgres: boolean, encryption?: EncryptionConfig): ImageAnalysisQueueStore {
  const db = database as NodePgDatabase;
  const schema = (isPostgres ? postgresSchema : sqliteSchema) as typeof postgresSchema;
  const q = schema.backgroundJob, files = schema.syncedFile;
  const queue = createJobStore(database, isPostgres, defaultJobLimits);
  const withOwner = <T>(userId: string, action: (tx: NodePgDatabase) => Promise<T>) => db.transaction(async (tx) => {
    if (isPostgres) await tx.execute(sql`select set_config('app.user_id', ${userId}, true)`);
    return action(tx);
  });
  // Recover accepted jobs only. Missing file metadata never constitutes a request.
  async function reconcilePage(model: string, ownerUserId: string, after?: string): Promise<string | undefined> {
    return withOwner(ownerUserId, async (tx) => {
      const query = tx.select().from(q).where(and(eq(q.kind, "image"), eq(q.owner, ownerUserId),
        inArray(q.status, ["pending", "processing", "failed"]), ne(payloadField(schema, "model"), model),
        after ? gt(payloadField(schema, "fileId"), after) : undefined)).orderBy(asc(payloadField(schema, "fileId"))).limit(100);
      const rows = isPostgres ? await query.for("update") : await query;
      for (const row of rows) await enqueueJob(tx, schema, row.dedupeKey, "image", row.owner, row.target, { ...row.payload, model, outputLanguage: null });
      return rows.length === 100 ? rows.at(-1)!.payload.fileId : undefined;
    });
  }
  return {
    reconcilePage,
    async due(model, ownerUserId, after) {
      return (await db.select().from(q).where(and(eq(q.kind, "image"), eq(q.owner, ownerUserId),
        eq(payloadField(schema, "model"), model), inArray(q.status, ["pending", "processing"]),
        after ? gt(payloadField(schema, "fileId"), after) : undefined)).orderBy(asc(payloadField(schema, "fileId"))).limit(100))
        .map(({ payload }) => ({ fileId: payload.fileId!, ownerUserId: payload.ownerUserId!, model: payload.model! }));
    },
    async reconcile(model) {
      for (const { id } of await db.select({ id: schema.user.id }).from(schema.user)) {
        let after: string | undefined;
        do { after = await reconcilePage(model, id, after); } while (after);
      }
    },
    async claim(model, reference) {
      const dispatch = reference && "dedupeKey" in reference ? reference
        : await queue.claim(["image"], reference ? [`image:${reference.fileId}`] : undefined);
      if (!dispatch) return null;
      if (dispatch.payload.model !== model) { await queue.retry(dispatch, { delayMs: 60_000, errorCode: "job_source_not_ready" }); return null; }
      return withOwner(dispatch.payload.ownerUserId!, async (tx) => {
        if (!await lockJob(tx, schema, dispatch)) return null;
        const payload = dispatch.payload;
        const [file] = await tx.select({ fileId: files.fileId }).from(files).where(and(
          eq(files.fileId, payload.fileId!), eq(files.workspaceId, payload.workspaceId!), eq(files.active, true),
          isNotNull(files.uploadedAt), inArray(files.contentType, [...imageContentTypes]),
          workspacePermissions(tx, schema, payload.ownerUserId!).write(files.workspaceId)));
        const [attachment] = await tx.select({ id: schema.meetingAttachment.id }).from(schema.meetingAttachment).where(and(
          eq(schema.meetingAttachment.fileId, payload.fileId!),
          exists(tx.select({ id: schema.syncedMeeting.meetingId }).from(schema.syncedMeeting).where(and(
            eq(schema.syncedMeeting.workspaceId, schema.meetingAttachment.workspaceId),
            eq(schema.syncedMeeting.meetingId, schema.meetingAttachment.meetingId),
            isNull(schema.syncedMeeting.deletingAt), isNull(schema.syncedMeeting.deletedAt)))))).limit(1);
        const [workspace] = await createContentEncryption(tx, schema, payload.ownerUserId!, encryption).read(schema.syncedWorkspace,
          await tx.select().from(schema.syncedWorkspace).where(and(eq(schema.syncedWorkspace.workspaceId, payload.workspaceId!), isNull(schema.syncedWorkspace.deletingAt))));
        if (!file || !workspace) { await settleJob(tx, schema, dispatch); return null; }
        if (!attachment) {
          await retryJob(tx, schema, dispatch, { delayMs: 60_000, errorCode: "job_source_not_ready" });
          return null;
        }
        const outputLanguage = payload.outputLanguage ?? workspace.generationSettings.outputLanguage;
        if (payload.outputLanguage == null) {
          payload.outputLanguage = outputLanguage;
          await tx.update(q).set({ payload }).where(eq(q.id, dispatch.id));
        }
        return { queue: dispatch, fileId: payload.fileId!, workspaceId: payload.workspaceId!, ownerUserId: payload.ownerUserId!, model,
          mode: payload.mode!, outputLanguage,
          attempts: dispatch.attempts - 1, claimedAt: dispatch.claimedAt! };
      });
    },
    async finish(claim, error) {
      if (!claim.queue) return;
      await db.transaction((tx) => settleJob(tx, schema, claim.queue!, error ? {
        status: error.retryAt ? "pending" : "failed", lastError: error.code, availableAt: error.retryAt ?? new Date(),
      } : undefined));
      if (error?.retryAt && isRateLimited(error.code)) await queue.cooldown("image", error.retryAt.getTime());
    },
  };
}
