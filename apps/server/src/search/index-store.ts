import { and, asc, eq, exists, gt, isNotNull, isNull, lte, ne, or, sql } from "drizzle-orm";
import type { AnyColumn } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import { Buffer } from "node:buffer";

import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as postgresSchema from "../db/auth-schema";
import * as sqliteSchema from "../db/sqlite-schema";

type SearchSchema = typeof postgresSchema;
type SearchDatabase = NodePgDatabase;
const RECONCILE_BATCH_SIZE = 500;

export interface SearchIndexJobRecord {
  vaultId: string;
  documentId: string;
  ownerUserId: string;
  generation: number;
  attempts: number;
  claimedAt: Date;
}

export interface SearchIndexDocumentRecord extends SearchIndexJobRecord {
  embeddingText: string;
  contentHash: string;
}

export type SearchIndexReference = Pick<SearchIndexJobRecord, "vaultId" | "documentId" | "ownerUserId" | "generation">;

export interface SearchIndexStore {
  reconcile(model: string, dimensions: number): Promise<void>;
  claim(model: string, dimensions: number, limit: number, references?: readonly SearchIndexReference[]): Promise<SearchIndexJobRecord[]>;
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
  reconcilePage(model: string, dimensions: number, ownerUserId: string, after?: string): Promise<string | undefined>;
  due(model: string, dimensions: number, ownerUserId: string, after?: string): Promise<SearchIndexReference[]>;
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
  const ownerFilter = (userId: string, vault: AnyColumn) => exists(
    db.select({ value: sql`1` }).from(schema.syncedVaultPermission).where(and(
      eq(schema.syncedVaultPermission.vaultId, vault),
      eq(schema.syncedVaultPermission.principalType, "user"),
      eq(schema.syncedVaultPermission.principalId, userId),
      eq(schema.syncedVaultPermission.role, "owner"),
    )),
  );
  const withOwner = <T>(userId: string, action: (transaction: SearchDatabase) => Promise<T>) =>
    db.transaction(async (transaction) => {
      if (isPostgres) {
        await transaction.execute(sql`select set_config('app.user_id', ${userId}, true)`);
      }
      return action(transaction);
    });
  const jobKey = (job: SearchIndexJobRecord) => and(
    eq(schema.searchIndexJob.vaultId, job.vaultId),
    eq(schema.searchIndexJob.documentId, job.documentId),
    eq(schema.searchIndexJob.generation, job.generation),
    eq(schema.searchIndexJob.claimedAt, job.claimedAt),
  );
  const documentKey = ({ vaultId, documentId }: Pick<SearchIndexJobRecord, "vaultId" | "documentId">) =>
    `${vaultId}\0${documentId}`;
  const groupByOwner = <T extends SearchIndexJobRecord>(items: T[]) => {
    const groups = new Map<string, T[]>();
    for (const item of items) groups.set(item.ownerUserId, [...(groups.get(item.ownerUserId) ?? []), item]);
    return groups;
  };

  function liveDocumentParentFilters(transaction: SearchDatabase) {
    return [
      exists(transaction.select({ value: sql`1` }).from(schema.syncedMeeting).where(and(
        eq(schema.syncedMeeting.vaultId, schema.searchDocument.vaultId),
        eq(schema.syncedMeeting.meetingId, schema.searchDocument.meetingId),
        isNull(schema.syncedMeeting.deletingAt),
      ))),
      exists(transaction.select({ value: sql`1` }).from(schema.syncedVault).where(and(
        eq(schema.syncedVault.vaultId, schema.searchDocument.vaultId),
        isNull(schema.syncedVault.deletingAt),
      ))),
    ];
  }

