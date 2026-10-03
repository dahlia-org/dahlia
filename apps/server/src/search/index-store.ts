import { and, asc, eq, exists, gt, inArray, isNotNull, isNull, ne, notExists, or, sql } from "drizzle-orm";
import type { AnyColumn } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import { Buffer } from "node:buffer";

import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import { createJobStore, type BackgroundJob } from "../jobs/store";
import { claimKey, enqueueJob, lockJob, payloadField, settleJob } from "../jobs/state";
import { defaultJobLimits } from "../jobs/model";
import { isRateLimited } from "../jobs/rate-limit";
import * as postgresSchema from "../db/auth-schema";
import * as sqliteSchema from "../db/sqlite-schema";

type SearchSchema = typeof postgresSchema;
type SearchDatabase = NodePgDatabase;
const RECONCILE_BATCH_SIZE = 500;

export interface SearchIndexJobRecord {
  queue?: BackgroundJob;
  workspaceId: string;
  documentId: string;
  generation: number;
  attempts: number;
  claimedAt: Date;
}

export interface SearchIndexDocumentRecord extends SearchIndexJobRecord {
  embeddingText: string;
  contentHash: string;
}

export type SearchIndexReference = Pick<SearchIndexJobRecord, "workspaceId" | "documentId" | "generation">;

export interface SearchIndexStore {
  reconcile(model: string, dimensions: number): Promise<void>;
  claim(model: string, dimensions: number, limit: number, references?: readonly (SearchIndexReference | BackgroundJob)[]): Promise<SearchIndexJobRecord[]>;
  load(job: SearchIndexJobRecord): Promise<SearchIndexDocumentRecord | null>;
  loadMany(jobs: SearchIndexJobRecord[]): Promise<SearchIndexDocumentRecord[]>;
  save(job: SearchIndexDocumentRecord, model: string, dimensions: number, embedding: number[]): Promise<boolean>;
  saveMany(
    documents: SearchIndexDocumentRecord[],
    model: string,
    dimensions: number,
    embeddings: number[][],
  ): Promise<Set<string>>;
  retry(job: SearchIndexJobRecord, errorCode: string, availableAt: Date): Promise<void>;
  fail(job: SearchIndexJobRecord, errorCode: string): Promise<void>;
  discard(job: SearchIndexJobRecord): Promise<void>;
}

export interface SearchIndexQueueStore extends SearchIndexStore {
  reconcilePage(model: string, dimensions: number, workspaceId: string, after?: string): Promise<string | undefined>;
  due(model: string, dimensions: number, workspaceId: string, after?: string): Promise<SearchIndexReference[]>;
}

export function createPostgresSearchIndexStore(db: PostgresDatabase): SearchIndexQueueStore {
  return createSearchIndexStore(db, postgresSchema, true);
}

export function createSqliteSearchIndexStore(db: SQLiteDatabase): SearchIndexQueueStore {
  return createSearchIndexStore(
    db as unknown as SearchDatabase,
    sqliteSchema as unknown as SearchSchema,
    false,
  );
}

