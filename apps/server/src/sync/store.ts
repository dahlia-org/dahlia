import { fileResponse, fileStorageKey, type FileMetadata } from "../files/model";
import {
  and,
  asc,
  desc,
  eq,
  exists,
  notExists,
  inArray,
  isNull,
  isNotNull,
  gt,
  lt,
  lte,
  or,
  sql,
} from "drizzle-orm";
import type { AnyColumn } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";

import type { Identity } from "../auth/identity";
import type { AppConfig } from "../config";
import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import { reciprocalRankFusion, SEARCH_CANDIDATE_LIMIT } from "../search/ranking";
import * as postgresSchema from "../db/auth-schema";
import * as sqliteSchema from "../db/sqlite-schema";
import type {
  IdentitySyncStore,
  MeetingSyncStore,
  SyncCanonicalRecord,
  SyncChangeRecord,
  SyncProjectView,
  SyncRevisionConflict,
  SyncScreenshotRecord,
  SyncSearchQuery,
  SyncTranscriptSegment,
  SyncTransaction,
  SyncTransactionResponse,
  SyncSnapshotPosition,
  SyncHistoryTarget,
} from "./types";

type SyncSchema = typeof postgresSchema;
export type SyncSearchBackend = "postgres" | "lakebase" | "sqlite";
const TRANSCRIPT_PATCH_RETENTION_MS = 24 * 60 * 60 * 1_000;
export const SYNC_HISTORY_RETENTION_MS = 90 * 24 * 60 * 60 * 1_000;
export const SYNC_RETENTION_BATCH_SIZE = 1_000;
export const SYNC_SNAPSHOT_PAGE_BYTES = 8 * 1024 * 1024;
export const SYNC_SNAPSHOT_ENTITIES = ["vault", "project", "meeting", "summary", "transcript", "file", "meeting_file"] as const;

function batches<T>(values: T[], size: number): T[][] {
  const result: T[][] = [];
  for (let offset = 0; offset < values.length; offset += size) result.push(values.slice(offset, offset + size));
  return result;
}

export function createPostgresMeetingSyncStore(
  db: PostgresDatabase,
  searchBackend: SyncSearchBackend = "postgres",
  embeddingConfig?: AppConfig["searchEmbedding"],
  sharingEnabled = false,
): MeetingSyncStore {
  let available: Promise<boolean> | undefined;
  const isAvailable = () => available ??= roleSupportsRls(db);
  const storageDeletes = createStorageDeleteStore(db, postgresSchema, true);
  return {
    isAvailable,
    ...storageDeletes,
    ...createHistoryMaintenanceStore(db, postgresSchema, true),
    async withIdentity(identity, action) {
      if (!await isAvailable()) throw new SyncStoreUnavailableError();
      return db.transaction(async (transaction) => {
        await transaction.execute(sql`select set_config('app.user_id', ${identity.userId}, true)`);
        await transaction.execute(sql`select set_config('app.sharing_enabled', ${sharingEnabled ? "true" : "false"}, true)`);
        if (searchBackend === "lakebase") {
          await transaction.execute(sql`select set_config('lakebase_bm25.prefilter', 'on', true)`);
        } else if (searchBackend === "postgres" && embeddingConfig) {
          await transaction.execute(sql`select set_config('hnsw.iterative_scan', 'strict_order', true)`);
        }
        return action(createIdentityStore(
          transaction,
          postgresSchema,
          identity,
          searchBackend,
          embeddingConfig,
          sharingEnabled,
        ));
      });
    },
  };
}

export function createSqliteMeetingSyncStore(
  db: SQLiteDatabase,
  embeddingConfig?: AppConfig["searchEmbedding"],
  sharingEnabled = false,
): MeetingSyncStore {
  const storageDeletes = createStorageDeleteStore(
    db as unknown as PostgresDatabase,
    sqliteSchema as unknown as SyncSchema,
    false,
  );
  return {
    isAvailable: () => Promise.resolve(true),
    ...storageDeletes,
    ...createHistoryMaintenanceStore(db as unknown as PostgresDatabase, sqliteSchema as unknown as SyncSchema, false),
    withIdentity: (identity, action) => Promise.resolve(db.transaction(async (transaction) => {
      return action(createIdentityStore(
        transaction as unknown as PostgresDatabase,
        sqliteSchema as unknown as SyncSchema,
        identity,
        "sqlite",
        embeddingConfig,
        sharingEnabled,
      ));
    })),
  };
}

export class SyncStoreUnavailableError extends Error {
  constructor() {
    super("sync_store_unavailable");
  }
}

export class SyncTransactionError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    readonly conflicts: SyncRevisionConflict[] = [],
    readonly operationId?: string,
  ) {
    super(code);
  }
}

export function createUnavailableMeetingSyncStore(): MeetingSyncStore {
  return {
    isAvailable: () => Promise.resolve(false),
    listHistoryTargets: () => Promise.reject(new SyncStoreUnavailableError()),
    pruneHistoryBatch: () => Promise.reject(new SyncStoreUnavailableError()),
    withIdentity: () => Promise.reject(new SyncStoreUnavailableError()),
    claimStorageDeletes: () => Promise.reject(new SyncStoreUnavailableError()),
    hasStorageDelete: () => Promise.reject(new SyncStoreUnavailableError()),
    enqueueStorageDelete: () => Promise.reject(new SyncStoreUnavailableError()),
    isStorageDeleteClaimCurrent: () => Promise.reject(new SyncStoreUnavailableError()),
    completeStorageDelete: () => Promise.reject(new SyncStoreUnavailableError()),
    failStorageDelete: () => Promise.reject(new SyncStoreUnavailableError()),
    withStorageKeyLock: () => Promise.reject(new SyncStoreUnavailableError()),
  };
}