  async function loadMany(jobs: SearchIndexJobRecord[]): Promise<SearchIndexDocumentRecord[]> {
    const groups = groupByOwner(jobs);
    const results = await Promise.all([...groups].map(([userId, ownerJobs]) => withOwner(userId, async (transaction) => {
      const rows = await transaction.select({
        vaultId: schema.searchDocument.vaultId,
        documentId: schema.searchDocument.documentId,
        embeddingText: schema.searchDocument.searchText,
        contentHash: schema.searchDocument.embeddingContentHash,
      }).from(schema.searchDocument).where(and(
        ownerFilter(userId, schema.searchDocument.vaultId),
        or(...ownerJobs.map((job) => and(
          eq(schema.searchDocument.vaultId, job.vaultId),
          eq(schema.searchDocument.documentId, job.documentId),
        ))),
        ...liveDocumentParentFilters(transaction),
      ));
      const jobsByKey = new Map(ownerJobs.map((job) => [documentKey(job), job]));
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
    const savedGroups = await Promise.all([...groupByOwner(documents)].map(([userId, ownerDocuments]) =>
      withOwner(userId, async (transaction) => {
        const saved = new Set<string>();
        for (const document of ownerDocuments) {
          const embedding = embeddingByKey.get(documentKey(document))!;
          if (isPostgres) {
            // Serialize result writes before checking the job in a fresh statement snapshot.
            await transaction.select({ documentId: schema.searchDocument.documentId }).from(schema.searchDocument)
              .where(and(eq(schema.searchDocument.vaultId, document.vaultId),
                eq(schema.searchDocument.documentId, document.documentId), ownerFilter(userId, schema.searchDocument.vaultId)))
              .for("update");
          }
          const rows = await transaction.update(schema.searchDocument).set({
            embedding: (isPostgres ? embedding : encodeFloat32(embedding)) as never,
            embeddingModel: model,
          }).where(and(
            ownerFilter(userId, schema.searchDocument.vaultId),
            eq(schema.searchDocument.vaultId, document.vaultId),
            eq(schema.searchDocument.documentId, document.documentId),
            eq(schema.searchDocument.embeddingContentHash, document.contentHash),
            exists(transaction.select({ value: sql`1` }).from(schema.searchIndexJob).where(and(
              jobKey(document), eq(schema.searchIndexJob.model, model), eq(schema.searchIndexJob.dimensions, dimensions),
              eq(schema.searchIndexJob.status, "processing"),
            ))),
            ...liveDocumentParentFilters(transaction),
          )).returning({ documentId: schema.searchDocument.documentId });
          if (rows.length) {
            saved.add(documentKey(document));
            await transaction.delete(schema.searchIndexJob).where(jobKey(document));
          }
        }
        return saved;
      })));
    return new Set(savedGroups.flatMap((keys) => [...keys]));
  }

  function afterDocument(documentId: AnyColumn, vaultId: AnyColumn, after?: string) {
    if (!after) return undefined;
    const [id, vault] = after.split("/");
    return or(gt(documentId, id!), and(eq(documentId, id!), gt(vaultId, vault!)));
  }
  async function reconcilePage(model: string, dimensions: number, userId: string, after?: string, batchSize = 100): Promise<string | undefined> {
    return withOwner(userId, async (transaction) => {
      const documents = await transaction.select({
        vaultId: schema.searchDocument.vaultId,
        documentId: schema.searchDocument.documentId,
      }).from(schema.searchDocument)
        .leftJoin(schema.searchIndexJob, and(
          eq(schema.searchIndexJob.vaultId, schema.searchDocument.vaultId),
          eq(schema.searchIndexJob.documentId, schema.searchDocument.documentId),
        ))
        .where(and(
          ownerFilter(userId, schema.searchDocument.vaultId),
          isNotNull(schema.searchDocument.embeddingContentHash),
          or(isNull(schema.searchDocument.embedding), isNull(schema.searchDocument.embeddingModel),
            ne(schema.searchDocument.embeddingModel, model),
            sql`${isPostgres ? sql`cardinality(${schema.searchDocument.embedding})` : sql`length(${schema.searchDocument.embedding}) / 4`} <> ${dimensions}`),
          afterDocument(schema.searchDocument.documentId, schema.searchDocument.vaultId, after),
          or(
            isNull(schema.searchIndexJob.documentId),
            ne(schema.searchIndexJob.model, model),
            ne(schema.searchIndexJob.dimensions, dimensions),
          ),
        )).orderBy(asc(schema.searchDocument.documentId), asc(schema.searchDocument.vaultId)).limit(batchSize);
      if (documents.length === 0) return undefined;
      const now = new Date();
      await transaction.insert(schema.searchIndexJob).values(documents.map((document) => ({
        ...document,
        ownerUserId: userId,
        model,
        dimensions,
        availableAt: now,
        updatedAt: now,
      }))).onConflictDoUpdate({
        target: [schema.searchIndexJob.vaultId, schema.searchIndexJob.documentId],
        set: {
          ownerUserId: userId,
          model,
          dimensions,
          generation: sql`${schema.searchIndexJob.generation} + 1`,
          status: "pending",
          attempts: 0,
          availableAt: now,
          claimedAt: null,
          leaseExpiresAt: null,
          lastErrorCode: null,
          updatedAt: now,
        },
      });
      if (documents.length < batchSize) return undefined;
      const last = documents.at(-1)!;
      return `${last.documentId}/${last.vaultId}`;
    });
  }
  return {
    reconcilePage,
    due(model, dimensions, ownerUserId, after) {
      const jobs = schema.searchIndexJob;
      return db.select({ vaultId: jobs.vaultId, documentId: jobs.documentId, ownerUserId: jobs.ownerUserId, generation: jobs.generation })
        .from(jobs).where(and(eq(jobs.model, model), eq(jobs.dimensions, dimensions), eq(jobs.ownerUserId, ownerUserId),
          afterDocument(jobs.documentId, jobs.vaultId, after), lte(jobs.availableAt, new Date()),
          or(eq(jobs.status, "pending"), and(eq(jobs.status, "processing"), lte(jobs.leaseExpiresAt, new Date())))))
        .orderBy(asc(jobs.documentId), asc(jobs.vaultId)).limit(100);
    },
    async reconcile(model, dimensions) {
      const owners = await db.selectDistinct({ userId: schema.syncedVaultPermission.principalId })
        .from(schema.syncedVaultPermission).where(and(
          eq(schema.syncedVaultPermission.principalType, "user"),
          eq(schema.syncedVaultPermission.role, "owner"),
        ));
      for (const { userId } of owners) {
        let after: string | undefined;
        while (true) {
          const next = await reconcilePage(model, dimensions, userId, after, RECONCILE_BATCH_SIZE);
          if (!next) break;
          after = next;
        }
      }
    },
    claim(model, dimensions, limit, references) {
      if (references?.length === 0) return Promise.resolve([]);
      return db.transaction(async (transaction) => {
        const now = new Date();
        const filter = and(
          references ? or(...references.map((ref) => and(
            eq(schema.searchIndexJob.vaultId, ref.vaultId), eq(schema.searchIndexJob.documentId, ref.documentId),
            eq(schema.searchIndexJob.ownerUserId, ref.ownerUserId), eq(schema.searchIndexJob.generation, ref.generation),
          ))) : undefined,
          eq(schema.searchIndexJob.model, model),
          eq(schema.searchIndexJob.dimensions, dimensions),
          lte(schema.searchIndexJob.availableAt, now),
          or(
            eq(schema.searchIndexJob.status, "pending"),
            and(eq(schema.searchIndexJob.status, "processing"), lte(schema.searchIndexJob.leaseExpiresAt, now)),
          ),
        );
        const query = transaction.select().from(schema.searchIndexJob).where(filter)
          .orderBy(asc(schema.searchIndexJob.availableAt), asc(schema.searchIndexJob.documentId)).limit(limit);
        const rows = isPostgres ? await query.for("update", { skipLocked: true }) : await query;
        const leaseExpiresAt = new Date(now.getTime() + 120_000);
        for (const row of rows) {
          await transaction.update(schema.searchIndexJob).set({
            status: "processing",
            claimedAt: now,
            leaseExpiresAt,
            updatedAt: now,
          }).where(and(
            eq(schema.searchIndexJob.vaultId, row.vaultId),
            eq(schema.searchIndexJob.documentId, row.documentId),
            eq(schema.searchIndexJob.generation, row.generation),
          ));
        }
        return rows.map((row) => ({
          vaultId: row.vaultId,
          documentId: row.documentId,
          ownerUserId: row.ownerUserId,
          generation: row.generation,
          attempts: row.attempts,
          claimedAt: now,
        }));
      });
    },
    load: async (job) => (await loadMany([job]))[0] ?? null,
    loadMany,
    save: async (job, model, dimensions, embedding) =>
      (await saveMany([job], model, dimensions, [embedding])).has(documentKey(job)),
    saveMany,
    async retry(job, errorCode, availableAt) {
      await db.update(schema.searchIndexJob).set({
        status: "pending",
        attempts: job.attempts + 1,
        availableAt,
        claimedAt: null,
        leaseExpiresAt: null,
        lastErrorCode: errorCode,
        updatedAt: new Date(),
      }).where(jobKey(job));
    },
    async fail(job, errorCode) {
      await db.update(schema.searchIndexJob).set({
        status: "failed",
        attempts: job.attempts + 1,
        claimedAt: null,
        leaseExpiresAt: null,
        lastErrorCode: errorCode,
        updatedAt: new Date(),
      }).where(jobKey(job));
    },
    async discard(job) {
      await db.delete(schema.searchIndexJob).where(jobKey(job));
    },
  };
}

function encodeFloat32(values: readonly number[]): Buffer {
  const value = Buffer.allocUnsafe(values.length * 4);
  values.forEach((item, index) => value.writeFloatLE(item, index * 4));
  return value;
}
