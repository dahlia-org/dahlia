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

export interface SearchIndexStore {
  reconcile(model: string, dimensions: number): Promise<void>;
  claim(model: string, dimensions: number, limit: number): Promise<SearchIndexJobRecord[]>;
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

export function createPostgresSearchIndexStore(db: PostgresDatabase): SearchIndexStore {
  return createSearchIndexStore(db, postgresSchema, true);
}

export function createSqliteSearchIndexStore(db: SQLiteDatabase): SearchIndexStore {
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
): SearchIndexStore {
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

  async function loadMany(jobs: SearchIndexJobRecord[]): Promise<SearchIndexDocumentRecord[]> {
    const groups = groupByOwner(jobs);
    const results = await Promise.all([...groups].map(([userId, ownerJobs]) => withOwner(userId, async (transaction) => {
      const rows = await transaction.select({
        vaultId: schema.searchDocument.vaultId,
        documentId: schema.searchDocument.documentId,
        embeddingText: schema.searchDocument.embeddingText,
        contentHash: schema.searchDocument.embeddingContentHash,
      }).from(schema.searchDocument).where(and(
        ownerFilter(userId, schema.searchDocument.vaultId),
        or(...ownerJobs.map((job) => and(
          eq(schema.searchDocument.vaultId, job.vaultId),
          eq(schema.searchDocument.documentId, job.documentId),
        ))),
        exists(transaction.select({ value: sql`1` }).from(schema.syncedMeeting).where(and(
          eq(schema.syncedMeeting.vaultId, schema.searchDocument.vaultId),
          eq(schema.syncedMeeting.meetingId, schema.searchDocument.meetingId),
          isNull(schema.syncedMeeting.deletingAt),
        ))),
        exists(transaction.select({ value: sql`1` }).from(schema.syncedVault).where(and(
          eq(schema.syncedVault.vaultId, schema.searchDocument.vaultId),
          isNull(schema.syncedVault.deletingAt),
        ))),
      ));
      const jobsByKey = new Map(ownerJobs.map((job) => [documentKey(job), job]));
      return rows.flatMap((row) => {
        const job = jobsByKey.get(documentKey(row));
        return job && row.embeddingText && row.contentHash
          ? [{ ...job, embeddingText: row.embeddingText, contentHash: row.contentHash }]
          : [];
      });
    })));
    return results.flat();
  }

  async function saveMany(
    documents: SearchIndexDocumentRecord[],
    model: string,
    dimensions: number,
    embeddings: number[][],
  ): Promise<Set<string>> {
    const embeddingByKey = new Map(documents.map((document, index) => [documentKey(document), embeddings[index]!]));
    const savedGroups = await Promise.all([...groupByOwner(documents)].map(([userId, ownerDocuments]) =>
      withOwner(userId, async (transaction) => {
        const current = await transaction.select({
          vaultId: schema.searchDocument.vaultId,
          documentId: schema.searchDocument.documentId,
        }).from(schema.searchDocument).where(and(
          ownerFilter(userId, schema.searchDocument.vaultId),
          or(...ownerDocuments.map((document) => and(
            eq(schema.searchDocument.vaultId, document.vaultId),
            eq(schema.searchDocument.documentId, document.documentId),
            eq(schema.searchDocument.embeddingContentHash, document.contentHash),
          ))),
          exists(transaction.select({ value: sql`1` }).from(schema.syncedMeeting).where(and(
            eq(schema.syncedMeeting.vaultId, schema.searchDocument.vaultId),
            eq(schema.syncedMeeting.meetingId, schema.searchDocument.meetingId),
            isNull(schema.syncedMeeting.deletingAt),
          ))),
          exists(transaction.select({ value: sql`1` }).from(schema.syncedVault).where(and(
            eq(schema.syncedVault.vaultId, schema.searchDocument.vaultId),
            isNull(schema.syncedVault.deletingAt),
          ))),
        ));
        const currentKeys = new Set(current.map(documentKey));
        const valid = ownerDocuments.filter((document) => currentKeys.has(documentKey(document)));
        if (valid.length === 0) return currentKeys;
        const now = new Date();
        await transaction.insert(schema.searchEmbedding).values(valid.map((document) => ({
          vaultId: document.vaultId,
          documentId: document.documentId,
          model,
          dimensions,
          contentHash: document.contentHash,
          embedding: (isPostgres
            ? embeddingByKey.get(documentKey(document))!
            : encodeFloat32(embeddingByKey.get(documentKey(document))!)) as never,
          updatedAt: now,
        }))).onConflictDoUpdate({
          target: [schema.searchEmbedding.vaultId, schema.searchEmbedding.documentId],
          set: {
            model: sql`excluded.model`,
            dimensions: sql`excluded.dimensions`,
            contentHash: sql`excluded.content_hash`,
            embedding: sql`excluded.embedding`,
            updatedAt: now,
          },
        });
        await transaction.delete(schema.searchIndexJob).where(or(...valid.map(jobKey)));
        return currentKeys;
      })));
    return new Set(savedGroups.flatMap((keys) => [...keys]));
  }

  return {
    async reconcile(model, dimensions) {
      const owners = await db.selectDistinct({ userId: schema.syncedVaultPermission.principalId })
        .from(schema.syncedVaultPermission).where(and(
          eq(schema.syncedVaultPermission.principalType, "user"),
          eq(schema.syncedVaultPermission.role, "owner"),
        ));
      for (const { userId } of owners) {
        let after: string | undefined;
        while (true) {
          const page = await withOwner(userId, async (transaction) => {
            const documents = await transaction.select({
              vaultId: schema.searchDocument.vaultId,
              documentId: schema.searchDocument.documentId,
            }).from(schema.searchDocument)
              .leftJoin(schema.searchEmbedding, and(
                eq(schema.searchEmbedding.vaultId, schema.searchDocument.vaultId),
                eq(schema.searchEmbedding.documentId, schema.searchDocument.documentId),
                eq(schema.searchEmbedding.model, model),
                eq(schema.searchEmbedding.dimensions, dimensions),
                eq(schema.searchEmbedding.contentHash, schema.searchDocument.embeddingContentHash),
              ))
              .leftJoin(schema.searchIndexJob, and(
                eq(schema.searchIndexJob.vaultId, schema.searchDocument.vaultId),
                eq(schema.searchIndexJob.documentId, schema.searchDocument.documentId),
              ))
              .where(and(
                ownerFilter(userId, schema.searchDocument.vaultId),
                isNotNull(schema.searchDocument.embeddingText),
                isNotNull(schema.searchDocument.embeddingContentHash),
                isNull(schema.searchEmbedding.documentId),
                after ? gt(schema.searchDocument.documentId, after) : undefined,
                or(
                  isNull(schema.searchIndexJob.documentId),
                  ne(schema.searchIndexJob.model, model),
                  ne(schema.searchIndexJob.dimensions, dimensions),
                ),
              )).orderBy(asc(schema.searchDocument.documentId)).limit(RECONCILE_BATCH_SIZE);
            if (documents.length === 0) return null;
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
            return {
              after: documents.at(-1)!.documentId,
              complete: documents.length < RECONCILE_BATCH_SIZE,
            };
          });
          if (!page) break;
          after = page.after;
          if (page.complete) break;
        }
      }
    },
    claim(model, dimensions, limit) {
      return db.transaction(async (transaction) => {
        const now = new Date();
        const filter = and(
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