function createHistoryMaintenanceStore(db: PostgresDatabase, schema: SyncSchema, isPostgres: boolean) {
  return {
    async listHistoryTargets(after?: SyncHistoryTarget): Promise<SyncHistoryTarget[]> {
      return db.select({ ownerUserId: schema.syncVaultState.ownerUserId, vaultId: schema.syncVaultState.vaultId })
        .from(schema.syncVaultState).where(after ? or(
          gt(schema.syncVaultState.ownerUserId, after.ownerUserId),
          and(eq(schema.syncVaultState.ownerUserId, after.ownerUserId), gt(schema.syncVaultState.vaultId, after.vaultId)),
        ) : undefined).orderBy(asc(schema.syncVaultState.ownerUserId), asc(schema.syncVaultState.vaultId)).limit(100);
    },
    async pruneHistoryBatch(target: SyncHistoryTarget) {
      return db.transaction(async (transaction) => {
        if (isPostgres) {
          await transaction.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`vault:${target.vaultId}`}, 0))`);
          await transaction.execute(sql`select set_config('app.user_id', ${target.ownerUserId}, true)`);
        }
        const statePredicate = and(
          eq(schema.syncVaultState.ownerUserId, target.ownerUserId),
          eq(schema.syncVaultState.vaultId, target.vaultId),
        );
        const [state] = await transaction.select().from(schema.syncVaultState).where(statePredicate).limit(1);
        if (!state) return { changesDeleted: 0, receiptsCompacted: 0 };
        const cutoff = new Date(Date.now() - SYNC_HISTORY_RETENTION_MS);
        const ledgerPredicate = and(
          eq(schema.syncChange.ownerUserId, target.ownerUserId),
          eq(schema.syncChange.vaultId, target.vaultId),
        );
        const rows = await transaction.select({ sequence: schema.syncChange.sequence, createdAt: schema.syncChange.createdAt })
          .from(schema.syncChange).where(ledgerPredicate).orderBy(asc(schema.syncChange.sequence)).limit(SYNC_RETENTION_BATCH_SIZE);
        // Only prune a contiguous prefix, even if server clocks moved backwards.
        const firstRetained = rows.findIndex((row) => row.createdAt >= cutoff);
        const expired = firstRetained < 0 ? rows : rows.slice(0, firstRetained);
        const through = expired.at(-1)?.sequence;
        if (through !== undefined) {
          await transaction.update(schema.syncVaultState).set({ prunedThrough: Math.max(state.prunedThrough, through) })
            .where(statePredicate);
          await transaction.delete(schema.syncChange).where(and(ledgerPredicate, lte(schema.syncChange.sequence, through)));
        }
        const receipts = await transaction.select({ id: schema.syncTransactionReceipt.transactionId })
          .from(schema.syncTransactionReceipt).where(and(
            eq(schema.syncTransactionReceipt.ownerUserId, target.ownerUserId),
            eq(schema.syncTransactionReceipt.vaultId, target.vaultId),
            lt(schema.syncTransactionReceipt.createdAt, cutoff),
            isNotNull(schema.syncTransactionReceipt.responseJson),
          )).orderBy(asc(schema.syncTransactionReceipt.createdAt), asc(schema.syncTransactionReceipt.transactionId))
          .limit(SYNC_RETENTION_BATCH_SIZE);
        // SQLite's parameter limit is lower than the maintenance batch size.
        for (const batch of batches(receipts, 100)) {
          await transaction.update(schema.syncTransactionReceipt).set({ responseJson: null })
            .where(and(
              eq(schema.syncTransactionReceipt.ownerUserId, target.ownerUserId),
              inArray(schema.syncTransactionReceipt.transactionId, batch.map(({ id }) => id)),
            ));
        }
        return { changesDeleted: expired.length, receiptsCompacted: receipts.length };
      });
    },
  };
}

function createStorageDeleteStore(db: PostgresDatabase, schema: SyncSchema, isPostgres: boolean) {
  return {
    async hasStorageDelete(storageKey: string): Promise<boolean> {
      const [row] = await db.select({ key: schema.storageDeleteJob.storageKey })
        .from(schema.storageDeleteJob).where(eq(schema.storageDeleteJob.storageKey, storageKey)).limit(1);
      return row !== undefined;
    },
    async enqueueStorageDelete(storageKey: string): Promise<void> {
      await db.insert(schema.storageDeleteJob).values({ storageKey }).onConflictDoNothing();
    },
    async claimStorageDeletes(limit: number) {
      return db.transaction(async (transaction) => {
        const now = new Date();
        const query = transaction.select({
          storageKey: schema.storageDeleteJob.storageKey,
          attempts: schema.storageDeleteJob.attempts,
        })
          .from(schema.storageDeleteJob).where(or(
            and(
              inArray(schema.storageDeleteJob.status, ["pending", "failed"]),
              lt(schema.storageDeleteJob.availableAt, new Date(now.getTime() + 1)),
            ),
            and(
              eq(schema.storageDeleteJob.status, "processing"),
              lt(schema.storageDeleteJob.leaseExpiresAt, now),
            ),
          )).orderBy(asc(schema.storageDeleteJob.availableAt)).limit(limit);
        const rows = isPostgres ? await query.for("update", { skipLocked: true }) : await query;
        const keys = rows.map(({ storageKey }) => storageKey);
        if (keys.length) await transaction.update(schema.storageDeleteJob).set({
          status: "processing",
          attempts: sql`${schema.storageDeleteJob.attempts} + 1`,
          claimedAt: now,
          leaseExpiresAt: new Date(now.getTime() + 60_000),
        }).where(inArray(schema.storageDeleteJob.storageKey, keys));
        return rows.map(({ storageKey, attempts }) => ({ storageKey, attempt: attempts + 1 }));
      });
    },
    async isStorageDeleteClaimCurrent(claim: { storageKey: string; attempt: number }): Promise<boolean> {
      const [row] = await db.select({ storageKey: schema.storageDeleteJob.storageKey })
        .from(schema.storageDeleteJob).where(and(
          eq(schema.storageDeleteJob.storageKey, claim.storageKey),
          eq(schema.storageDeleteJob.status, "processing"),
          eq(schema.storageDeleteJob.attempts, claim.attempt),
        )).limit(1);
      return row !== undefined;
    },
    async completeStorageDelete(claim: { storageKey: string; attempt: number }): Promise<void> {
      await db.delete(schema.storageDeleteJob).where(and(
        eq(schema.storageDeleteJob.storageKey, claim.storageKey),
        eq(schema.storageDeleteJob.status, "processing"),
        eq(schema.storageDeleteJob.attempts, claim.attempt),
      ));
    },
    async failStorageDelete(claim: { storageKey: string; attempt: number }, code: string): Promise<void> {
      await db.update(schema.storageDeleteJob).set({
        status: "failed",
        availableAt: new Date(Date.now() + 60_000),
        claimedAt: null,
        leaseExpiresAt: null,
        lastErrorCode: code,
      }).where(and(
        eq(schema.storageDeleteJob.storageKey, claim.storageKey),
        eq(schema.storageDeleteJob.status, "processing"),
        eq(schema.storageDeleteJob.attempts, claim.attempt),
      ));
    },
    async withStorageKeyLock<T>(storageKey: string, action: () => Promise<T>): Promise<T> {
      if (!isPostgres) return action();
      const client = await db.$client.connect();
      const lockKey = `storage:${storageKey}`;
      try {
        await client.query("select pg_advisory_lock(hashtextextended($1, 0))", [lockKey]);
        try {
          return await action();
        } finally {
          await client.query("select pg_advisory_unlock(hashtextextended($1, 0))", [lockKey]);
        }
      } finally {
        client.release();
      }
    },
  };
}

async function roleSupportsRls(db: PostgresDatabase): Promise<boolean> {
  const client = await db.$client.connect();
  let transaction = false;
  try {
    const role = (await client.query<{ rolsuper: boolean; rolbypassrls: boolean }>(
      "select rolsuper, rolbypassrls from pg_roles where rolname = current_user",
    )).rows[0];
    if (role?.rolsuper !== false || role.rolbypassrls !== false) return false;
    const tables = [
      "app.vaults",
      "app.projects",
      "app.transaction_receipts",
      "app.meetings",
      "app.transcript_segments",
      "app.transcript_patch_chunks",
      "app.files",
      "app.meeting_files",
      "app.search_documents",
      "app.search_embeddings",
    ];
    const secured = (await client.query<{ count: number }>(`
      select count(*)::integer as count
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where format('%I.%I', n.nspname, c.relname) = any($1::text[])
        and c.relrowsecurity
        and c.relforcerowsecurity
        and pg_get_userbyid(c.relowner) = current_user
    `, [tables])).rows[0];
    if (secured?.count !== tables.length) return false;

    await client.query("begin");
    transaction = true;
    await client.query("select set_config('app.user_id', 'rls-probe', true)");
    await client.query("select set_config('app.sharing_enabled', 'false', true)");
    await client.query("select vault_id from app.vaults limit 1");
    await client.query("commit");
    transaction = false;
    if (!await identityContextIsEmpty(client)) return false;

    await client.query("begin");
    transaction = true;
    await client.query("select set_config('app.user_id', 'rls-probe', true)");
    await client.query("select set_config('app.sharing_enabled', 'false', true)");
    await client.query("rollback");
    transaction = false;
    return identityContextIsEmpty(client);
  } catch {
    if (transaction) await client.query("rollback").catch(() => undefined);
    return false;
  } finally {
    client.release();
  }
}

async function identityContextIsEmpty(client: import("pg").PoolClient): Promise<boolean> {
  const context = (await client.query<{
    user_id: string | null;
    sharing_enabled: string | null;
  }>(`
    select
      current_setting('app.user_id', true) as user_id,
      current_setting('app.sharing_enabled', true) as sharing_enabled
  `)).rows[0];
  return !context?.user_id && !context?.sharing_enabled;
}

function createIdentityStore(
  db: NodePgDatabase,
  schema: SyncSchema,
  identity: Identity,
  searchBackend: SyncSearchBackend,
  embeddingConfig?: AppConfig["searchEmbedding"],
  sharingEnabled = false,
): IdentitySyncStore {
  const userPrincipalId = identity.userId;
  const ownerAccess = (vault: AnyColumn) => exists(
    db.select({ value: sql`1` }).from(schema.syncedVaultPermission).where(and(
      eq(schema.syncedVaultPermission.vaultId, vault),
      eq(schema.syncedVaultPermission.principalType, "user"),
      eq(schema.syncedVaultPermission.principalId, userPrincipalId),
      eq(schema.syncedVaultPermission.role, "owner"),
    )),
  );
  const matchingMember = () => and(
    eq(schema.syncedVaultPermission.role, "member"),
    or(
      and(
        eq(schema.syncedVaultPermission.principalType, "user"),
        eq(schema.syncedVaultPermission.principalId, userPrincipalId),
      ),
      and(
        eq(schema.syncedVaultPermission.principalType, "organization"),
        exists(db.select({ value: sql`1` }).from(schema.member).where(and(
          eq(schema.member.userId, userPrincipalId),
          eq(schema.member.organizationId, schema.syncedVaultPermission.principalId),
        ))),
      ),
      and(
        eq(schema.syncedVaultPermission.principalType, "team"),
        exists(db.select({ value: sql`1` }).from(schema.teamMember).where(and(
          eq(schema.teamMember.userId, userPrincipalId),
          eq(schema.teamMember.teamId, schema.syncedVaultPermission.principalId),
        ))),
      ),
    ),
  );
  const memberAccess = (vault: AnyColumn) => exists(
    db.select({ value: sql`1` }).from(schema.syncedVaultPermission).where(and(
      eq(schema.syncedVaultPermission.vaultId, vault),
      matchingMember(),
    )),
  );
  const readable = !sharingEnabled
    ? ownerAccess
    : (vault: AnyColumn) => or(ownerAccess(vault), memberAccess(vault));
  const ownedVault = (vaultId: string) => and(
    eq(schema.syncedVault.vaultId, vaultId),
    ownerAccess(schema.syncedVault.vaultId),
  );
  const ownedMeeting = (vaultId: string, meetingId: string) => and(
    eq(schema.syncedMeeting.vaultId, vaultId),
    eq(schema.syncedMeeting.meetingId, meetingId),
    ownerAccess(schema.syncedMeeting.vaultId),
  );
  const readableMeeting = (vaultId: string, meetingId?: string) => and(
    readable(schema.syncedMeeting.vaultId),
    eq(schema.syncedMeeting.vaultId, vaultId),
    ...(meetingId ? [eq(schema.syncedMeeting.meetingId, meetingId)] : []),
  );
  const vaultRole = (vault: AnyColumn) => sql<"owner" | "member">`case when ${ownerAccess(vault)} then 'owner' else 'member' end`;

  async function lockVault(vaultId: string): Promise<void> {
    if (searchBackend !== "sqlite") {
      await db.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`vault:${vaultId}`}, 0))`);
    }
  }

  async function projectViews(vaultId: string): Promise<SyncProjectView[]> {
    const projects = await db.select().from(schema.syncedProject).where(and(
      readable(schema.syncedProject.vaultId),
      eq(schema.syncedProject.vaultId, vaultId),
    )).orderBy(asc(schema.syncedProject.parentProjectId), asc(schema.syncedProject.name), asc(schema.syncedProject.projectId));
    const meetings = await db.select({ projectId: schema.syncedMeeting.projectId })
      .from(schema.syncedMeeting).where(and(
        readableMeeting(vaultId),
        eq(schema.syncedMeeting.active, true),
        isNull(schema.syncedMeeting.deletingAt),
      ));
    const directCounts = new Map<string, number>();
    for (const { projectId } of meetings) {
      if (projectId) directCounts.set(projectId, (directCounts.get(projectId) ?? 0) + 1);
    }
    const byId = new Map(projects.map((project) => [project.projectId, project]));
    const childrenByParent = new Map<string, typeof projects>();
    for (const project of projects) {
      if (!project.parentProjectId) continue;
      const siblings = childrenByParent.get(project.parentProjectId) ?? [];
      siblings.push(project);
      childrenByParent.set(project.parentProjectId, siblings);
    }
    return projects.map((project) => {
      const root = project.parentProjectId ? byId.get(project.parentProjectId) : project;
      const children = project.parentProjectId ? [] : childrenByParent.get(project.projectId) ?? [];
      return {
        ...project,
        projectType: project.projectType as SyncProjectView["projectType"],
        path: project.parentProjectId && root ? `${root.name}/${project.name}` : project.name,
        rootProjectId: root?.projectId ?? project.projectId,
        effectiveType: (root?.projectType ?? "undefined") as SyncProjectView["effectiveType"],
        typeOwnerProjectId: root?.projectId ?? project.projectId,
        directMeetingCount: directCounts.get(project.projectId) ?? 0,
        subtreeMeetingCount: (directCounts.get(project.projectId) ?? 0)
          + children.reduce((count, child) => count + (directCounts.get(child.projectId) ?? 0), 0),
      };
    });
  }

  type SearchDocumentInput = {
    documentId: string;
    vaultId: string;
    meetingId: string;
    kind: "meeting" | "screenshot";
    searchText: string;
    embeddingText: string | null;
    embeddingContentHash: string | null;
    currentEmbeddingContentHash: string | null;
  };

  async function updateSearchDocuments(inputs: SearchDocumentInput[]): Promise<void> {
    const batchSize = searchBackend === "sqlite" ? 100 : 500;
    const now = new Date();
    for (let offset = 0; offset < inputs.length; offset += batchSize) {
      const batch = inputs.slice(offset, offset + batchSize);
      await db.insert(schema.searchDocument).values(batch.map((input) => ({
        documentId: input.documentId,
        vaultId: input.vaultId,
        meetingId: input.meetingId,
        kind: input.kind,
        searchText: input.searchText,
        embeddingText: input.embeddingText,
        embeddingContentHash: input.embeddingContentHash,
        updatedAt: now,
      }))).onConflictDoUpdate({
        target: [schema.searchDocument.vaultId, schema.searchDocument.documentId],
        set: {
          meetingId: sql`excluded.meeting_id`,
          kind: sql`excluded.kind`,
          searchText: sql`excluded.search_text`,
          embeddingText: sql`excluded.embedding_text`,
          embeddingContentHash: sql`excluded.embedding_content_hash`,
          updatedAt: now,
        },
      });
    }

    const withoutEmbedding = inputs.filter((input) => !embeddingConfig || !input.embeddingText || !input.embeddingContentHash);
    for (let offset = 0; offset < withoutEmbedding.length; offset += batchSize) {
      const batch = withoutEmbedding.slice(offset, offset + batchSize);
      const documentIds = batch.map(({ documentId }) => documentId);
      const vaultId = batch[0]!.vaultId;
      await db.delete(schema.searchIndexJob).where(and(
        eq(schema.searchIndexJob.vaultId, vaultId),
        inArray(schema.searchIndexJob.documentId, documentIds),
      ));
      await db.delete(schema.searchEmbedding).where(and(
        eq(schema.searchEmbedding.vaultId, vaultId),
        inArray(schema.searchEmbedding.documentId, documentIds),
      ));
    }

    if (!embeddingConfig) return;
    const changed = inputs.filter((input) => input.embeddingText
      && input.embeddingContentHash
      && input.currentEmbeddingContentHash !== input.embeddingContentHash);
    const availableAt = new Date(Date.now() + 5_000);
    for (let offset = 0; offset < changed.length; offset += batchSize) {
      await db.insert(schema.searchIndexJob).values(changed.slice(offset, offset + batchSize).map((input) => ({
        vaultId: input.vaultId,
        documentId: input.documentId,
        ownerUserId: userPrincipalId,
        model: embeddingConfig.model,
        dimensions: embeddingConfig.dimensions,
        availableAt,
        updatedAt: now,
      }))).onConflictDoUpdate({
        target: [schema.searchIndexJob.vaultId, schema.searchIndexJob.documentId],
        set: {
          ownerUserId: userPrincipalId,
          model: embeddingConfig.model,
          dimensions: embeddingConfig.dimensions,
          generation: sql`${schema.searchIndexJob.generation} + 1`,
          status: "pending",
          attempts: 0,
          availableAt,
          claimedAt: null,
          leaseExpiresAt: null,
          lastErrorCode: null,
          updatedAt: now,
        },
      });
    }
  }

  function ftsExpressions(query: SyncSearchQuery) {
    if (searchBackend === "sqlite") {
      const match = query.tokens.map((token) => `"${token.replaceAll('"', '""')}"`).join(" AND ");
      const table = sql.identifier("search_documents_fts");
      const sourceTable = sql.identifier("search_documents");
      return {
        filter: sql`exists (select 1 from ${table} where rowid = ${sourceTable}.rowid and ${table} match ${match})`,
        rank: sql<number>`(select rank from ${table} where rowid = ${sourceTable}.rowid and ${table} match ${match})`,
      };
    }
    const vector = schema.searchDocument.searchVector;
    if (!vector) throw new Error("search_vector_not_configured");
    const tsquery = sql`plainto_tsquery('simple', ${query.text})`;
    return {
      filter: sql`${vector} @@ ${tsquery}`,
      rank: searchBackend === "lakebase"
        ? sql<number>`${vector} <@> to_bm25query(
            to_tsvector('simple', ${query.text}),
            'app.search_documents_search_bm25'::regclass
          )`
        : sql<number>`-${sql`ts_rank_cd(${vector}, ${tsquery})`}`,
    };
  }

  async function ftsDocumentIds(
    vaultId: string,
    meetingId: string | undefined,
    kind: "meeting" | "screenshot",
    query: SyncSearchQuery,
  ): Promise<string[]> {
    const search = ftsExpressions(query);
    const common = and(
      readable(schema.searchDocument.vaultId),
      eq(schema.searchDocument.vaultId, vaultId),
      eq(schema.searchDocument.kind, kind),
      ...(meetingId ? [eq(schema.searchDocument.meetingId, meetingId)] : []),
      search.filter,
    );
    if (kind === "meeting") {
      return (await db.select({ documentId: schema.searchDocument.documentId, rank: search.rank })
        .from(schema.searchDocument)
        .innerJoin(schema.syncedMeeting, and(
          eq(schema.syncedMeeting.vaultId, schema.searchDocument.vaultId),
          eq(schema.syncedMeeting.meetingId, schema.searchDocument.documentId),
        ))
        .where(and(common, eq(schema.syncedMeeting.active, true), isNull(schema.syncedMeeting.deletingAt)))
        .orderBy(asc(search.rank), desc(schema.syncedMeeting.createdAt), desc(schema.syncedMeeting.meetingId))
        .limit(SEARCH_CANDIDATE_LIMIT)).map(({ documentId }) => documentId);
    }
    return (await db.select({ documentId: schema.searchDocument.documentId, rank: search.rank })
      .from(schema.searchDocument)
      .innerJoin(schema.syncedScreenshot, and(
        eq(schema.syncedScreenshot.vaultId, schema.searchDocument.vaultId),
        eq(schema.syncedScreenshot.screenshotId, schema.searchDocument.documentId),
      ))
      .where(and(common, eq(schema.syncedScreenshot.active, true)))
      .orderBy(asc(search.rank), asc(schema.syncedScreenshot.capturedAt), asc(schema.syncedScreenshot.screenshotId))
      .limit(SEARCH_CANDIDATE_LIMIT)).map(({ documentId }) => documentId);
  }

  async function vectorDocumentIds(
    vaultId: string,
    meetingId: string | undefined,
    kind: "meeting" | "screenshot",
    query: SyncSearchQuery,
  ): Promise<string[]> {
    const embedding = query.embedding;
    if (!embedding) return [];
    const common = and(
      readable(schema.searchDocument.vaultId),
      eq(schema.searchDocument.vaultId, vaultId),
      eq(schema.searchDocument.kind, kind),
      ...(meetingId ? [eq(schema.searchDocument.meetingId, meetingId)] : []),
      eq(schema.searchEmbedding.model, embedding.model),
      eq(schema.searchEmbedding.dimensions, embedding.dimensions),
      eq(schema.searchEmbedding.contentHash, schema.searchDocument.embeddingContentHash),
    );
    if (searchBackend === "sqlite") {
      const rows = kind === "meeting"
        ? await db.select({
            documentId: schema.searchDocument.documentId,
            vector: schema.searchEmbedding.embedding,
            sortTime: schema.syncedMeeting.createdAt,
          }).from(schema.searchDocument).innerJoin(schema.searchEmbedding, and(
            eq(schema.searchEmbedding.vaultId, schema.searchDocument.vaultId),
            eq(schema.searchEmbedding.documentId, schema.searchDocument.documentId),
          )).innerJoin(schema.syncedMeeting, and(
            eq(schema.syncedMeeting.vaultId, schema.searchDocument.vaultId),
            eq(schema.syncedMeeting.meetingId, schema.searchDocument.documentId),
          )).where(and(common, eq(schema.syncedMeeting.active, true), isNull(schema.syncedMeeting.deletingAt)))
        : await db.select({
            documentId: schema.searchDocument.documentId,
            vector: schema.searchEmbedding.embedding,
            sortTime: schema.syncedScreenshot.capturedAt,
          }).from(schema.searchDocument).innerJoin(schema.searchEmbedding, and(
            eq(schema.searchEmbedding.vaultId, schema.searchDocument.vaultId),
            eq(schema.searchEmbedding.documentId, schema.searchDocument.documentId),
          )).innerJoin(schema.syncedScreenshot, and(
            eq(schema.syncedScreenshot.vaultId, schema.searchDocument.vaultId),
            eq(schema.syncedScreenshot.screenshotId, schema.searchDocument.documentId),
          )).where(and(common, eq(schema.syncedScreenshot.active, true)));
      return rows.map(({ documentId, vector, sortTime }) => ({
        documentId,
        sortTime,
        similarity: cosineSimilarity(decodeFloat32(vector as unknown), embedding.vector),
      })).filter(({ similarity }) => Number.isFinite(similarity))
        .sort((left, right) => right.similarity - left.similarity
          || (kind === "meeting"
            ? right.sortTime.getTime() - left.sortTime.getTime()
            : left.sortTime.getTime() - right.sortTime.getTime())
          || left.documentId.localeCompare(right.documentId))
        .slice(0, SEARCH_CANDIDATE_LIMIT).map(({ documentId }) => documentId);
    }
    const vectorType = sql.raw(
      `${searchBackend === "postgres" ? "public." : ""}vector(${embedding.dimensions})`,
    );
    const distance = sql<number>`(
      ${schema.searchEmbedding.embedding}::${vectorType}
      <=> ${JSON.stringify(embedding.vector)}::${vectorType}
    )`;
    const base = db.select({ documentId: schema.searchDocument.documentId, distance })
      .from(schema.searchDocument).innerJoin(schema.searchEmbedding, and(
        eq(schema.searchEmbedding.vaultId, schema.searchDocument.vaultId),
        eq(schema.searchEmbedding.documentId, schema.searchDocument.documentId),
      ));
    const rows = kind === "meeting"
      ? await base.innerJoin(schema.syncedMeeting, and(
          eq(schema.syncedMeeting.vaultId, schema.searchDocument.vaultId),
          eq(schema.syncedMeeting.meetingId, schema.searchDocument.documentId),
        )).where(and(common, eq(schema.syncedMeeting.active, true), isNull(schema.syncedMeeting.deletingAt)))
        .orderBy(asc(distance), desc(schema.syncedMeeting.createdAt), desc(schema.syncedMeeting.meetingId))
        .limit(SEARCH_CANDIDATE_LIMIT)
      : await base.innerJoin(schema.syncedScreenshot, and(
          eq(schema.syncedScreenshot.vaultId, schema.searchDocument.vaultId),
          eq(schema.syncedScreenshot.screenshotId, schema.searchDocument.documentId),
        )).where(and(common, eq(schema.syncedScreenshot.active, true)))
        .orderBy(asc(distance), asc(schema.syncedScreenshot.capturedAt), asc(schema.syncedScreenshot.screenshotId))
        .limit(SEARCH_CANDIDATE_LIMIT);
    return rows.map(({ documentId }) => documentId);
  }

  async function rankedDocumentIds(
    vaultId: string,
    meetingId: string | undefined,
    kind: "meeting" | "screenshot",
    query: SyncSearchQuery,
  ): Promise<string[]> {
    const [fts, vector] = await Promise.all([
      query.ftsCandidateIds ?? ftsDocumentIds(vaultId, meetingId, kind, query),
      vectorDocumentIds(vaultId, meetingId, kind, query),
    ]);
    return reciprocalRankFusion(fts, vector).map(({ documentId }) => documentId);
  }

  async function ensureUploadTarget(vaultId: string, meetingId: string): Promise<boolean> {
    const [vault] = await db.select({ deletingAt: schema.syncedVault.deletingAt })
      .from(schema.syncedVault).where(ownedVault(vaultId)).limit(1);
    if (!vault || vault.deletingAt) return false;
    const [meeting] = await db.select({ active: schema.syncedMeeting.active, deletingAt: schema.syncedMeeting.deletingAt })
      .from(schema.syncedMeeting).where(ownedMeeting(vaultId, meetingId)).limit(1);
    return meeting?.active === true && meeting.deletingAt === null;
  }

  async function canonicalRecord(
    entity: SyncCanonicalRecord["entity"],
    vaultId: string,
    entityId: string,
    access: "owner" | "read" = "owner",
  ): Promise<SyncCanonicalRecord> {
    const canAccess = access === "owner" ? ownerAccess : readable;
    if (entity === "vault") {
      const [record] = await db.select().from(schema.syncedVault).where(and(
        eq(schema.syncedVault.vaultId, vaultId),
        canAccess(schema.syncedVault.vaultId),
      )).limit(1);
      return { entity, id: entityId, revision: record?.revision ?? null, record: record ?? null };
    }
    if (entity === "project") {
      const [record] = await db.select().from(schema.syncedProject).where(and(
        eq(schema.syncedProject.vaultId, vaultId),
        eq(schema.syncedProject.projectId, entityId),
        canAccess(schema.syncedProject.vaultId),
      )).limit(1);
      return { entity, id: entityId, revision: record?.revision ?? null, record: record ?? null };
    }
    if (["meeting", "summary", "transcript"].includes(entity)) {
      const [record] = await db.select().from(schema.syncedMeeting).where(and(
        eq(schema.syncedMeeting.vaultId, vaultId),
        eq(schema.syncedMeeting.meetingId, entityId),
        canAccess(schema.syncedMeeting.vaultId),
      )).limit(1);
      const revision = entity === "summary"
        ? record?.summaryRevision
        : entity === "transcript"
          ? record?.transcriptRevision
          : record?.revision;
      const value = entity === "summary" && record
        ? {
            meetingId: record.meetingId,
            title: record.summaryTitle,
            document: record.summaryDocument,
            createdAt: record.summaryCreatedAt,
          }
        : entity === "transcript" && record
          ? { meetingId: record.meetingId }
          : record;
      return { entity, id: entityId, revision: revision ?? null, record: value ?? null };
    }
    if (entity === "file") {
      const [record] = await db.select().from(schema.syncedFile).where(and(
        eq(schema.syncedFile.vaultId, vaultId), eq(schema.syncedFile.fileId, entityId), canAccess(schema.syncedFile.vaultId),
        ...(access === "read" ? [eq(schema.syncedFile.active, true)] : []),
      )).limit(1);
      return { entity, id: entityId, revision: record?.active ? record.revision : null,
        record: record ? { ...fileResponse(record), active: record.active } : null };
    }
    const [record] = await db.select().from(schema.meetingFile).where(and(
      eq(schema.meetingFile.vaultId, vaultId), eq(schema.meetingFile.id, entityId), canAccess(schema.meetingFile.vaultId),
    )).limit(1);
    return { entity, id: entityId, revision: record?.revision ?? null, record: record ?? null };
  }

  async function appendChange(
    transaction: SyncTransaction,
    entity: SyncCanonicalRecord["entity"],
    entityId: string,
    action: "upsert" | "delete" | "reset",
    revision: number | null,
  ): Promise<number> {
    return appendChanges(transaction, [{ entity, entityId, action, revision }]);
  }

  async function appendChanges(
    transaction: SyncTransaction,
    changes: Pick<SyncChangeRecord, "entity" | "entityId" | "action" | "revision">[],
  ): Promise<number> {
    let cursor: number | undefined;
    for (const batch of batches(changes, 100)) {
      const inserted = await db.insert(schema.syncChange).values(batch.map((change) => ({
        ...change,
        ownerUserId: userPrincipalId,
        vaultId: transaction.vaultId,
        transactionId: transaction.id,
      }))).returning({ sequence: schema.syncChange.sequence });
      if (!inserted.length) throw new SyncTransactionError(500, "sync_change_not_recorded");
      cursor = Math.max(...inserted.map(({ sequence }) => sequence));
    }
    if (cursor === undefined) throw new SyncTransactionError(500, "sync_change_not_recorded");
    await db.insert(schema.syncVaultState).values({
      ownerUserId: userPrincipalId,
      vaultId: transaction.vaultId,
      latestSequence: cursor,
    }).onConflictDoUpdate({
      target: [schema.syncVaultState.ownerUserId, schema.syncVaultState.vaultId],
      set: { latestSequence: cursor },
    });
    return cursor;
  }

  async function assertRevision(
    transaction: SyncTransaction,
    entity: SyncCanonicalRecord["entity"],
    entityId: string,
    baseRevision: number | null,
    missingDependencies: Array<{ entity: SyncCanonicalRecord["entity"]; id: string }> = [],
  ): Promise<void> {
    const current = await canonicalRecord(entity, transaction.vaultId, entityId);
    if (current.record === null) {
      const conflicts: SyncRevisionConflict[] = [{
        entity,
        id: entityId,
        clientBaseRevision: baseRevision,
        serverRevision: null,
        record: null,
      }];
      for (const dependency of missingDependencies) {
        const record = await canonicalRecord(dependency.entity, transaction.vaultId, dependency.id);
        if (record.record === null) conflicts.push({
          entity: dependency.entity,
          id: dependency.id,
          clientBaseRevision: null,
          serverRevision: null,
          record: null,
        });
      }
      throw new SyncTransactionError(409, "revision_conflict", conflicts);
    }
    if (current.revision !== baseRevision) {
      throw new SyncTransactionError(409, "revision_conflict", [{
        entity,
        id: entityId,
        clientBaseRevision: baseRevision,
        serverRevision: current.revision,
        record: current.record,
      }]);
    }
  }

  async function assertCreateAvailable(
    transaction: SyncTransaction,
    operation: SyncTransaction["operations"][number],
  ): Promise<void> {
    if (operation.action !== "create") return;
    const current = await canonicalRecord(operation.entity, transaction.vaultId, operation.entityId);
    if (current.record === null
      || (operation.entity === "vault" && current.revision === 0)
      || (operation.entity === "meeting" && current.record.active === false)) return;
    throw new SyncTransactionError(409, "revision_conflict", [{
      entity: operation.entity,
      id: operation.entityId,
      clientBaseRevision: null,
      serverRevision: current.revision,
      record: current.record,
    }], operation.id);
  }

  async function assertProjectHierarchy(
    vaultId: string,
    projectId: string,
    parentProjectId: string | null,
    operationId: string,
  ): Promise<void> {
    if (!parentProjectId) return;
    if (parentProjectId === projectId) {
      throw new SyncTransactionError(422, "invalid_project_parent", [], operationId);
    }
    const [parent] = await db.select({ parentProjectId: schema.syncedProject.parentProjectId })
      .from(schema.syncedProject).where(and(
        eq(schema.syncedProject.vaultId, vaultId),
        eq(schema.syncedProject.projectId, parentProjectId),
        ownerAccess(schema.syncedProject.vaultId),
      )).limit(1);
    if (!parent) {
      throw new SyncTransactionError(409, "revision_conflict", [{
        entity: "project",
        id: parentProjectId,
        clientBaseRevision: null,
        serverRevision: null,
        record: null,
      }], operationId);
    }
    if (parent.parentProjectId) {
      throw new SyncTransactionError(422, "invalid_project_parent", [], operationId);
    }
    const [child] = await db.select({ id: schema.syncedProject.projectId })
      .from(schema.syncedProject).where(and(
        eq(schema.syncedProject.vaultId, vaultId),
        eq(schema.syncedProject.parentProjectId, projectId),
        ownerAccess(schema.syncedProject.vaultId),
      )).limit(1);
    if (child) throw new SyncTransactionError(422, "invalid_project_hierarchy", [], operationId);
  }

  async function assertProjectReference(
    vaultId: string,
    projectId: string | null,
    operationId: string,
  ): Promise<void> {
    if (!projectId) return;
    const [project] = await db.select({ id: schema.syncedProject.projectId })
      .from(schema.syncedProject).where(and(
        eq(schema.syncedProject.vaultId, vaultId),
        eq(schema.syncedProject.projectId, projectId),
        ownerAccess(schema.syncedProject.vaultId),
      )).limit(1);
    if (!project) throw new SyncTransactionError(409, "revision_conflict", [{
      entity: "project",
      id: projectId,
      clientBaseRevision: null,
      serverRevision: null,
      record: null,
    }], operationId);
  }

  async function assertProjectDeletionAvailable(
    vaultId: string,
    projectId: string,
    operationId: string,
  ): Promise<void> {
    const conflicts: SyncRevisionConflict[] = [];
    const [child] = await db.select({ id: schema.syncedProject.projectId })
      .from(schema.syncedProject).where(and(
        eq(schema.syncedProject.vaultId, vaultId),
        eq(schema.syncedProject.parentProjectId, projectId),
        ownerAccess(schema.syncedProject.vaultId),
      )).limit(1);
    if (child) {
      const current = await canonicalRecord("project", vaultId, child.id);
      conflicts.push({
        entity: "project",
        id: child.id,
        clientBaseRevision: null,
        serverRevision: current.revision,
        record: current.record,
      });
    }
    const [meeting] = await db.select({ id: schema.syncedMeeting.meetingId })
      .from(schema.syncedMeeting).where(and(
        eq(schema.syncedMeeting.vaultId, vaultId),
        eq(schema.syncedMeeting.projectId, projectId),
        ownerAccess(schema.syncedMeeting.vaultId),
      )).limit(1);
    if (meeting) {
      const current = await canonicalRecord("meeting", vaultId, meeting.id);
      conflicts.push({
        entity: "meeting",
        id: meeting.id,
        clientBaseRevision: null,
        serverRevision: current.revision,
        record: current.record,
      });
    }
    if (conflicts.length) throw new SyncTransactionError(409, "revision_conflict", conflicts, operationId);
  }

  async function resolveTransaction(transaction: SyncTransaction): Promise<SyncTransactionResponse | null> {
    await lockVault(transaction.vaultId);
    if (searchBackend !== "sqlite") {
      await db.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`transaction:${transaction.id}`}, 0))`);
    }
    const [receipt] = await db.select().from(schema.syncTransactionReceipt).where(
      eq(schema.syncTransactionReceipt.transactionId, transaction.id),
    ).limit(1);
    if (!receipt) return null;
    const [owner] = await db.select({ id: schema.syncedVaultPermission.principalId })
      .from(schema.syncedVaultPermission).where(and(
        eq(schema.syncedVaultPermission.vaultId, transaction.vaultId),
        eq(schema.syncedVaultPermission.role, "owner"),
        eq(schema.syncedVaultPermission.principalType, "user"),
      )).limit(1);
    if ((owner && owner.id !== userPrincipalId) || receipt.ownerUserId !== userPrincipalId) {
      throw new SyncTransactionError(404, "vault_not_found");
    }
    if (receipt.vaultId !== transaction.vaultId || receipt.requestHash !== transaction.requestHash) {
      throw new SyncTransactionError(409, "idempotency_key_reused");
    }
    // After Vault deletion only acknowledge the operation; do not expose old content.
    if (receipt.responseJson !== null && owner) {
      return searchBackend === "sqlite"
        ? JSON.parse(receipt.responseJson as string) as SyncTransactionResponse
        : receipt.responseJson as SyncTransactionResponse;
    }
    const results = searchBackend === "sqlite"
      ? JSON.parse(receipt.resultsJson as string) as SyncTransactionResponse["records"]
      : receipt.resultsJson as SyncTransactionResponse["records"];
    return { id: transaction.id, status: "committed", receipt: "compact", cursor: encodeSyncCursor(receipt.cursor), records: results };
  }

  async function commitTransaction(transaction: SyncTransaction): Promise<SyncTransactionResponse> {
    const receipt = await resolveTransaction(transaction);
    if (receipt?.receipt === "compact") throw new SyncTransactionError(410, "transaction_receipt_expired");
    if (receipt) return receipt;

    const records: SyncCanonicalRecord[] = [];
    let cursor = 0;
    const firstOperation = transaction.operations[0];
    const establishesVault = firstOperation?.entity === "vault"
      && (firstOperation.action === "create"
        || (firstOperation.action === "reset" && transaction.operations.length === 1));
    if (!establishesVault) {
      const [vault] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
        .where(ownedVault(transaction.vaultId)).limit(1);
      if (!vault) throw new SyncTransactionError(409, "revision_conflict", [{
        entity: "vault",
        id: transaction.vaultId,
        clientBaseRevision: null,
        serverRevision: null,
        record: null,
      }], transaction.operations[0]?.id);
    }
    for (const operation of transaction.operations) {
      await assertCreateAvailable(transaction, operation);
      const data = operation.data ?? {};
      const now = new Date();
      if (operation.entity === "vault") {
        if (operation.action === "create") {
          const [existing] = await db.select({
            id: schema.syncedVault.vaultId,
            revision: schema.syncedVault.revision,
          }).from(schema.syncedVault)
            .where(eq(schema.syncedVault.vaultId, transaction.vaultId)).limit(1);
          if (existing?.revision === 0) {
            await db.update(schema.syncedVault).set({
              name: String(data.name),
              revision: 1,
              createdAt: data.createdAt as Date,
              updatedAt: now,
            }).where(ownedVault(transaction.vaultId));
          } else {
            if (existing) throw new SyncTransactionError(409, "revision_conflict", [{
              entity: "vault",
              id: operation.entityId,
              clientBaseRevision: null,
              serverRevision: (await canonicalRecord("vault", transaction.vaultId, operation.entityId)).revision,
              record: (await canonicalRecord("vault", transaction.vaultId, operation.entityId)).record,
            }], operation.id);
            await db.insert(schema.syncedVault).values({
              vaultId: transaction.vaultId,
              name: String(data.name),
              revision: 1,
              createdAt: data.createdAt as Date,
              updatedAt: now,
            });
            await db.insert(schema.syncedVaultPermission).values({
              vaultId: transaction.vaultId,
              principalType: "user",
              principalId: userPrincipalId,
              role: "owner",
              grantedByUserId: userPrincipalId,
            });
          }
        } else if (operation.action === "update") {
          await assertRevision(transaction, "vault", operation.entityId, operation.baseRevision);
          await db.update(schema.syncedVault).set({
            name: String(data.name),
            revision: sql`${schema.syncedVault.revision} + 1`,
            updatedAt: now,
          }).where(ownedVault(transaction.vaultId));
        } else if (operation.action === "reset") {
          const [owned] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
            .where(ownedVault(transaction.vaultId)).limit(1);
          if (!owned) {
            throw new SyncTransactionError(409, "revision_conflict", [{
              entity: "vault",
              id: operation.entityId,
              clientBaseRevision: operation.baseRevision,
              serverRevision: null,
              record: null,
            }], operation.id);
          }
          await assertRevision(transaction, "vault", operation.entityId, operation.baseRevision);
          const files = await db.select({ id: schema.syncedFile.fileId }).from(schema.syncedFile)
            .where(eq(schema.syncedFile.vaultId, transaction.vaultId));
          if (files.length) await db.insert(schema.storageDeleteJob)
            .values(files.map(({ id }) => ({ storageKey: fileStorageKey(id) }))).onConflictDoNothing();
          await db.delete(schema.meetingFile).where(eq(schema.meetingFile.vaultId, transaction.vaultId));
          await db.delete(schema.syncedFile).where(eq(schema.syncedFile.vaultId, transaction.vaultId));
          if (data.preservePermissions === true) {
            await db.delete(schema.searchIndexJob).where(eq(schema.searchIndexJob.vaultId, transaction.vaultId));
            await db.delete(schema.syncedMeeting).where(eq(schema.syncedMeeting.vaultId, transaction.vaultId));
            await db.delete(schema.syncedProject).where(eq(schema.syncedProject.vaultId, transaction.vaultId));
            await db.update(schema.syncedVault).set({ revision: 0, updatedAt: now })
              .where(ownedVault(transaction.vaultId));
          } else {
            await db.delete(schema.syncedVault).where(ownedVault(transaction.vaultId));
          }
          cursor = await appendChange(transaction, "vault", operation.entityId, "reset", null);
          records.push({ entity: "vault", id: operation.entityId, revision: null, record: null });
          continue;
        }
      } else if (operation.entity === "project") {
        if (operation.action === "create") {
          const parentProjectId = data.parentProjectId as string | null;
          await assertProjectHierarchy(transaction.vaultId, operation.entityId, parentProjectId, operation.id);
          await db.insert(schema.syncedProject).values({
            projectId: operation.entityId,
            vaultId: transaction.vaultId,
            parentProjectId,
            name: String(data.name),
            description: stringField(data, "description"),
            projectType: data.projectType as string | null,
            revision: 1,
            createdAt: data.createdAt as Date,
            updatedAt: now,
          });
        } else if (operation.action === "update") {
          const parentProjectId = data.parentProjectId as string | null;
          await assertRevision(transaction, "project", operation.entityId, operation.baseRevision,
            parentProjectId ? [{ entity: "project", id: parentProjectId }] : []);
          await assertProjectHierarchy(transaction.vaultId, operation.entityId, parentProjectId, operation.id);
          await db.update(schema.syncedProject).set({
            parentProjectId,
            name: String(data.name),
            description: stringField(data, "description"),
            projectType: data.projectType as string | null,
            revision: sql`${schema.syncedProject.revision} + 1`,
            updatedAt: now,
          }).where(and(
            eq(schema.syncedProject.vaultId, transaction.vaultId),
            eq(schema.syncedProject.projectId, operation.entityId),
            ownerAccess(schema.syncedProject.vaultId),
          ));
        } else if (operation.action === "delete") {
          await assertRevision(transaction, "project", operation.entityId, operation.baseRevision);
          await assertProjectDeletionAvailable(transaction.vaultId, operation.entityId, operation.id);
          await db.delete(schema.syncedProject).where(and(
            eq(schema.syncedProject.vaultId, transaction.vaultId),
            eq(schema.syncedProject.projectId, operation.entityId),
            ownerAccess(schema.syncedProject.vaultId),
          ));
          cursor = await appendChange(transaction, "project", operation.entityId, "delete", null);
          records.push({ entity: "project", id: operation.entityId, revision: null, record: null });
          continue;
        }
      } else if (operation.entity === "meeting") {
        if (operation.action === "create") {
          const [existing] = await db.select({ active: schema.syncedMeeting.active })
            .from(schema.syncedMeeting).where(ownedMeeting(transaction.vaultId, operation.entityId)).limit(1);
          const projectId = data.projectId as string | null;
          await assertProjectReference(transaction.vaultId, projectId, operation.id);
          const values = {
            meetingId: operation.entityId,
            vaultId: transaction.vaultId,
            projectId,
            name: String(data.name),
            description: stringField(data, "description"),
            status: String(data.status),
            duration: data.duration as number | null,
            recordingStartedAt: data.recordingStartedAt as Date | null,
            createdAt: data.createdAt as Date,
            updatedAt: data.updatedAt as Date,
            revision: 1,
            active: true,
          };
          if (existing) {
            await db.update(schema.syncedMeeting).set(values).where(ownedMeeting(transaction.vaultId, operation.entityId));
          } else {
            await db.insert(schema.syncedMeeting).values(values);
          }
        } else if (operation.action === "update") {
          const projectId = data.projectId as string | null;
          await assertRevision(transaction, "meeting", operation.entityId, operation.baseRevision,
            projectId ? [{ entity: "project", id: projectId }] : []);
          await assertProjectReference(transaction.vaultId, projectId, operation.id);
          await db.update(schema.syncedMeeting).set({
            projectId,
            name: String(data.name),
            description: stringField(data, "description"),
            status: String(data.status),
            duration: data.duration as number | null,
            recordingStartedAt: data.recordingStartedAt as Date | null,
            updatedAt: data.updatedAt as Date,
            revision: sql`${schema.syncedMeeting.revision} + 1`,
          }).where(ownedMeeting(transaction.vaultId, operation.entityId));
        } else if (operation.action === "delete") {
          await assertRevision(transaction, "meeting", operation.entityId, operation.baseRevision);
          const attachments = await db.select({ id: schema.meetingFile.id }).from(schema.meetingFile).where(and(
            eq(schema.meetingFile.vaultId, transaction.vaultId), eq(schema.meetingFile.meetingId, operation.entityId),
          ));
          await db.delete(schema.syncedMeeting).where(ownedMeeting(transaction.vaultId, operation.entityId));
          // A coalesced delete/recreate must still invalidate the old canonical children.
          cursor = await appendChanges(transaction, [
            { entity: "summary", entityId: operation.entityId, action: "delete", revision: null },
            { entity: "transcript", entityId: operation.entityId, action: "delete", revision: null },
            ...attachments.map(({ id: entityId }) => ({ entity: "meeting_file" as const, entityId, action: "delete" as const, revision: null })),
            { entity: "meeting", entityId: operation.entityId, action: "delete", revision: null },
          ]);
          records.push({ entity: "meeting", id: operation.entityId, revision: null, record: null });
          continue;
        }
      } else if (operation.entity === "summary") {
        await assertRevision(transaction, "summary", operation.entityId, operation.baseRevision);
        await db.update(schema.syncedMeeting).set(operation.action === "delete" ? {
          summaryTitle: null,
          summaryDocument: null,
          summaryCreatedAt: null,
          summaryRevision: sql`${schema.syncedMeeting.summaryRevision} + 1`,
        } : {
          summaryTitle: String(data.title),
          summaryDocument: String(data.document),
          summaryCreatedAt: data.createdAt as Date,
          summaryRevision: sql`${schema.syncedMeeting.summaryRevision} + 1`,
        }).where(ownedMeeting(transaction.vaultId, operation.entityId));
      } else if (operation.entity === "transcript") {
        await assertRevision(transaction, "transcript", operation.entityId, operation.baseRevision);
        const patchId = String(data.patchId);
        if (patchId !== operation.id) {
          throw new SyncTransactionError(422, "transcript_patch_id_mismatch", [], operation.id);
        }
        const expectedChunks = data.chunks as Array<{
          index: number;
          sha256: string;
          segmentCount: number;
          deletionCount: number;
        }>;
        const storedChunks = await db.select().from(schema.transcriptPatchChunk).where(and(
          eq(schema.transcriptPatchChunk.vaultId, transaction.vaultId),
          eq(schema.transcriptPatchChunk.meetingId, operation.entityId),
          eq(schema.transcriptPatchChunk.patchId, patchId),
        )).orderBy(asc(schema.transcriptPatchChunk.chunkIndex));
        if (storedChunks.length !== expectedChunks.length) {
          throw new SyncTransactionError(422, "transcript_patch_incomplete", [], operation.id);
        }
        const segments: SyncTranscriptSegment[] = [];
        const deletions: string[] = [];
        for (const [index, chunk] of storedChunks.entries()) {
          const expected = expectedChunks[index];
          if (!expected || chunk.chunkIndex !== expected.index || chunk.contentHash !== expected.sha256) {
            throw new SyncTransactionError(422, "transcript_patch_hash_mismatch", [], operation.id);
          }
          const payload = (typeof chunk.payload === "string" ? JSON.parse(chunk.payload) : chunk.payload) as {
            segments: Array<Omit<SyncTranscriptSegment, "startTime" | "endTime"> & {
              startTime: Date | string;
              endTime: Date | string | null;
            }>;
            deletions: string[];
          };
          if (payload.segments.length !== expected.segmentCount || payload.deletions.length !== expected.deletionCount) {
            throw new SyncTransactionError(422, "transcript_patch_count_mismatch", [], operation.id);
          }
          segments.push(...payload.segments.map((segment) => ({
            ...segment,
            startTime: new Date(segment.startTime),
            endTime: segment.endTime ? new Date(segment.endTime) : null,
          })));
          deletions.push(...payload.deletions);
        }
        if (segments.length !== data.segmentCount || deletions.length !== data.deletionCount
          || new Set([...segments.map(({ segmentId }) => segmentId), ...deletions]).size !== segments.length + deletions.length) {
          throw new SyncTransactionError(422, "invalid_transcript_patch", [], operation.id);
        }
        for (const batch of batches(deletions, 500)) {
          await db.delete(schema.syncedTranscriptSegment).where(and(
            eq(schema.syncedTranscriptSegment.vaultId, transaction.vaultId),
            eq(schema.syncedTranscriptSegment.meetingId, operation.entityId),
            inArray(schema.syncedTranscriptSegment.segmentId, batch),
          ));
        }
        for (const batch of batches(segments, 250)) {
          await db.insert(schema.syncedTranscriptSegment).values(batch.map((segment) => ({
            ...segment,
            vaultId: transaction.vaultId,
            meetingId: operation.entityId,
          }))).onConflictDoUpdate({
            target: [
              schema.syncedTranscriptSegment.vaultId,
              schema.syncedTranscriptSegment.meetingId,
              schema.syncedTranscriptSegment.segmentId,
            ],
            set: {
              startTime: sql`excluded.start_time`,
              endTime: sql`excluded.end_time`,
              text: sql`excluded.text`,
              isConfirmed: sql`excluded.is_confirmed`,
              audioSource: sql`excluded.audio_source`,
              speakerLabel: sql`excluded.speaker_label`,
            },
          });
        }
        await db.update(schema.syncedMeeting).set({
          transcriptRevision: sql`${schema.syncedMeeting.transcriptRevision} + 1`,
        }).where(ownedMeeting(transaction.vaultId, operation.entityId));
        await db.delete(schema.transcriptPatchChunk).where(and(
          eq(schema.transcriptPatchChunk.vaultId, transaction.vaultId),
          eq(schema.transcriptPatchChunk.meetingId, operation.entityId),
          eq(schema.transcriptPatchChunk.patchId, patchId),
        ));
      } else if (operation.entity === "file") {
        const [file] = await db.select().from(schema.syncedFile).where(and(
          eq(schema.syncedFile.fileId, operation.entityId), eq(schema.syncedFile.vaultId, transaction.vaultId),
          ownerAccess(schema.syncedFile.vaultId),
        )).limit(1);
        if (!file && operation.baseRevision !== null) await assertRevision(transaction, "file", operation.entityId, operation.baseRevision);
        if (!file) throw new SyncTransactionError(422, "file_content_missing", [], operation.id);
        if (file.active || operation.baseRevision !== null) {
          await assertRevision(transaction, "file", operation.entityId, operation.baseRevision);
        }
        if (operation.action === "delete") {
          const [reference] = await db.select({ id: schema.meetingFile.id }).from(schema.meetingFile)
            .where(eq(schema.meetingFile.fileId, file.fileId)).limit(1);
          if (reference) throw new SyncTransactionError(409, "file_in_use", [], operation.id);
          await db.insert(schema.storageDeleteJob).values({ storageKey: fileStorageKey(file.fileId) }).onConflictDoNothing();
          await db.delete(schema.syncedFile).where(eq(schema.syncedFile.fileId, file.fileId));
          cursor = await appendChange(transaction, "file", operation.entityId, "delete", null);
          records.push({ entity: "file", id: operation.entityId, revision: null, record: null });
          continue;
        }
        const [pendingDelete] = await db.select({ key: schema.storageDeleteJob.storageKey }).from(schema.storageDeleteJob)
          .where(eq(schema.storageDeleteJob.storageKey, fileStorageKey(file.fileId))).limit(1);
        if (pendingDelete) throw new SyncTransactionError(503, "file_storage_delete_pending", [], operation.id);
        if (!file.uploadedAt || data.checksum !== file.checksum) {
          throw new SyncTransactionError(422, "file_content_missing", [], operation.id);
        }
        const metadata = { ...file.metadata, ...data.metadata as Partial<FileMetadata> };
        if (metadata.source !== file.metadata.source) throw new SyncTransactionError(409, "file_source_immutable", [], operation.id);
        await db.update(schema.syncedFile).set({ active: true, metadata,
          name: typeof data.name === "string" ? data.name : file.name,
          revision: file.revision + 1, updatedAt: now,
        }).where(eq(schema.syncedFile.fileId, file.fileId));
      } else if (operation.entity === "meeting_file") {
        const previous = await canonicalRecord("meeting_file", transaction.vaultId, operation.entityId);
        if (previous.record !== null || operation.baseRevision !== null || operation.action === "delete") {
          await assertRevision(transaction, "meeting_file", operation.entityId, operation.baseRevision,
            operation.action === "delete" ? [] : [{ entity: "meeting", id: String(data.meetingId) }]);
        }
        if (operation.action === "delete") {
          await db.delete(schema.meetingFile).where(and(eq(schema.meetingFile.id, operation.entityId),
            eq(schema.meetingFile.vaultId, transaction.vaultId)));
          await db.delete(schema.searchIndexJob).where(and(eq(schema.searchIndexJob.vaultId, transaction.vaultId), eq(schema.searchIndexJob.documentId, operation.entityId)));
          await db.delete(schema.searchDocument).where(and(eq(schema.searchDocument.vaultId, transaction.vaultId), eq(schema.searchDocument.documentId, operation.entityId)));
          cursor = await appendChange(transaction, "meeting_file", operation.entityId, "delete", null);
          records.push({ entity: "meeting_file", id: operation.entityId, revision: null, record: null });
          continue;
        }
        const meetingId = String(data.meetingId);
        const fileId = String(data.fileId);
        const meeting = await canonicalRecord("meeting", transaction.vaultId, meetingId);
        if (!meeting.record || meeting.record.deletingAt || meeting.record.active === false) {
          throw new SyncTransactionError(409, "revision_conflict", [{
            entity: "meeting", id: meetingId, clientBaseRevision: null, serverRevision: null, record: null,
          }], operation.id);
        }
        if (previous.record && (previous.record.meetingId !== meetingId || previous.record.fileId !== fileId)) {
          throw new SyncTransactionError(409, "meeting_file_identity_immutable", [], operation.id);
        }
        const [file] = await db.select().from(schema.syncedFile).where(and(
          eq(schema.syncedFile.fileId, fileId), eq(schema.syncedFile.vaultId, transaction.vaultId), eq(schema.syncedFile.active, true),
        )).limit(1);
        if (!file) throw new SyncTransactionError(422, "file_not_found", [], operation.id);
        const values = { capturedAt: data.capturedAt as Date | null, sessionId: data.sessionId as string | null,
          revision: (previous.revision ?? 0) + 1 };
        if (previous.record) {
          await db.update(schema.meetingFile).set(values).where(and(eq(schema.meetingFile.id, operation.entityId),
            eq(schema.meetingFile.vaultId, transaction.vaultId)));
        } else {
          const [inserted] = await db.insert(schema.meetingFile).values({ ...values, id: operation.entityId,
            vaultId: transaction.vaultId, meetingId, fileId, createdAt: data.createdAt as Date,
          }).onConflictDoNothing().returning({ id: schema.meetingFile.id });
          if (!inserted) throw new SyncTransactionError(409, "meeting_file_id_conflict", [], operation.id);
        }
      }

      if (["meeting", "summary"].includes(operation.entity) && typeof data.searchText === "string") {
        const [current] = await db.select({ hash: schema.searchDocument.embeddingContentHash })
          .from(schema.searchDocument).where(and(
            eq(schema.searchDocument.vaultId, transaction.vaultId),
            eq(schema.searchDocument.documentId, operation.entityId),
          )).limit(1);
        await updateSearchDocuments([{
          documentId: operation.entityId,
          vaultId: transaction.vaultId,
          meetingId: operation.entityId,
          kind: "meeting",
          searchText: data.searchText,
          embeddingText: data.embeddingText as string | null,
          embeddingContentHash: data.embeddingContentHash as string | null,
          currentEmbeddingContentHash: current?.hash ?? null,
        }]);
      }
      if (operation.entity === "file" || operation.entity === "meeting_file") {
        const images = await db.select().from(schema.syncedScreenshot).where(and(
          eq(schema.syncedScreenshot.vaultId, transaction.vaultId),
          operation.entity === "file" ? eq(schema.syncedScreenshot.fileId, operation.entityId) : eq(schema.syncedScreenshot.screenshotId, operation.entityId),
        ));
        for (const image of images) {
          const [current] = await db.select({ hash: schema.searchDocument.embeddingContentHash }).from(schema.searchDocument)
            .where(and(eq(schema.searchDocument.vaultId, transaction.vaultId), eq(schema.searchDocument.documentId, image.screenshotId))).limit(1);
          await updateSearchDocuments([{
            documentId: image.screenshotId, vaultId: transaction.vaultId, meetingId: image.meetingId, kind: "screenshot",
            searchText: typeof data.searchText === "string" ? data.searchText : "", embeddingText: data.embeddingText as string | null ?? null,
            embeddingContentHash: data.embeddingContentHash as string | null ?? null, currentEmbeddingContentHash: current?.hash ?? null,
          }]);
        }
      }

      const record = await canonicalRecord(operation.entity, transaction.vaultId, operation.entityId);
      records.push(record);
      cursor = await appendChange(transaction, operation.entity, operation.entityId, "upsert", record.revision);
    }

    const response: SyncTransactionResponse = {
      id: transaction.id,
      status: "committed",
      cursor: encodeSyncCursor(cursor),
      records,
    };
    await db.insert(schema.syncTransactionReceipt).values({
      transactionId: transaction.id,
      ownerUserId: userPrincipalId,
      vaultId: transaction.vaultId,
      requestHash: transaction.requestHash,
      responseJson: searchBackend === "sqlite" ? JSON.stringify(response) : response,
      resultsJson: searchBackend === "sqlite"
        ? JSON.stringify(records.map(({ entity, id, revision }) => ({ entity, id, revision })))
        : records.map(({ entity, id, revision }) => ({ entity, id, revision })),
      cursor,
    });
    return searchBackend === "sqlite"
      ? JSON.parse(JSON.stringify(response)) as SyncTransactionResponse
      : response;
  }

  async function listChanges(
    vaultId: string,
    after: number,
    through: number,
    limit: number,
  ): Promise<SyncChangeRecord[]> {
    await lockVault(vaultId);
    await assertCursorAvailable(vaultId, after);
    const [vault] = await db.select({ ownerUserId: schema.syncedVaultPermission.principalId })
      .from(schema.syncedVault)
      .innerJoin(schema.syncedVaultPermission, and(
        eq(schema.syncedVaultPermission.vaultId, schema.syncedVault.vaultId),
        eq(schema.syncedVaultPermission.principalType, "user"),
        eq(schema.syncedVaultPermission.role, "owner"),
      ))
      .where(and(readable(schema.syncedVault.vaultId), eq(schema.syncedVault.vaultId, vaultId))).limit(1);
    const ledgerOwnerUserId = vault?.ownerUserId ?? userPrincipalId;
    const [latestReset] = await db.select({
      sequence: schema.syncChange.sequence,
      revision: schema.syncChange.revision,
      transactionId: schema.syncChange.transactionId,
    })
      .from(schema.syncChange).where(and(
        eq(schema.syncChange.vaultId, vaultId),
        eq(schema.syncChange.ownerUserId, ledgerOwnerUserId),
        eq(schema.syncChange.action, "reset"),
        gt(schema.syncChange.sequence, after),
        lte(schema.syncChange.sequence, through),
      )).orderBy(desc(schema.syncChange.sequence)).limit(1);
    if (!vault && !latestReset) throw new SyncTransactionError(404, "vault_not_found");
    const effectiveAfter = Number(latestReset?.sequence ?? after);
    const latestChanges = db.select({
      entity: schema.syncChange.entity,
      entityId: schema.syncChange.entityId,
      sequence: sql<number>`max(${schema.syncChange.sequence})`.as("sequence"),
    }).from(schema.syncChange).where(and(
      eq(schema.syncChange.vaultId, vaultId),
      eq(schema.syncChange.ownerUserId, ledgerOwnerUserId),
      gt(schema.syncChange.sequence, effectiveAfter),
      lte(schema.syncChange.sequence, through),
    )).groupBy(schema.syncChange.entity, schema.syncChange.entityId).as("latest_changes");
    const rowLimit = Math.max(0, limit - (latestReset ? 1 : 0));
    const rows = rowLimit === 0 ? [] : await db.select({
      sequence: schema.syncChange.sequence,
      ownerUserId: schema.syncChange.ownerUserId,
      vaultId: schema.syncChange.vaultId,
      entity: schema.syncChange.entity,
      entityId: schema.syncChange.entityId,
      action: schema.syncChange.action,
      revision: schema.syncChange.revision,
      transactionId: schema.syncChange.transactionId,
      createdAt: schema.syncChange.createdAt,
    }).from(schema.syncChange).innerJoin(latestChanges, and(
      eq(schema.syncChange.entity, latestChanges.entity),
      eq(schema.syncChange.entityId, latestChanges.entityId),
      eq(schema.syncChange.sequence, latestChanges.sequence),
    )).orderBy(asc(schema.syncChange.sequence)).limit(rowLimit);
    const changes: SyncChangeRecord[] = [];
    const canonicalRecords = new Map<string, SyncCanonicalRecord>();
    if (latestReset) {
      const [recreated] = vault ? await db.select({ sequence: schema.syncChange.sequence })
        .from(schema.syncChange).where(and(
          eq(schema.syncChange.vaultId, vaultId),
          eq(schema.syncChange.ownerUserId, ledgerOwnerUserId),
          eq(schema.syncChange.entity, "vault"),
          eq(schema.syncChange.action, "upsert"),
          gt(schema.syncChange.sequence, latestReset.sequence),
          lte(schema.syncChange.sequence, through),
        )).limit(1) : [];
      const canonical = recreated
        ? await canonicalRecord("vault", vaultId, vaultId, "read")
        : null;
      changes.push({
        sequence: latestReset.sequence,
        vaultId,
        entity: "vault",
        entityId: vaultId,
        action: "reset",
        revision: canonical?.revision ?? latestReset.revision,
        transactionId: latestReset.transactionId,
        record: canonical?.record ?? null,
      });
    }
    for (const row of rows) {
      let canonical: SyncCanonicalRecord | null = null;
      if (row.action !== "reset") {
        const key = `${row.entity}:${row.entityId}`;
        canonical = canonicalRecords.get(key)
          ?? await canonicalRecord(row.entity as SyncCanonicalRecord["entity"], vaultId, row.entityId, "read");
        canonicalRecords.set(key, canonical);
      }
      changes.push({
        sequence: row.sequence,
        vaultId,
        entity: row.entity as SyncCanonicalRecord["entity"],
        entityId: row.entityId,
        action: row.action === "reset" ? "reset" : canonical?.record ? "upsert" : "delete",
        revision: canonical?.revision ?? row.revision,
        transactionId: row.transactionId,
        record: canonical?.record ?? null,
      });
    }
    return changes;
  }

  async function latestChangeSequence(vaultId?: string): Promise<number> {
    const [row] = await db.select({ sequence: sql<number>`coalesce(max(${schema.syncVaultState.latestSequence}), 0)` })
      .from(schema.syncVaultState).where(and(
        or(
          eq(schema.syncVaultState.ownerUserId, userPrincipalId),
          readable(schema.syncVaultState.vaultId),
        ),
        ...(vaultId ? [eq(schema.syncVaultState.vaultId, vaultId)] : []),
      ));
    return Number(row?.sequence ?? 0);
  }

  async function assertCursorAvailable(vaultId: string, after: number): Promise<void> {
    const [state] = await db.select({ through: sql<number>`max(${schema.syncVaultState.prunedThrough})` })
      .from(schema.syncVaultState).where(and(
        eq(schema.syncVaultState.vaultId, vaultId),
        or(eq(schema.syncVaultState.ownerUserId, userPrincipalId), readable(schema.syncVaultState.vaultId)),
      ));
    if (after < Number(state?.through ?? 0)) throw new SyncTransactionError(410, "sync_cursor_expired");
  }

  async function listSnapshot(
    vaultId: string,
    after: SyncSnapshotPosition | undefined,
    limit: number,
  ): Promise<{ items: SyncCanonicalRecord[]; hasMore: boolean }> {
    const vault = await canonicalRecord("vault", vaultId, vaultId, "read");
    if (!vault.record || vault.record.deletingAt) throw new SyncTransactionError(404, "vault_not_found");
    const records: SyncCanonicalRecord[] = [];
    let bytes = 0;
    const append = (record: SyncCanonicalRecord) => {
      const size = new TextEncoder().encode(JSON.stringify(record)).byteLength + 1;
      // A single record must make progress even if it exceeds the page budget.
      if (records.length > 0 && (records.length >= limit || bytes + size > SYNC_SNAPSHOT_PAGE_BYTES)) return false;
      records.push(record);
      bytes += size;
      return true;
    };
    for (const entity of SYNC_SNAPSHOT_ENTITIES.slice(after ? SYNC_SNAPSHOT_ENTITIES.indexOf(after.entity) : 0)) {
      const afterId = after?.entity === entity ? after.id : undefined;
      const remaining = limit - records.length;
      if (entity === "vault") {
        if (!afterId || vaultId > afterId) append(vault);
        continue;
      }
      const source = entity === "project"
        ? { table: schema.syncedProject, id: schema.syncedProject.projectId, active: undefined }
        : entity === "file" ? { table: schema.syncedFile, id: schema.syncedFile.fileId, active: eq(schema.syncedFile.active, true) }
        : entity === "meeting_file" ? { table: schema.meetingFile, id: schema.meetingFile.id, active: undefined }
          : { table: schema.syncedMeeting, id: schema.syncedMeeting.meetingId, active: and(
              eq(schema.syncedMeeting.active, true), isNull(schema.syncedMeeting.deletingAt),
              entity === "summary" ? isNotNull(schema.syncedMeeting.summaryDocument) : undefined,
              entity === "transcript" ? gt(schema.syncedMeeting.transcriptRevision, 0) : undefined,
            ) };
      const rows = await db.select({ id: source.id }).from(source.table).where(and(
        eq(source.table.vaultId, vaultId), readable(source.table.vaultId), source.active,
        afterId ? gt(source.id, afterId) : undefined,
      )).orderBy(asc(source.id)).limit(remaining + 1);
      for (const row of rows) {
        if (records.length >= limit || !append(await canonicalRecord(entity, vaultId, row.id, "read"))) {
          return { items: records, hasMore: true };
        }
      }
    }
    return { items: records, hasMore: false };
  }

  return {
    lockVault,
    commitTransaction,
    resolveTransaction,
    assertCursorAvailable,
    listSnapshot,
    listChanges,
    latestChangeSequence,
    ensureUploadTarget,
    async putTranscriptChunk(vaultId, meetingId, patchId, chunkIndex, contentHash, segments, deletions) {
      if (!await ensureUploadTarget(vaultId, meetingId)) return false;
      await db.delete(schema.transcriptPatchChunk).where(and(
        eq(schema.transcriptPatchChunk.vaultId, vaultId),
        lt(schema.transcriptPatchChunk.createdAt, new Date(Date.now() - TRANSCRIPT_PATCH_RETENTION_MS)),
      ));
      const payload = { segments, deletions };
      await db.insert(schema.transcriptPatchChunk).values({
        vaultId,
        meetingId,
        patchId,
        chunkIndex,
        contentHash,
        payload: searchBackend === "sqlite" ? JSON.stringify(payload) : payload,
      }).onConflictDoNothing();
      const [stored] = await db.select({ hash: schema.transcriptPatchChunk.contentHash })
        .from(schema.transcriptPatchChunk).where(and(
          eq(schema.transcriptPatchChunk.vaultId, vaultId),
          eq(schema.transcriptPatchChunk.meetingId, meetingId),
          eq(schema.transcriptPatchChunk.patchId, patchId),
          eq(schema.transcriptPatchChunk.chunkIndex, chunkIndex),
        )).limit(1);
      return stored?.hash === contentHash;
    },
    async deleteTranscriptPatch(vaultId, meetingId, patchId) {
      await db.delete(schema.transcriptPatchChunk).where(and(
        eq(schema.transcriptPatchChunk.vaultId, vaultId),
        eq(schema.transcriptPatchChunk.meetingId, meetingId),
        eq(schema.transcriptPatchChunk.patchId, patchId),
      ));
    },
    async getScreenshot(vaultId, meetingId, screenshotId, activeOnly = false) {
      const [row] = await db.select().from(schema.syncedScreenshot).where(and(
        readable(schema.syncedScreenshot.vaultId),
        eq(schema.syncedScreenshot.vaultId, vaultId),
        eq(schema.syncedScreenshot.meetingId, meetingId),
        eq(schema.syncedScreenshot.screenshotId, screenshotId),
        ...(activeOnly ? [eq(schema.syncedScreenshot.active, true)] : []),
      )).limit(1);
      return (row as SyncScreenshotRecord | undefined) ?? null;
    },
    async getFile(fileId, activeOnly = false) {
      const [file] = await db.select().from(schema.syncedFile).where(and(
        eq(schema.syncedFile.fileId, fileId), readable(schema.syncedFile.vaultId),
        activeOnly ? eq(schema.syncedFile.active, true) : ownerAccess(schema.syncedFile.vaultId),
      )).limit(1);
      return file ?? null;
    },
    async reserveFile(input) {
      const [vault] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
        .where(ownedVault(input.vaultId)).limit(1);
      if (!vault) return null;
      await db.insert(schema.syncedFile).values(input).onConflictDoNothing();
      const [file] = await db.select().from(schema.syncedFile).where(and(
        eq(schema.syncedFile.fileId, input.fileId), eq(schema.syncedFile.vaultId, input.vaultId), ownerAccess(schema.syncedFile.vaultId),
      )).limit(1);
      return file ?? null;
    },
    async markFileUploaded(fileId, checksum) {
      const [file] = await db.update(schema.syncedFile).set({ uploadedAt: new Date(), updatedAt: new Date() })
        .where(and(eq(schema.syncedFile.fileId, fileId), eq(schema.syncedFile.checksum, checksum), ownerAccess(schema.syncedFile.vaultId),
          notExists(db.select({ key: schema.storageDeleteJob.storageKey }).from(schema.storageDeleteJob)
            .where(eq(schema.storageDeleteJob.storageKey, fileStorageKey(fileId))))))
        .returning({ id: schema.syncedFile.fileId });
      return file !== undefined;
    },
    async expireFileUploads(vaultId, before) {
      const files = await db.select({ id: schema.syncedFile.fileId }).from(schema.syncedFile).where(and(
        eq(schema.syncedFile.vaultId, vaultId), eq(schema.syncedFile.active, false), lt(schema.syncedFile.updatedAt, before), ownerAccess(schema.syncedFile.vaultId),
      )).limit(25);
      for (const file of files) {
        const deleted = await db.delete(schema.syncedFile).where(and(
          eq(schema.syncedFile.fileId, file.id), eq(schema.syncedFile.active, false), lt(schema.syncedFile.updatedAt, before),
        )).returning({ id: schema.syncedFile.fileId });
        if (deleted.length) await db.insert(schema.storageDeleteJob).values({ storageKey: fileStorageKey(file.id) }).onConflictDoNothing();
      }
    },
    async listFiles(vaultId, after, limit) {
      return db.select().from(schema.syncedFile).where(and(
        eq(schema.syncedFile.vaultId, vaultId), readable(schema.syncedFile.vaultId), eq(schema.syncedFile.active, true),
        after ? gt(schema.syncedFile.fileId, after) : undefined,
      )).orderBy(asc(schema.syncedFile.fileId)).limit(limit);
    },
    async listMeetingFiles(vaultId, meetingId, after, limit) {
      const rows = await db.select({ link: schema.meetingFile, file: schema.syncedFile }).from(schema.meetingFile)
        .innerJoin(schema.syncedFile, eq(schema.syncedFile.fileId, schema.meetingFile.fileId)).where(and(
          eq(schema.meetingFile.vaultId, vaultId), eq(schema.meetingFile.meetingId, meetingId), readable(schema.meetingFile.vaultId),
          eq(schema.syncedFile.active, true), after ? gt(schema.meetingFile.id, after) : undefined,
        )).orderBy(asc(schema.meetingFile.id)).limit(limit);
      return rows.map(({ link, file }) => ({ ...link, file }));
    },
    async listOrganizations() {
      if (!sharingEnabled) return [];
      return db.select({
        id: schema.organization.id, name: schema.organization.name, slug: schema.organization.slug,
      }).from(schema.organization).where(exists(
        db.select({ value: sql`1` }).from(schema.member).where(and(
          eq(schema.member.organizationId, schema.organization.id),
          eq(schema.member.userId, userPrincipalId),
        )),
      )).orderBy(asc(schema.organization.name), asc(schema.organization.id));
    },
    async listVaults(organizationId) {
      const membership = organizationId ? and(
        eq(schema.member.userId, userPrincipalId),
        eq(schema.member.organizationId, organizationId),
      ) : undefined;
      if (organizationId) {
        const [member] = await db.select({ id: schema.member.id }).from(schema.member).where(membership).limit(1);
        if (!sharingEnabled || !member) throw new SyncTransactionError(403, "organization_forbidden");
      }
      const scope = organizationId
        ? exists(db.select({ value: sql`1` }).from(schema.syncedVaultPermission).where(and(
            eq(schema.syncedVaultPermission.vaultId, schema.syncedVault.vaultId),
            eq(schema.syncedVaultPermission.role, "member"),
            or(
              and(eq(schema.syncedVaultPermission.principalType, "organization"),
                eq(schema.syncedVaultPermission.principalId, organizationId)),
              and(eq(schema.syncedVaultPermission.principalType, "team"),
                exists(db.select({ value: sql`1` }).from(schema.team)
                  .innerJoin(schema.teamMember, eq(schema.teamMember.teamId, schema.team.id)).where(and(
                    eq(schema.team.id, schema.syncedVaultPermission.principalId),
                    eq(schema.team.organizationId, organizationId),
                    eq(schema.teamMember.userId, userPrincipalId),
                  )))),
            ),
          )))
        : ownerAccess(schema.syncedVault.vaultId);
      const rows = await db.select({
        vaultId: schema.syncedVault.vaultId,
        name: schema.syncedVault.name,
        revision: schema.syncedVault.revision,
        createdAt: schema.syncedVault.createdAt,
        updatedAt: schema.syncedVault.updatedAt,
        role: vaultRole(schema.syncedVault.vaultId),
      }).from(schema.syncedVault).where(and(
        readable(schema.syncedVault.vaultId),
        scope,
        organizationId ? exists(db.select({ value: sql`1` }).from(schema.member).where(membership)) : undefined,
        isNull(schema.syncedVault.deletingAt),
      )).orderBy(desc(schema.syncedVault.updatedAt));
      return rows;
    },
    async getVault(vaultId) {
      const [row] = await db.select({
        vaultId: schema.syncedVault.vaultId,
        name: schema.syncedVault.name,
        revision: schema.syncedVault.revision,
        createdAt: schema.syncedVault.createdAt,
        updatedAt: schema.syncedVault.updatedAt,
        role: vaultRole(schema.syncedVault.vaultId),
      }).from(schema.syncedVault).where(and(
        readable(schema.syncedVault.vaultId),
        eq(schema.syncedVault.vaultId, vaultId),
        isNull(schema.syncedVault.deletingAt),
      )).limit(1);
      return row ?? null;
    },
    async listProjects(vaultId) {
      return projectViews(vaultId);
    },
    async getProject(vaultId, projectId) {
      return (await projectViews(vaultId)).find((project) => project.projectId === projectId) ?? null;
    },
    async listMeetings(vaultId, query, limit, projectId, cursor, projectScope) {
      if (query && query.tokens.length === 0) return [];
      const projectIds = projectId
        ? (await projectViews(vaultId)).filter((project) =>
            project.projectId === projectId || (projectScope !== "direct" && project.parentProjectId === projectId)).map((project) => project.projectId)
        : undefined;
      if (projectId && projectIds?.length === 0) return [];
      const filter = and(
        readableMeeting(vaultId),
        ...(projectIds ? [inArray(schema.syncedMeeting.projectId, projectIds)] : []),
        ...(projectScope === "unassigned" ? [isNull(schema.syncedMeeting.projectId)] : []),
        ...(cursor ? [or(
          lt(schema.syncedMeeting.createdAt, cursor.createdAt),
          and(
            eq(schema.syncedMeeting.createdAt, cursor.createdAt),
            lt(schema.syncedMeeting.meetingId, cursor.meetingId),
          ),
        )] : []),
        eq(schema.syncedMeeting.active, true),
        isNull(schema.syncedMeeting.deletingAt),
      );
      if (!query) {
        return db.select(meetingSelection(schema)).from(schema.syncedMeeting)
          .where(filter).orderBy(desc(schema.syncedMeeting.createdAt), desc(schema.syncedMeeting.meetingId))
          .limit(limit);
      }
      const ids = await rankedDocumentIds(vaultId, undefined, "meeting", query);
      if (ids.length === 0) return [];
      const rows = await db.select(meetingSelection(schema)).from(schema.syncedMeeting)
        .where(and(filter, inArray(schema.syncedMeeting.meetingId, ids)))
        .orderBy(desc(schema.syncedMeeting.createdAt), desc(schema.syncedMeeting.meetingId));
      const rank = new Map(ids.map((id, index) => [id, index]));
      return rows.sort((left, right) => rank.get(left.meetingId)! - rank.get(right.meetingId)!).slice(0, limit);
    },
    async getMeeting(vaultId, meetingId) {
      const [row] = await db.select(meetingSelection(schema)).from(schema.syncedMeeting).where(and(
        readableMeeting(vaultId, meetingId),
        eq(schema.syncedMeeting.active, true),
        isNull(schema.syncedMeeting.deletingAt),
      )).limit(1);
      return row ?? null;
    },
    async listTranscript(vaultId, meetingId, limit, cursor) {
      const [meeting] = await db.select({ id: schema.syncedMeeting.meetingId })
        .from(schema.syncedMeeting).where(and(
          readableMeeting(vaultId, meetingId),
          eq(schema.syncedMeeting.active, true),
          isNull(schema.syncedMeeting.deletingAt),
        )).limit(1);
      if (!meeting) return [];
      return db.select({
        segmentId: schema.syncedTranscriptSegment.segmentId,
        startTime: schema.syncedTranscriptSegment.startTime,
        endTime: schema.syncedTranscriptSegment.endTime,
        text: schema.syncedTranscriptSegment.text,
        isConfirmed: schema.syncedTranscriptSegment.isConfirmed,
        audioSource: schema.syncedTranscriptSegment.audioSource,
        speakerLabel: schema.syncedTranscriptSegment.speakerLabel,
      }).from(schema.syncedTranscriptSegment).where(and(
        readable(schema.syncedTranscriptSegment.vaultId),
        eq(schema.syncedTranscriptSegment.vaultId, vaultId),
        eq(schema.syncedTranscriptSegment.meetingId, meetingId),
        ...(cursor ? [or(
          gt(schema.syncedTranscriptSegment.startTime, cursor.startTime),
          and(
            eq(schema.syncedTranscriptSegment.startTime, cursor.startTime),
            gt(schema.syncedTranscriptSegment.segmentId, cursor.segmentId),
          ),
        )] : []),
      )).orderBy(asc(schema.syncedTranscriptSegment.startTime), asc(schema.syncedTranscriptSegment.segmentId))
        .limit(limit);
    },
    async listScreenshots(vaultId, meetingId, query, limit, cursor) {
      if (query && query.tokens.length === 0) return [];
      const [meeting] = await db.select({ id: schema.syncedMeeting.meetingId })
        .from(schema.syncedMeeting).where(and(
          readableMeeting(vaultId, meetingId),
          eq(schema.syncedMeeting.active, true),
          isNull(schema.syncedMeeting.deletingAt),
        )).limit(1);
      if (!meeting) return [];
      const filter = and(
        readable(schema.syncedScreenshot.vaultId),
        eq(schema.syncedScreenshot.vaultId, vaultId),
        eq(schema.syncedScreenshot.meetingId, meetingId),
        eq(schema.syncedScreenshot.active, true),
        ...(cursor ? [or(
          gt(schema.syncedScreenshot.capturedAt, cursor.capturedAt),
          and(
            eq(schema.syncedScreenshot.capturedAt, cursor.capturedAt),
            gt(schema.syncedScreenshot.screenshotId, cursor.screenshotId),
          ),
        )] : []),
      );
      if (!query) {
        return db.select(screenshotSelection(schema)).from(schema.syncedScreenshot).where(filter)
          .orderBy(asc(schema.syncedScreenshot.capturedAt), asc(schema.syncedScreenshot.screenshotId)).limit(limit);
      }
      const ids = await rankedDocumentIds(vaultId, meetingId, "screenshot", query);
      if (ids.length === 0) return [];
      const rows = await db.select(screenshotSelection(schema)).from(schema.syncedScreenshot)
        .where(and(filter, inArray(schema.syncedScreenshot.screenshotId, ids)))
        .orderBy(asc(schema.syncedScreenshot.capturedAt), asc(schema.syncedScreenshot.screenshotId));
      const rank = new Map(ids.map((id, index) => [id, index]));
      return rows.sort((left, right) => rank.get(left.screenshotId)! - rank.get(right.screenshotId)!).slice(0, limit);
    },
    async listPermissions(vaultId) {
      const [vault] = await db.select({ role: vaultRole(schema.syncedVault.vaultId) })
        .from(schema.syncedVault).where(and(
          readable(schema.syncedVault.vaultId),
          eq(schema.syncedVault.vaultId, vaultId),
          isNull(schema.syncedVault.deletingAt),
        )).limit(1);
      if (!vault) return null;
      return db.select({
        vaultId: schema.syncedVaultPermission.vaultId,
        principalType: schema.syncedVaultPermission.principalType,
        principalId: schema.syncedVaultPermission.principalId,
        role: schema.syncedVaultPermission.role,
        createdAt: schema.syncedVaultPermission.createdAt,
      }).from(schema.syncedVaultPermission).where(and(
        eq(schema.syncedVaultPermission.vaultId, vaultId),
        ...(vault.role === "owner" ? [] : [matchingMember()]),
      )) as Promise<import("./types").VaultPermissionRecord[]>;
    },
    async putMemberPermission(vaultId, principalType, principalId) {
      const [vault] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
        .where(and(ownedVault(vaultId), isNull(schema.syncedVault.deletingAt))).limit(1);
      if (!vault) return false;
      if (principalType === "organization") {
        if (identity.source === "header" && principalId !== "external") return false;
        const [membership] = await db.select({ id: schema.member.id }).from(schema.member).where(and(
          eq(schema.member.userId, userPrincipalId),
          eq(schema.member.organizationId, principalId),
        )).limit(1);
        if (!membership) return false;
      } else if (principalType === "team") {
        const [team] = await db.select({ id: schema.team.id }).from(schema.team)
          .innerJoin(schema.member, and(
            eq(schema.member.organizationId, schema.team.organizationId),
            eq(schema.member.userId, userPrincipalId),
          ))
          .where(eq(schema.team.id, principalId)).limit(1);
        if (!team) return false;
      } else {
        return false;
      }
      await db.insert(schema.syncedVaultPermission).values({
        vaultId,
        principalType,
        principalId,
        role: "member",
        grantedByUserId: userPrincipalId,
      }).onConflictDoNothing();
      return true;
    },
    async deleteMemberPermission(vaultId, principalType, principalId) {
      const [vault] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
        .where(ownedVault(vaultId)).limit(1);
      if (!vault || principalType === "user") return false;
      const [deleted] = await db.delete(schema.syncedVaultPermission).where(and(
        eq(schema.syncedVaultPermission.vaultId, vaultId),
        eq(schema.syncedVaultPermission.principalType, principalType),
        eq(schema.syncedVaultPermission.principalId, principalId),
        eq(schema.syncedVaultPermission.role, "member"),
      )).returning({ vaultId: schema.syncedVaultPermission.vaultId });
      return deleted !== undefined;
    },

  };
}

export function encodeSyncCursor(sequence: number): string {
  return `v1.${base64UrlEncode(String(sequence))}`;
}

export function decodeSyncCursor(cursor: string | undefined): number {
  if (!cursor) return 0;
  const [version, value, extra] = cursor.split(".");
  if (version !== "v1" || !value || extra || !/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new SyncTransactionError(400, "invalid_sync_cursor");
  }
  let decoded: string;
  try {
    decoded = base64UrlDecode(value);
  } catch {
    throw new SyncTransactionError(400, "invalid_sync_cursor");
  }
  if (base64UrlEncode(decoded) !== value) throw new SyncTransactionError(400, "invalid_sync_cursor");
  const sequence = Number(decoded);
  if (!Number.isSafeInteger(sequence) || sequence < 0) throw new SyncTransactionError(400, "invalid_sync_cursor");
  return sequence;
}

function stringField(data: Record<string, unknown>, key: string): string {
  const value = data[key];
  if (typeof value !== "string") throw new SyncTransactionError(400, "invalid_sync_operation");
  return value;
}

function base64UrlEncode(value: string): string {
  return btoa(value).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function base64UrlDecode(value: string): string {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  return atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "="));
}

function meetingSelection(schema: SyncSchema) {
  return {
    meetingId: schema.syncedMeeting.meetingId,
    vaultId: schema.syncedMeeting.vaultId,
    projectId: schema.syncedMeeting.projectId,
    name: schema.syncedMeeting.name,
    description: schema.syncedMeeting.description,
    status: schema.syncedMeeting.status,
    duration: schema.syncedMeeting.duration,
    recordingStartedAt: schema.syncedMeeting.recordingStartedAt,
    createdAt: schema.syncedMeeting.createdAt,
    updatedAt: schema.syncedMeeting.updatedAt,
    summaryTitle: schema.syncedMeeting.summaryTitle,
    summaryDocument: schema.syncedMeeting.summaryDocument,
    summaryCreatedAt: schema.syncedMeeting.summaryCreatedAt,
    revision: schema.syncedMeeting.revision,
    summaryRevision: schema.syncedMeeting.summaryRevision,
    transcriptRevision: schema.syncedMeeting.transcriptRevision,
  };
}

function screenshotSelection(schema: SyncSchema) {
  return {
    screenshotId: schema.syncedScreenshot.screenshotId,
    fileId: schema.syncedScreenshot.fileId,
    vaultId: schema.syncedScreenshot.vaultId,
    meetingId: schema.syncedScreenshot.meetingId,
    capturedAt: schema.syncedScreenshot.capturedAt,
    contentType: schema.syncedScreenshot.contentType,
    storageKey: schema.syncedScreenshot.storageKey,
    contentLength: schema.syncedScreenshot.contentLength,
    contentHash: schema.syncedScreenshot.contentHash,
    ocrText: schema.syncedScreenshot.ocrText,
    caption: schema.syncedScreenshot.caption,
    revision: schema.syncedScreenshot.revision,
  };
}

function decodeFloat32(value: unknown): number[] {
  if (!(value instanceof Uint8Array) && !(value instanceof ArrayBuffer)) return [];
  const bytes = value instanceof Uint8Array
    ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
    : new Uint8Array(value);
  if (bytes.byteLength % 4 !== 0) return [];
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return Array.from({ length: bytes.byteLength / 4 }, (_, index) => view.getFloat32(index * 4, true));
}

function cosineSimilarity(left: readonly number[], right: readonly number[]): number {
  if (left.length !== right.length || left.length === 0) return Number.NaN;
  let dot = 0;
  let leftNorm = 0;
  let rightNorm = 0;
  for (let index = 0; index < left.length; index++) {
    dot += left[index]! * right[index]!;
    leftNorm += left[index]! ** 2;
    rightNorm += right[index]! ** 2;
  }
  return leftNorm && rightNorm ? dot / Math.sqrt(leftNorm * rightNorm) : Number.NaN;
}