function createSearchIndexStore(
  db: SearchDatabase,
  schema: SearchSchema,
  isPostgres: boolean,
): SearchIndexQueueStore {
  const withWorkspace = <T>(workspaceId: string, action: (transaction: SearchDatabase) => Promise<T>) =>
    db.transaction(async (transaction) => {
      if (isPostgres) await transaction.execute(sql`select set_config('app.maintenance', 'search', true), set_config('app.maintenance_workspace_id', ${workspaceId}, true)`);
      return action(transaction);
    });
  const q = schema.backgroundJob;
  const queue = createJobStore(db, isPostgres, defaultJobLimits);
  const jobKey = (job: SearchIndexJobRecord) => job.queue ? claimKey(schema, job.queue) : sql`false`;
  const documentKey = ({ workspaceId, documentId }: Pick<SearchIndexJobRecord, "workspaceId" | "documentId">) =>
    `${workspaceId}\0${documentId}`;
  const groupByWorkspace = <T extends SearchIndexJobRecord>(items: T[]) => {
    const groups = new Map<string, T[]>();
    for (const item of items) {
      const group = groups.get(item.workspaceId);
      if (group) group.push(item);
      else groups.set(item.workspaceId, [item]);
    }
    return groups;
  };

  function liveDocumentParentFilters(transaction: SearchDatabase) {
    return [
      exists(transaction.select({ value: sql`1` }).from(schema.syncedMeeting).where(and(
        eq(schema.syncedMeeting.workspaceId, schema.searchDocument.workspaceId),
        eq(schema.syncedMeeting.meetingId, schema.searchDocument.meetingId),
        isNull(schema.syncedMeeting.deletingAt), isNull(schema.syncedMeeting.deletedAt),
      ))),
      exists(transaction.select({ value: sql`1` }).from(schema.syncedWorkspace).where(and(
        eq(schema.syncedWorkspace.workspaceId, schema.searchDocument.workspaceId),
        isNull(schema.syncedWorkspace.deletingAt),
      ))),
    ];
  }

  async function loadMany(jobs: SearchIndexJobRecord[]): Promise<SearchIndexDocumentRecord[]> {
    const groups = groupByWorkspace(jobs);
    const results = await Promise.all([...groups].map(([workspaceId, workspaceJobs]) => withWorkspace(workspaceId, async (transaction) => {
      const rows = await transaction.select({
        workspaceId: schema.searchDocument.workspaceId,
        documentId: schema.searchDocument.documentId,
        embeddingText: schema.searchDocument.searchText,
        contentHash: schema.searchDocument.embeddingContentHash,
      }).from(schema.searchDocument).where(and(
        eq(schema.searchDocument.workspaceId, workspaceId),
        or(...workspaceJobs.map((job) => and(
          eq(schema.searchDocument.workspaceId, job.workspaceId),
          eq(schema.searchDocument.documentId, job.documentId),
        ))),
        ...liveDocumentParentFilters(transaction),
      ));
      const jobsByKey = new Map(workspaceJobs.map((job) => [documentKey(job), job]));
      const documents: SearchIndexDocumentRecord[] = [];
      for (const row of rows) {
        const job = jobsByKey.get(documentKey(row));
        if (job && row.contentHash && row.embeddingText) {
          documents.push({ ...job, embeddingText: row.embeddingText, contentHash: row.contentHash });
        }
      }
      return documents;
    })));
    return results.flat();
  }

  async function saveMany(
    documents: SearchIndexDocumentRecord[],
    model: string,
    dimensions: number,
    embeddings: number[][],
  ): Promise<Set<string>> {
    if (!Number.isInteger(dimensions) || dimensions < 32 || dimensions > 1024
      || embeddings.length !== documents.length
      || embeddings.some((vector) => vector.length !== dimensions || vector.some((value) => !Number.isFinite(value)))) {
      throw new Error("embedding_dimensions_invalid");
    }
    const embeddingByKey = new Map(documents.map((document, index) => [documentKey(document), embeddings[index]!]));
    const savedGroups = await Promise.all([...groupByWorkspace(documents)].map(([workspaceId, workspaceDocuments]) =>
      withWorkspace(workspaceId, async (transaction) => {
        const saved = new Set<string>();
        for (const document of workspaceDocuments) {
          const embedding = embeddingByKey.get(documentKey(document))!;
          if (isPostgres) {
            // Serialize result writes before checking the job in a fresh statement snapshot.
            await transaction.select({ documentId: schema.searchDocument.documentId }).from(schema.searchDocument)
              .where(and(eq(schema.searchDocument.workspaceId, document.workspaceId),
                eq(schema.searchDocument.documentId, document.documentId), eq(schema.searchDocument.workspaceId, workspaceId)))
              .for("update");
          }
          if (!document.queue) continue;
          if (!await lockJob(transaction, schema, document.queue)) {
            await settleJob(transaction, schema, document.queue); continue;
          }
          const rows = await transaction.update(schema.searchDocument).set({
            embedding: (isPostgres ? embedding : encodeFloat32(embedding)) as never,
            embeddingModel: model,
          }).where(and(
            eq(schema.searchDocument.workspaceId, workspaceId),
            eq(schema.searchDocument.workspaceId, document.workspaceId),
            eq(schema.searchDocument.documentId, document.documentId),
            eq(schema.searchDocument.embeddingContentHash, document.contentHash),
            exists(transaction.select({ value: sql`1` }).from(q).where(and(
              jobKey(document), eq(payloadField(schema, "model"), model), sql`cast(${payloadField(schema, "dimensions")} as integer) = ${dimensions}`,
              eq(q.status, "processing"),
            ))),
            ...liveDocumentParentFilters(transaction),
          )).returning({ documentId: schema.searchDocument.documentId });
          if (rows.length) {
            saved.add(documentKey(document));
            if (!await settleJob(transaction, schema, document.queue)) throw new Error("job_lease_changed");
          }
        }
        return saved;
      })));
    return new Set(savedGroups.flatMap((keys) => [...keys]));
  }

  function afterDocument(documentId: AnyColumn, workspaceId: AnyColumn, after?: string) {
    if (!after) return undefined;
    const [id, workspace] = after.split("/");
    return or(gt(documentId, id!), and(eq(documentId, id!), gt(workspaceId, workspace!)));
  }
  async function reconcilePage(model: string, dimensions: number, workspaceId: string, after?: string, batchSize = 100): Promise<string | undefined> {
    return withWorkspace(workspaceId, async (transaction) => {
      const documents = await transaction.select({
        workspaceId: schema.searchDocument.workspaceId,
        documentId: schema.searchDocument.documentId,
      }).from(schema.searchDocument)
        .leftJoin(q, and(eq(q.kind, "search"),
          eq(q.dedupeKey, sql`'search:' || ${schema.searchDocument.workspaceId} || ':' || ${schema.searchDocument.documentId}`)))
        .where(and(
          eq(schema.searchDocument.workspaceId, workspaceId),
          ...liveDocumentParentFilters(transaction),
          isNotNull(schema.searchDocument.embeddingContentHash),
          or(isNull(schema.searchDocument.embedding), isNull(schema.searchDocument.embeddingModel),
            ne(schema.searchDocument.embeddingModel, model),
            sql`${isPostgres ? sql`cardinality(${schema.searchDocument.embedding})` : sql`length(${schema.searchDocument.embedding}) / 4`} <> ${dimensions}`),
          notExists(transaction.select({ id: q.id }).from(q).innerJoin(schema.meetingAttachment, and(
            eq(schema.meetingAttachment.workspaceId, schema.searchDocument.workspaceId), eq(schema.meetingAttachment.id, schema.searchDocument.documentId),
            eq(schema.meetingAttachment.fileId, payloadField(schema, "fileId", true))))
            .where(and(eq(q.kind, "image"), eq(payloadField(schema, "workspaceId", true), schema.searchDocument.workspaceId),
              eq(payloadField(schema, "mode"), "replace"), inArray(q.status, ["pending", "processing"])))),
          afterDocument(schema.searchDocument.documentId, schema.searchDocument.workspaceId, after),
          or(
            isNull(q.id),
            ne(payloadField(schema, "model"), model),
            sql`cast(${payloadField(schema, "dimensions")} as integer) <> ${dimensions}`,
          ),
        )).orderBy(asc(schema.searchDocument.documentId), asc(schema.searchDocument.workspaceId)).limit(batchSize);
      if (documents.length === 0) return undefined;
      for (const document of documents) await enqueueJob(transaction, schema,
        `search:${document.workspaceId}:${document.documentId}`, "search", document.workspaceId,
        `document:${document.workspaceId}:${document.documentId}`, { ...document, model, dimensions });
      if (documents.length < batchSize) return undefined;
      const last = documents.at(-1)!;
      return `${last.documentId}/${last.workspaceId}`;
    });
  }
  return {
    reconcilePage,
    async due(model, dimensions, workspaceId, after) {
      const rows = await db.select().from(q).where(and(eq(q.kind, "search"), eq(q.owner, workspaceId),
        eq(payloadField(schema, "model"), model), sql`cast(${payloadField(schema, "dimensions")} as integer) = ${dimensions}`,
        inArray(q.status, ["pending", "processing"]), after ? gt(payloadField(schema, "documentId"), after.split("/")[0]!) : undefined))
        .orderBy(asc(payloadField(schema, "documentId"))).limit(100);
      return rows.map((row) => ({ workspaceId: row.payload.workspaceId!, documentId: row.payload.documentId!, generation: row.generation }));
    },
    async reconcile(model, dimensions) {
      const workspaces = await db.selectDistinct({ workspaceId: schema.syncedWorkspacePermission.workspaceId }).from(schema.syncedWorkspacePermission);
      for (const { workspaceId } of workspaces) {
        let after: string | undefined;
        while (true) {
          const next = await reconcilePage(model, dimensions, workspaceId, after, RECONCILE_BATCH_SIZE);
          if (!next) break;
          after = next;
        }
      }
    },
    async claim(model, dimensions, limit, references) {
      if (references?.length === 0) return [];
      let dispatch = references?.filter((ref): ref is BackgroundJob => "dedupeKey" in ref) ?? [];
      if (!dispatch.length) {
        const dedupeKeys = references?.map((ref) => {
          const { workspaceId, documentId } = ref as SearchIndexReference;
          return `search:${workspaceId}:${documentId}`;
        });
        dispatch = (await queue.claim(["search"], dedupeKeys))?.batch ?? [];
      }
      const jobs: SearchIndexJobRecord[] = [];
      for (const row of dispatch) {
        if (row.payload.model !== model || row.payload.dimensions !== dimensions || jobs.length >= limit) {
          await queue.reschedule(row, row.payload, 60_000); continue;
        }
        jobs.push({ queue: row, workspaceId: row.payload.workspaceId!, documentId: row.payload.documentId!,
          generation: row.generation, attempts: row.attempts - 1, claimedAt: row.claimedAt! });
      }
      return jobs;
    },
    load: async (job) => (await loadMany([job]))[0] ?? null,
    loadMany,
    save: async (job, model, dimensions, embedding) =>
      (await saveMany([job], model, dimensions, [embedding])).has(documentKey(job)),
    saveMany,
    async retry(job, errorCode, availableAt) {
      if (!job.queue) return;
      await db.transaction((tx) => settleJob(tx, schema, job.queue!, { status: "pending", lastError: errorCode, availableAt,
        attempts: errorCode === "embedding_batch_deferred" ? Math.max(0, job.queue!.attempts - 1) : job.queue!.attempts }));
      if (isRateLimited(errorCode)) await queue.cooldown("search", availableAt.getTime());
    },
    async fail(job, errorCode) {
      if (job.queue) await db.transaction((tx) => settleJob(tx, schema, job.queue!, { status: "failed", lastError: errorCode }));
    },
    async discard(job) {
      if (job.queue) await db.transaction((tx) => settleJob(tx, schema, job.queue!));
    },

  };
}

function encodeFloat32(values: readonly number[]): Buffer {
  const value = Buffer.allocUnsafe(values.length * 4);
  values.forEach((item, index) => value.writeFloatLE(item, index * 4));
  return value;
}
