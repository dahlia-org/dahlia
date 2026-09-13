import type { CalendarEventSnapshot } from "./schemas";
import { createContentEncryption } from "../encryption/store";
import { readAuthorization, validateAuthorization } from "../auth/authorization";
import { vaultPermissions } from "../auth/vault-permissions";
import { sha256 } from "../storage/sha256";
import { storedTranscriptSettingsSchema } from "../summary/model";
import { uuidV7 } from "../id";
import type { SearchDocumentFields } from "../search/document";
import { DEFAULT_SEARCH_SETTINGS, SEARCH_FIELDS, type SearchSettings } from "../search/settings-model";
import { createSearchSettingsStore } from "../search/settings";
import { transcriptStatus, sameTranscriptModel, type TranscriptVersion } from "./transcript";
import { summaryMetadata, summaryMetadataSchema } from "../summary/metadata";
import { fileResponse, fileStorageKey, imageContentTypes, type FileMetadata } from "../files/model";
import { needsImageAnalysis, type ImageAnalysisClaim, type ImageAnalysisInput } from "../image-analysis/model";
import { recordingCanonical, recordingStorageKey, type RecordingRecord, type RecordingSource, type RecordingManifest } from "../recordings/model";
import { normalizedCharacterCount } from "../conversation-analytics";
import {
  and,
  asc,
  count,
  getTableColumns,
  desc,
  eq,
  exists,
  notExists,
  inArray,
  isNull,
  isNotNull,
  gt,
  gte,
  lt,
  lte,
  max,
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
  VaultTransferRequest,
  VaultTransferRecord,
  VaultRelocations,
  MeetingSyncStore,
  SyncCanonicalRecord,
  SyncChangeRecord,
  SyncProjectView,
  SyncRevisionConflict,
  SyncScreenshotRecord,
  SyncSearchQuery,
  SyncSearchFilters,
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
export const SYNC_SNAPSHOT_ENTITIES = ["vault", "project", "meeting", "summary", "transcript", "file", "meeting_attachment", "recording"] as const;

function batches<T>(values: T[], size: number): T[][] {
  const result: T[][] = [];
  for (let offset = 0; offset < values.length; offset += size) result.push(values.slice(offset, offset + size));
  return result;
}

export function createPostgresMeetingSyncStore(
  db: PostgresDatabase,
  searchBackend: SyncSearchBackend = "postgres",
  embeddingConfig?: AppConfig["searchEmbedding"],
  encryption?: AppConfig["encryption"],
): MeetingSyncStore {
  let available: Promise<boolean> | undefined;
  const isAvailable = () => available ??= roleSupportsRls(db);
  const storageDeletes = createStorageDeleteStore(db, postgresSchema, true);
  return {
    isAvailable,
    ...storageDeletes,
    ...createHistoryMaintenanceStore(db, postgresSchema, true, encryption),
    async withIdentity(identity, action) {
      if (!await isAvailable()) throw new SyncStoreUnavailableError();
      return db.transaction(async (transaction) => {
        await transaction.execute(sql`select set_config('app.user_id', ${identity.userId}, true)`);
        await transaction.execute(sql`select set_config('app.sharing_enabled', 'true', true)`);
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
          encryption,
        ));
      });
    },
  };
}

export function createSqliteMeetingSyncStore(
  db: SQLiteDatabase,
  embeddingConfig?: AppConfig["searchEmbedding"],
  encryption?: AppConfig["encryption"],
): MeetingSyncStore {
  const storageDeletes = createStorageDeleteStore(
    db as unknown as PostgresDatabase,
    sqliteSchema as unknown as SyncSchema,
    false,
  );
  return {
    isAvailable: () => Promise.resolve(true),
    ...storageDeletes,
    ...createHistoryMaintenanceStore(db as unknown as PostgresDatabase, sqliteSchema as unknown as SyncSchema, false, encryption),
    withIdentity: (identity, action) => Promise.resolve(db.transaction(async (transaction) => {
      return action(createIdentityStore(
        transaction as unknown as PostgresDatabase,
        sqliteSchema as unknown as SyncSchema,
        identity,
        "sqlite",
        embeddingConfig,
        encryption,
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
    expireRecordingUploads: () => Promise.reject(new SyncStoreUnavailableError()),
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

async function expireRecordingStaging(db: NodePgDatabase, schema: SyncSchema, isPostgres: boolean, vaultId: string, before: Date) {
      const expired = (source: RecordingSource) => !isPostgres
        ? sql`json_extract(${schema.syncedRecording.audio}, ${`$.${source}.active`}) = 0 AND json_extract(${schema.syncedRecording.audio}, ${`$.${source}.createdAt`}) < ${before.toISOString()}`
        : sql`${schema.syncedRecording.audio}->${source}->>'active' = 'false' AND ${schema.syncedRecording.audio}->${source}->>'createdAt' < ${before.toISOString()}`;
      const records = await db.select({ ...getTableColumns(schema.syncedRecording), vaultId: schema.syncedMeeting.vaultId }).from(schema.syncedRecording)
      .innerJoin(schema.syncedMeeting, eq(schema.syncedMeeting.meetingId, schema.syncedRecording.meetingId)).where(and(
        eq(schema.syncedMeeting.vaultId, vaultId),
        or(expired("mic"), expired("system")),
      )).limit(100);
      for (const record of records) {
        const audio = { ...record.audio };
        for (const source of ["mic", "system"] as const) {
          const value = audio[source];
          if (!value || value.active || new Date(value.createdAt) >= before) continue;
          await db.insert(schema.storageDeleteJob).values({ storageKey: recordingStorageKey(record, source) }).onConflictDoNothing();
          audio[source] = { generation: crypto.randomUUID(), createdAt: new Date().toISOString(), uploadedAt: null,
            active: false, content_type: "audio/mp4", size: 0, checksum: null };
        }
        if (JSON.stringify(audio) !== JSON.stringify(record.audio)) {
          await db.update(schema.syncedRecording).set({ audio }).where(eq(schema.syncedRecording.sessionId, record.sessionId));
        }
      }
}

function createHistoryMaintenanceStore(db: PostgresDatabase, schema: SyncSchema, isPostgres: boolean, encryption?: AppConfig["encryption"]) {
  return {
    async expireRecordingUploads(vaultId: string, before: Date) {
      await db.transaction(async (tx) => {
        if (isPostgres) {
          await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`vault:${vaultId}`}, 0))`);
          await tx.execute(sql`select set_config('app.maintenance', 'storage', true), set_config('app.maintenance_vault_id', ${vaultId}, true)`);
        }
        await expireRecordingStaging(tx, schema, isPostgres, vaultId, before);
      });
    },
    async listHistoryTargets(after?: SyncHistoryTarget): Promise<SyncHistoryTarget[]> {
      return db.select({ vaultId: schema.syncVaultState.vaultId }).from(schema.syncVaultState)
        .where(after ? gt(schema.syncVaultState.vaultId, after.vaultId) : undefined)
        .orderBy(asc(schema.syncVaultState.vaultId)).limit(100);
    },
    async pruneHistoryBatch(target: SyncHistoryTarget) {
      return db.transaction(async (transaction) => {
        if (isPostgres) {
          await transaction.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`vault:${target.vaultId}`}, 0))`);
          await transaction.execute(sql`select set_config('app.maintenance', 'retention', true)`);
        }
        const statePredicate = and(
          eq(schema.syncVaultState.vaultId, target.vaultId),
        );
        const [state] = await transaction.select().from(schema.syncVaultState).where(statePredicate).limit(1);
        if (!state) return { changesDeleted: 0, receiptsCompacted: 0 };
        const cutoff = new Date(Date.now() - SYNC_HISTORY_RETENTION_MS);
        const ledgerPredicate = and(
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
            eq(schema.syncTransactionReceipt.vaultId, target.vaultId),
            lt(schema.syncTransactionReceipt.createdAt, cutoff),
            isNotNull(schema.syncTransactionReceipt.responseJson),
          )).orderBy(asc(schema.syncTransactionReceipt.createdAt), asc(schema.syncTransactionReceipt.transactionId))
          .limit(SYNC_RETENTION_BATCH_SIZE);
        const content = createContentEncryption(transaction, schema, "", encryption, undefined, "retention");
        if (receipts.length && await content.cipher(target.vaultId)) {
          for (const receipt of receipts) {
            await transaction.update(schema.syncTransactionReceipt).set(await content.write(schema.syncTransactionReceipt, { responseJson: null },
              { transactionId: receipt.id, vaultId: target.vaultId }))
              .where(and(eq(schema.syncTransactionReceipt.transactionId, receipt.id)));
          }
        } else {
          // SQLite's parameter limit is lower than the maintenance batch size.
          for (const batch of batches(receipts, 100)) {
            await transaction.update(schema.syncTransactionReceipt).set({ responseJson: null })
              .where(and(
                inArray(schema.syncTransactionReceipt.transactionId, batch.map(({ id }) => id))));
          }
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
      "crypto.vault_keys",
      "app.projects",
      "app.transaction_receipts",
      "app.vault_transfers",
      "app.meetings",
      "app.meeting_events",
      "app.transcripts",
      "app.transcript_segments",
      "app.transcript_patch_chunks",
      "app.files",
      "app.meeting_attachments",
      "app.recordings",
      "search.documents",
      "app.account_settings",
      "jobs.summary",
      "app.summaries",
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
    await client.query("select set_config('app.user_id', '00000000-0000-7000-8000-000000005899', true)");
    await client.query("select set_config('app.sharing_enabled', 'false', true)");
    await client.query("select vault_id from app.vaults limit 1");
    await client.query("commit");
    transaction = false;
    if (!await identityContextIsEmpty(client)) return false;

    await client.query("begin");
    transaction = true;
    await client.query("select set_config('app.user_id', '00000000-0000-7000-8000-000000005899', true)");
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
  encryption?: AppConfig["encryption"],
): IdentitySyncStore {
  const userPrincipalId = identity.userId;
  let searchSettings: Promise<SearchSettings> | undefined;
  const content = createContentEncryption(db, schema, userPrincipalId, encryption, (vault) => readable(vault));
  const { admin: adminAccess, write: writeAccess, read: readable, role: vaultRole, matchingPrincipal } = vaultPermissions(db, schema, userPrincipalId);
  const readableHistory = (vault: AnyColumn) => or(readable(vault), and(
    notExists(db.select({ id: schema.syncedVaultPermission.vaultId }).from(schema.syncedVaultPermission).where(eq(schema.syncedVaultPermission.vaultId, vault))),
    exists(db.select({ id: schema.syncTransactionReceipt.transactionId }).from(schema.syncTransactionReceipt).where(and(eq(schema.syncTransactionReceipt.vaultId, vault), eq(schema.syncTransactionReceipt.ownerUserId, userPrincipalId)))),
  ));
  const adminVault = (vaultId: string) => and(eq(schema.syncedVault.vaultId, vaultId), adminAccess(schema.syncedVault.vaultId));
  const writableVault = (vaultId: string) => and(
    eq(schema.syncedVault.vaultId, vaultId),
    writeAccess(schema.syncedVault.vaultId),
  );
  const writableMeeting = (vaultId: string, meetingId: string) => and(
    eq(schema.syncedMeeting.vaultId, vaultId),
    eq(schema.syncedMeeting.meetingId, meetingId),
    writeAccess(schema.syncedMeeting.vaultId),
  );
  const readableMeeting = (vaultId: string, meetingId?: string) => and(
    readable(schema.syncedMeeting.vaultId),
    eq(schema.syncedMeeting.vaultId, vaultId),
    ...(meetingId ? [eq(schema.syncedMeeting.meetingId, meetingId)] : []),
  );
  function publicVaultColumns() {
    const { createdBy, ...columns } = getTableColumns(schema.syncedVault);
    void createdBy; // Audit snapshot is deliberately excluded from canonical responses.
    return columns;
  }
  const vaultHasResources = (vault: AnyColumn) => or(
    ...[schema.syncedProject, schema.syncedMeeting, schema.syncedFile].map((table) =>
      exists(db.select({ value: sql`1` }).from(table).where(eq(table.vaultId, vault)))),
  )!;



  async function validateSharing() {
    if (searchBackend !== "sqlite") await db.execute(sql`select set_config('app.maintenance', 'authorization', true)`);
    try { validateAuthorization(await readAuthorization(db, schema)); }
    catch (error) {
      const code = (error as { body?: { message?: string } }).body?.message;
      if (code) throw new SyncTransactionError(409, code);
      throw error;
    } finally {
      if (searchBackend !== "sqlite") await db.execute(sql`select set_config('app.maintenance', '', true)`);
    }
  }

  async function lockVault(vaultId: string, checkTransfers = true): Promise<void> {
    if (searchBackend !== "sqlite") {
      // ponytail: serialize authorization-changing transactions; partition this lock if write throughput requires it.
      await db.execute(sql`select pg_advisory_xact_lock(75047176522050)`);
      await db.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`vault:${vaultId}`}, 0))`);
    }
    if (checkTransfers && identity.syncClient && !identity.syncClient.vaultTransfers) {
      const [transfer] = await db.select({ id: schema.vaultTransfer.id }).from(schema.vaultTransfer).where(and(or(
        eq(schema.vaultTransfer.sourceVaultId, vaultId), eq(schema.vaultTransfer.destinationVaultId, vaultId),
      ), or(eq(schema.vaultTransfer.ownerUserId, userPrincipalId), readable(schema.vaultTransfer.sourceVaultId), readable(schema.vaultTransfer.destinationVaultId)))).limit(1);
      if (transfer) throw new SyncTransactionError(426, "vault_transfer_update_required");
    }
  }

  async function vaultTransferAudience(sourceVaultId: string, destinationVaultId: string) {
    for (const id of [sourceVaultId, destinationVaultId].sort()) await lockVault(id, false);
    for (const id of [sourceVaultId, destinationVaultId]) {
      const [vault] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault).where(adminVault(id)).limit(1);
      if (!vault) throw new SyncTransactionError(404, "vault_not_found");
    }
    if (searchBackend !== "sqlite") {
      // ponytail: transfer-wide sharing locks; use scoped permission versions if transfer traffic makes this costly.
      await db.execute(sql`LOCK TABLE ${schema.syncedVaultPermission}, ${schema.member}, ${schema.teamMember} IN SHARE MODE`);
    }
    const readers = async (id: string) => db.select({ id: schema.user.id, name: schema.user.name, email: schema.user.email })
      .from(schema.user).where(exists(db.select({ value: sql`1` }).from(schema.syncedVaultPermission).where(and(
        eq(schema.syncedVaultPermission.vaultId, id), or(
          and(eq(schema.syncedVaultPermission.principalType, "user"), eq(schema.syncedVaultPermission.principalId, schema.user.id)),
          and(eq(schema.syncedVaultPermission.principalType, "organization"), exists(db.select({ value: sql`1` }).from(schema.member).where(and(
            eq(schema.member.organizationId, schema.syncedVaultPermission.principalId), eq(schema.member.userId, schema.user.id))))),
          and(eq(schema.syncedVaultPermission.principalType, "team"), exists(db.select({ value: sql`1` }).from(schema.teamMember).where(and(
            eq(schema.teamMember.teamId, schema.syncedVaultPermission.principalId), eq(schema.teamMember.userId, schema.user.id))))),
        ),
      )))).orderBy(asc(schema.user.name), asc(schema.user.id));
    const source = await readers(sourceVaultId);
    const destination = await readers(destinationVaultId);
    const audienceHash = await sha256(JSON.stringify([sourceVaultId, destinationVaultId,
      source.map((person) => person.id).sort(), destination.map((person) => person.id).sort()]));
    return { audienceHash, removed: source.filter((person) => !destination.some((other) => other.id === person.id)),
      added: destination.filter((person) => !source.some((other) => other.id === person.id)) };
  }

  async function transferVault(request: VaultTransferRequest): Promise<VaultTransferRecord> {
    const { sourceVaultId, destinationVaultId } = request;
    if (sourceVaultId === destinationVaultId) throw new SyncTransactionError(400, "same_vault");
    // Serialize reused keys even when the second request names different Vaults.
    if (searchBackend !== "sqlite") {
      await db.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`transfer:${userPrincipalId}:${request.idempotencyKey}`}, 0))`);
    }
    for (const id of [sourceVaultId, destinationVaultId].sort()) await lockVault(id, false);
    const transfers = schema.vaultTransfer;
    const [previous] = await db.select().from(transfers).where(and(
      eq(transfers.ownerUserId, userPrincipalId), eq(transfers.idempotencyKey, request.idempotencyKey),
    )).limit(1);
    if (previous) {
      if (previous.requestHash !== request.requestHash) throw new SyncTransactionError(409, "idempotency_key_reused");
      return previous;
    }
    const vaults = await content.read(schema.syncedVault, await db.select().from(schema.syncedVault).where(and(
      inArray(schema.syncedVault.vaultId, [sourceVaultId, destinationVaultId]), adminAccess(schema.syncedVault.vaultId),
      isNull(schema.syncedVault.deletingAt),
    )));
    if (vaults.length !== 2) throw new SyncTransactionError(404, "vault_not_found");
    if (vaults.some((vault) => vault.encryption === "server")) throw new SyncTransactionError(409, "encrypted_vault_transfer_unsupported");
    for (const vault of vaults) {
      const expected = vault.vaultId === sourceVaultId ? request.sourceRevision : request.destinationRevision;
      if (vault.revision !== expected) throw new SyncTransactionError(409, "revision_conflict");
    }
    const audience = await vaultTransferAudience(sourceVaultId, destinationVaultId);
    if (audience.audienceHash !== request.audienceHash) throw new SyncTransactionError(409, "transfer_audience_changed");
    const affected = [sourceVaultId, destinationVaultId];
    const [blocked] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault).where(and(
      inArray(schema.syncedVault.vaultId, affected),
      or(
        exists(db.select({ value: sql`1` }).from(schema.syncedFile).where(and(eq(schema.syncedFile.vaultId, schema.syncedVault.vaultId), eq(schema.syncedFile.active, false)))),
        exists(db.select({ value: sql`1` }).from(schema.transcriptPatchChunk).where(eq(schema.transcriptPatchChunk.vaultId, schema.syncedVault.vaultId))),
      ),
    )).limit(1);
    if (blocked) throw new SyncTransactionError(409, "transfer_unsynced_data");
    const recordings = await selectRecordings().where(inArray(schema.syncedMeeting.vaultId, affected));
    if (recordings.some((recording) => Object.values(recording.audio).some((audio) => !audio.active || !audio.uploadedAt))) {
      throw new SyncTransactionError(409, "transfer_unsynced_data");
    }
    const [busy] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault).where(and(
      inArray(schema.syncedVault.vaultId, affected),
      or(
        exists(db.select({ value: sql`1` }).from(schema.syncedMeeting).where(and(eq(schema.syncedMeeting.vaultId, schema.syncedVault.vaultId), or(
          eq(schema.syncedMeeting.active, false), isNotNull(schema.syncedMeeting.deletingAt), eq(schema.syncedMeeting.status, "PROCESSING_TRANSCRIPT"),
        )))),
        exists(db.select({ value: sql`1` }).from(schema.recordingSession).where(and(eq(schema.recordingSession.vaultId, schema.syncedVault.vaultId), isNull(schema.recordingSession.endedAt)))),
        ...[schema.summaryJob, schema.imageAnalysisJob, schema.searchIndexJob].map((table) =>
          exists(db.select({ value: sql`1` }).from(table).where(and(eq(table.vaultId, schema.syncedVault.vaultId), inArray(table.status, ["pending", "processing"]))))),
      ),
    )).limit(1);
    if (busy) throw new SyncTransactionError(409, "transfer_processing");
    const projects = await content.read(schema.syncedProject, await db.select().from(schema.syncedProject).where(inArray(schema.syncedProject.vaultId, affected)));
    const roots = projects.filter((project) => project.parentProjectId === null);
    const nameKey = (value: string) => [...value.normalize("NFC")].map((character) => character === "ı" ? character : character.toUpperCase().toLowerCase()).join("").normalize("NFC");
    if (roots.some((source) => source.vaultId === sourceVaultId && roots.some((destination) =>
      destination.vaultId === destinationVaultId && nameKey(source.name) === nameKey(destination.name)))) {
      throw new SyncTransactionError(409, "transfer_name_conflict");
    }
    const meetings = await db.select({ id: schema.syncedMeeting.meetingId, revision: schema.syncedMeeting.revision,
      summaryRevision: schema.syncedMeeting.summaryRevision, transcriptRevision: schema.syncedMeeting.transcriptRevision,
    }).from(schema.syncedMeeting).where(eq(schema.syncedMeeting.vaultId, sourceVaultId));
    const files = await db.select({ id: schema.syncedFile.fileId, revision: schema.syncedFile.revision }).from(schema.syncedFile).where(eq(schema.syncedFile.vaultId, sourceVaultId));
    const movedChanges: Pick<SyncChangeRecord, "entity" | "entityId" | "action" | "revision">[] = [
      ...projects.filter((project) => project.vaultId === sourceVaultId).map((project) => ({ entity: "project" as const, entityId: project.projectId, action: "upsert" as const, revision: project.revision })),
      ...meetings.flatMap((meeting) => [
        { entity: "meeting" as const, entityId: meeting.id, action: "upsert" as const, revision: meeting.revision },
        { entity: "summary" as const, entityId: meeting.id, action: "upsert" as const, revision: meeting.summaryRevision },
        { entity: "transcript" as const, entityId: meeting.id, action: "upsert" as const, revision: meeting.transcriptRevision },
      ]),
      ...files.map((file) => ({ entity: "file" as const, entityId: file.id, action: "upsert" as const, revision: file.revision })),
    ];
    const meetingAttachments = await db.select({ entityId: schema.meetingAttachment.id, revision: schema.meetingAttachment.revision })
      .from(schema.meetingAttachment).where(eq(schema.meetingAttachment.vaultId, sourceVaultId));
    movedChanges.push(...meetingAttachments.map((row) => ({ entity: "meeting_attachment" as const, ...row, action: "upsert" as const })));
    movedChanges.push(...recordings.filter((recording) => recording.vaultId === sourceVaultId)
      .map((recording) => ({ entity: "recording" as const, entityId: recording.sessionId, revision: recording.revision, action: "upsert" as const })));
    if (searchBackend === "sqlite") {
      await (db as unknown as SQLiteDatabase).run(sql`PRAGMA defer_foreign_keys = ON`);
    } else {
      await db.execute(sql`SET CONSTRAINTS ALL DEFERRED`);
    }
    for (const table of [schema.syncedProject, schema.syncedMeeting, schema.syncedFile,
      schema.meetingAttachment, schema.meetingEvent, schema.transcriptPatchChunk, schema.searchDocument,
      schema.searchIndexJob, schema.imageAnalysisJob, schema.summaryJob]) {
      await db.update(table).set({ vaultId: destinationVaultId }).where(eq(table.vaultId, sourceVaultId));
    }
    // Transcript and summary history follows the unchanged meeting ID. Object keys never change.
    const id = uuidV7();
    const [result] = await db.insert(transfers).values({
      id, ownerUserId: userPrincipalId, idempotencyKey: request.idempotencyKey, requestHash: request.requestHash,
      sourceVaultId, destinationVaultId,
      manifest: { projects: projects.filter((project) => project.vaultId === sourceVaultId).map((project) => project.projectId),
        meetings: meetings.map((meeting) => meeting.id), files: files.map((file) => file.id) },
    }).returning();
    if (!result) throw new SyncTransactionError(500, "transfer_not_recorded");
    for (const vault of vaults) {
      const revision = vault.revision + 1;
      await db.update(schema.syncedVault).set({ revision, updatedAt: new Date() }).where(eq(schema.syncedVault.vaultId, vault.vaultId));
      await appendChanges({ schemaVersion: 3, id, vaultId: vault.vaultId, createdAt: new Date(), requestHash: request.requestHash, operations: [] },
        [{ entity: "vault", entityId: vault.vaultId, action: "upsert", revision }, ...(vault.vaultId === destinationVaultId ? movedChanges : [])]);
    }
    return result;
  }

  async function getVaultRelocations(vaultId: string): Promise<VaultRelocations> {
    await lockVault(vaultId, false);
    const table = schema.vaultTransfer;
    // Receipts retain the IDs after delta expiry or source deletion. Clients ask for current
    // locations, never replay transfer history or acknowledge a separate transfer cursor.
    const history = await db.select().from(table).where(or(
      eq(table.ownerUserId, userPrincipalId), readable(table.sourceVaultId), readable(table.destinationVaultId),
    )).orderBy(asc(table.sequence));
    const relevant = history.filter((transfer) => transfer.sourceVaultId === vaultId || transfer.destinationVaultId === vaultId);
    if (!relevant.length) return { vaults: [], items: [] };
    const ids = { projects: new Set<string>(), meetings: new Set<string>(), files: new Set<string>() };
    for (const transfer of relevant) for (const kind of ["projects", "meetings", "files"] as const) {
      for (const id of transfer.manifest[kind]) ids[kind].add(id);
    }
    const destinations = new Map<string, string>();
    const items: VaultRelocations["items"] = [];
    for (const [kind, entity, content, key] of [
      ["projects", "project", schema.syncedProject, schema.syncedProject.projectId],
      ["meetings", "meeting", schema.syncedMeeting, schema.syncedMeeting.meetingId],
      ["files", "file", schema.syncedFile, schema.syncedFile.fileId],
    ] as const) {
      for (const batch of batches([...ids[kind]], 100)) {
        const rows = await db.select({ id: key, vaultId: content.vaultId }).from(content).where(and(inArray(key, batch), readable(content.vaultId)));
        for (const row of rows) {
          destinations.set(row.id, row.vaultId);
          items.push({ entity, ...row });
        }
      }
    }
    // Resolve missing IDs against receipts read after the canonical lookup: a concurrent
    // onward transfer must not look like deletion merely because its new Vault is private.
    const latestHistory = await db.select().from(table).where(or(
      eq(table.ownerUserId, userPrincipalId), readable(table.sourceVaultId), readable(table.destinationVaultId),
    )).orderBy(asc(table.sequence));
    const present = new Set(items.map((item) => item.id));
    for (const transfer of latestHistory) for (const kind of ["projects", "meetings", "files"] as const) {
      for (const id of transfer.manifest[kind]) if (ids[kind].has(id) && !present.has(id)) destinations.set(id, transfer.destinationVaultId);
    }
    const vaults: VaultRelocations["vaults"] = [];
    for (const id of new Set(destinations.values())) {
      const [vault] = await content.read(schema.syncedVault, await db.select({ encryption: schema.syncedVault.encryption, encryptedPayload: schema.syncedVault.encryptedPayload, vaultId: schema.syncedVault.vaultId, organizationId: schema.syncedVault.organizationId, name: schema.syncedVault.name,
        icon: schema.syncedVault.icon, color: schema.syncedVault.color, revision: schema.syncedVault.revision,
        createdAt: schema.syncedVault.createdAt, updatedAt: schema.syncedVault.updatedAt, role: vaultRole(schema.syncedVault.vaultId),
      }).from(schema.syncedVault).where(and(eq(schema.syncedVault.vaultId, id), readable(schema.syncedVault.vaultId), isNull(schema.syncedVault.deletingAt))).limit(1));
      if (!vault) throw new SyncTransactionError(403, "transfer_access_required");
      vaults.push(vault);
    }
    return { vaults, items };
  }

  async function projectViews(vaultId: string): Promise<SyncProjectView[]> {
    const projects = await content.read(schema.syncedProject, await db.select().from(schema.syncedProject).where(and(
      readable(schema.syncedProject.vaultId),
      eq(schema.syncedProject.vaultId, vaultId),
    )).orderBy(asc(schema.syncedProject.parentProjectId), asc(schema.syncedProject.name), asc(schema.syncedProject.projectId)));
    if (await content.cipher(vaultId)) projects.sort((a, b) => (a.parentProjectId ?? "").localeCompare(b.parentProjectId ?? "") || a.name.localeCompare(b.name) || a.projectId.localeCompare(b.projectId));
    const counts = await db.select({ projectId: schema.syncedMeeting.projectId, meetingCount: count() })
      .from(schema.syncedMeeting).where(and(
        readableMeeting(vaultId),
        eq(schema.syncedMeeting.active, true),
        isNull(schema.syncedMeeting.deletingAt),
        isNotNull(schema.syncedMeeting.projectId),
      )).groupBy(schema.syncedMeeting.projectId);
    const directCounts = new Map(counts.map(({ projectId, meetingCount }) => [projectId, meetingCount]));
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
    searchFields: SearchDocumentFields;
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
        ...input.searchFields,
        embeddingContentHash: input.embeddingContentHash,
        updatedAt: now,
      }))).onConflictDoUpdate({
        target: [schema.searchDocument.vaultId, schema.searchDocument.documentId],
        set: {
          meetingId: sql`excluded.meeting_id`,
          kind: sql`excluded.kind`,
          searchText: sql`excluded.search_text`,
          ...Object.fromEntries(SEARCH_FIELDS.map((field) => [`${field}Text`, sql`excluded.${sql.identifier(`${field}_text`)}`])),
          embedding: sql`CASE WHEN ${schema.searchDocument.embeddingContentHash} = excluded.embedding_content_hash THEN ${schema.searchDocument.embedding} ELSE NULL END`,
          embeddingModel: sql`CASE WHEN ${schema.searchDocument.embeddingContentHash} = excluded.embedding_content_hash THEN ${schema.searchDocument.embeddingModel} ELSE NULL END`,
          embeddingContentHash: sql`excluded.embedding_content_hash`,
          updatedAt: now,
        },
      });
    }

    const withoutEmbedding = inputs.filter((input) => !embeddingConfig || !input.embeddingContentHash);
    for (let offset = 0; offset < withoutEmbedding.length; offset += batchSize) {
      const batch = withoutEmbedding.slice(offset, offset + batchSize);
      const documentIds = batch.map(({ documentId }) => documentId);
      const vaultId = batch[0]!.vaultId;
      await db.delete(schema.searchIndexJob).where(and(
        eq(schema.searchIndexJob.vaultId, vaultId),
        inArray(schema.searchIndexJob.documentId, documentIds),
      ));
      await db.update(schema.searchDocument).set({ embedding: null, embeddingModel: null }).where(and(
        eq(schema.searchDocument.vaultId, vaultId),
        inArray(schema.searchDocument.documentId, documentIds),
      ));
    }

    if (!embeddingConfig) return;
    const changed = inputs.filter((input) => input.embeddingContentHash
      && input.currentEmbeddingContentHash !== input.embeddingContentHash);
    const availableAt = new Date(Date.now() + 5_000);
    for (let offset = 0; offset < changed.length; offset += batchSize) {
      await db.insert(schema.searchIndexJob).values(changed.slice(offset, offset + batchSize).map((input) => ({
        vaultId: input.vaultId,
        documentId: input.documentId,
        model: embeddingConfig.model,
        dimensions: embeddingConfig.dimensions,
        availableAt,
        updatedAt: now,
      }))).onConflictDoUpdate({
        target: [schema.searchIndexJob.vaultId, schema.searchIndexJob.documentId],
        set: {
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

  function ftsExpressions(query: SyncSearchQuery, weights: SearchSettings = DEFAULT_SEARCH_SETTINGS) {
    if (searchBackend === "sqlite") {
      const match = query.tokens.map((token) => `"${token.replaceAll('"', '""')}"`).join(" AND ");
      const table = sql.identifier("search_documents_fts");
      const sourceTable = sql.identifier("search_documents");
      return {
        filter: sql`exists (select 1 from ${table} where rowid = ${sourceTable}.rowid and ${table} match ${match})`,
        rank: sql<number>`(select bm25(${table}, ${sql.join(SEARCH_FIELDS.map((field) => sql`${weights[field]}`), sql`, `)}) from ${table} where rowid = ${sourceTable}.rowid and ${table} match ${match})`,
      };
    }
    const vector = schema.searchDocument.searchVector;
    if (!vector) throw new Error("search_vector_not_configured");
    const tsquery = sql`plainto_tsquery('simple', ${query.text})`;
    // Score each matching term even when the AND query spans different fields.
    const rankQuery = sql.join(query.tokens.map((token) => sql`plainto_tsquery('simple', ${token})`), sql` || `);
    return {
      filter: sql`${vector} @@ ${tsquery}`,
      rank: sql<number>`(${sql.join(SEARCH_FIELDS.map((field) => {
        const fieldVector = schema.searchDocument[`${field}Vector`];
        if (!fieldVector) throw new Error("search_vector_not_configured");
        const score = searchBackend === "lakebase"
          ? sql`${fieldVector} <@> to_bm25query(to_tsvector('simple', ${query.text}), ${`search.search_documents_${field}_bm25`}::regclass)`
          : sql`-ts_rank_cd(${fieldVector}, (${rankQuery}))`;
        return sql`${weights[field]} * (${score})`;
      }), sql` + `)})`,
    };
  }

  function searchFilters(vaultId: string, kind: "meeting" | "screenshot", filters?: SyncSearchFilters) {
    const meeting = schema.syncedMeeting;
    const time = kind === "meeting" ? meeting.createdAt : schema.syncedScreenshot.capturedAt;
    const meetingFilter = and(readableMeeting(vaultId), eq(meeting.active, true), isNull(meeting.deletingAt),
      ...(filters?.projectIds ? [filters.projectIds.length ? inArray(meeting.projectId, filters.projectIds) : sql`false`] : []),
      ...(filters?.meetingIds ? [filters.meetingIds.length ? inArray(meeting.meetingId, filters.meetingIds) : sql`false`] : []),
      ...(filters?.unassigned ? [isNull(meeting.projectId)] : []));
    return and(
      kind === "meeting" ? meetingFilter : exists(db.select({ id: meeting.meetingId }).from(meeting)
        .where(and(meetingFilter, eq(meeting.meetingId, schema.syncedScreenshot.meetingId)))),
      ...(filters?.from ? [gte(time, filters.from)] : []),
      ...(filters?.to ? [lt(time, filters.to)] : []),
    );
  }

  async function ftsDocumentIds(
    vaultId: string,
    meetingId: string | undefined,
    kind: "meeting" | "screenshot",
    query: SyncSearchQuery,
  ): Promise<string[]> {
    const weights = await (searchSettings ??= createSearchSettingsStore(db, searchBackend !== "sqlite").get());
    if (searchBackend === "lakebase") {
      // ponytail: score all filtered matches; use a proven combined top-K plan if corpus size makes this too slow.
      await db.execute(sql`select set_config('lakebase_bm25.enable_scan', 'false', true)`);
    }
    const search = ftsExpressions(query, weights);
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
        .where(and(common, searchFilters(vaultId, "meeting", query.filters)))
        .orderBy(asc(search.rank), desc(schema.syncedMeeting.createdAt), desc(schema.syncedMeeting.meetingId))
        .limit(SEARCH_CANDIDATE_LIMIT)).map(({ documentId }) => documentId);
    }
    return (await db.select({ documentId: schema.searchDocument.documentId, rank: search.rank })
      .from(schema.searchDocument)
      .innerJoin(schema.syncedScreenshot, and(
        eq(schema.syncedScreenshot.vaultId, schema.searchDocument.vaultId),
        eq(schema.syncedScreenshot.screenshotId, schema.searchDocument.documentId),
      ))
      .where(and(common, eq(schema.syncedScreenshot.active, true), searchFilters(vaultId, "screenshot", query.filters)))
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
      eq(schema.searchDocument.embeddingModel, embedding.model),
      isNotNull(schema.searchDocument.embedding),
      sql`${searchBackend === "sqlite" ? sql`length(${schema.searchDocument.embedding}) / 4` : sql`cardinality(${schema.searchDocument.embedding})`} = ${embedding.dimensions}`,
    );
    if (searchBackend === "sqlite") {
      const rows = kind === "meeting"
        ? await db.select({
            documentId: schema.searchDocument.documentId,
            vector: schema.searchDocument.embedding,
            sortTime: schema.syncedMeeting.createdAt,
          }).from(schema.searchDocument).innerJoin(schema.syncedMeeting, and(
            eq(schema.syncedMeeting.vaultId, schema.searchDocument.vaultId),
            eq(schema.syncedMeeting.meetingId, schema.searchDocument.documentId),
          )).where(and(common, searchFilters(vaultId, "meeting", query.filters)))
        : await db.select({
            documentId: schema.searchDocument.documentId,
            vector: schema.searchDocument.embedding,
            sortTime: schema.syncedScreenshot.capturedAt,
          }).from(schema.searchDocument).innerJoin(schema.syncedScreenshot, and(
            eq(schema.syncedScreenshot.vaultId, schema.searchDocument.vaultId),
            eq(schema.syncedScreenshot.screenshotId, schema.searchDocument.documentId),
          )).where(and(common, eq(schema.syncedScreenshot.active, true), searchFilters(vaultId, "screenshot", query.filters)));
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
      ${schema.searchDocument.embedding}::${vectorType}
      <=> ${JSON.stringify(embedding.vector)}::${vectorType}
    )`;
    const base = db.select({ documentId: schema.searchDocument.documentId, distance })
      .from(schema.searchDocument);
    const rows = kind === "meeting"
      ? await base.innerJoin(schema.syncedMeeting, and(
          eq(schema.syncedMeeting.vaultId, schema.searchDocument.vaultId),
          eq(schema.syncedMeeting.meetingId, schema.searchDocument.documentId),
        )).where(and(common, searchFilters(vaultId, "meeting", query.filters)))
        .orderBy(asc(distance), desc(schema.syncedMeeting.createdAt), desc(schema.syncedMeeting.meetingId))
        .limit(SEARCH_CANDIDATE_LIMIT)
      : await base.innerJoin(schema.syncedScreenshot, and(
          eq(schema.syncedScreenshot.vaultId, schema.searchDocument.vaultId),
          eq(schema.syncedScreenshot.screenshotId, schema.searchDocument.documentId),
        )).where(and(common, eq(schema.syncedScreenshot.active, true), searchFilters(vaultId, "screenshot", query.filters)))
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
      .from(schema.syncedVault).where(writableVault(vaultId)).limit(1);
    if (!vault || vault.deletingAt) return false;
    const [meeting] = await db.select({ active: schema.syncedMeeting.active, deletingAt: schema.syncedMeeting.deletingAt })
      .from(schema.syncedMeeting).where(writableMeeting(vaultId, meetingId)).limit(1);
    return meeting?.active === true && meeting.deletingAt === null;
  }

  function selectRecordings() {
    return db.select({ ...getTableColumns(schema.syncedRecording), vaultId: schema.syncedMeeting.vaultId })
      .from(schema.syncedRecording)
      .innerJoin(schema.syncedMeeting, eq(schema.syncedMeeting.meetingId, schema.syncedRecording.meetingId));
  }

  async function queueRecordingDeletes(vaultId: string, meetingId?: string) {
    const records = await selectRecordings().where(and(
      eq(schema.syncedMeeting.vaultId, vaultId),
      meetingId ? eq(schema.syncedRecording.meetingId, meetingId) : undefined,
    ));
    for (const record of records) {
      await db.insert(schema.storageDeleteJob).values((["mic", "system"] as const)
        .map((source) => ({ storageKey: recordingStorageKey(record, source) }))).onConflictDoNothing();
    }
    return records;
  }

  function readableSummary(vaultId: string, meetingId: string) {
    return and(eq(schema.summary.meetingId, meetingId), exists(db.select({ id: schema.syncedMeeting.meetingId }).from(schema.syncedMeeting).where(and(
      eq(schema.syncedMeeting.meetingId, schema.summary.meetingId),
      eq(schema.syncedMeeting.vaultId, vaultId), readable(schema.syncedMeeting.vaultId),
    ))));
  }

  async function readMeetings<T extends { vaultId: string; meetingId: string; name: string; description: string; summaryTitle: string | null; summaryDocument: string | null }>(rows: T[]): Promise<T[]> {
    const plain = await content.read(schema.syncedMeeting, rows);
    for (const row of plain) {
      if (!await content.cipher(row.vaultId)) continue;
      const summary = await getSummaryVersion(row.vaultId, row.meetingId);
      row.summaryTitle = summary?.title ?? null;
      row.summaryDocument = summary?.document ?? null;
    }
    return plain;
  }

  async function readScreenshots<T extends { vaultId: string; fileId: string; ocrText: string | null; caption: string | null; contentHash: string }>(rows: T[]): Promise<T[]> {
    for (const row of rows) {
      if (!await content.cipher(row.vaultId)) continue;
      const [file] = await content.read(schema.syncedFile, await db.select().from(schema.syncedFile)
        .where(and(eq(schema.syncedFile.fileId, row.fileId), eq(schema.syncedFile.vaultId, row.vaultId), readable(schema.syncedFile.vaultId))).limit(1));
      if (!file) throw new SyncTransactionError(404, "file_not_found");
      row.ocrText = file.metadata.ocr_text ?? null;
      row.caption = file.metadata.caption ?? null;
      row.contentHash = file.checksum.slice(8);
    }
    return rows;
  }

  async function getSummaryVersion(vaultId: string, meetingId: string, version?: number) {
    const [row] = await content.read(schema.summary, await db.select().from(schema.summary).where(and(
      readableSummary(vaultId, meetingId),
      version === undefined ? undefined : eq(schema.summary.version, version),
    )).orderBy(desc(schema.summary.version)).limit(1));
    return row ? { ...row, metadata: row.metadata ? summaryMetadataSchema.parse(row.metadata) : null } : null;
  }

  const transcriptSelection = {
    encryptedPayload: schema.transcript.encryptedPayload,
    id: schema.transcript.id, meetingId: schema.transcript.meetingId,
    version: schema.transcript.version, syncRevision: schema.transcript.syncRevision,
    startedAt: schema.transcript.startedAt, endedAt: schema.transcript.endedAt,
    createdAt: schema.transcript.createdAt, metadata: schema.transcript.metadata,
    latestSegmentCreatedAt: sql`(select max(s.created_at) from ${schema.syncedTranscriptSegment} s where s.transcript_id = ${schema.transcript.id})`
      .mapWith(schema.syncedTranscriptSegment.createdAt),
  };
  async function getTranscript(vaultId: string, meetingId: string, version?: number): Promise<TranscriptVersion | null> {
    const [row] = await content.read(schema.transcript, await db.select(transcriptSelection).from(schema.transcript)
      .innerJoin(schema.syncedMeeting, eq(schema.transcript.meetingId, schema.syncedMeeting.meetingId)).where(and(
        readable(schema.syncedMeeting.vaultId), eq(schema.syncedMeeting.vaultId, vaultId), eq(schema.transcript.meetingId, meetingId),
        version === undefined ? undefined : eq(schema.transcript.version, version),
      )).orderBy(desc(schema.transcript.version)).limit(1));
    return row ? { ...row, status: transcriptStatus(row.endedAt, row.latestSegmentCreatedAt) } : null;
  }

  async function canonicalRecord(
    entity: SyncCanonicalRecord["entity"],
    vaultId: string,
    entityId: string,
    access: "write" | "read" = "write",
  ): Promise<SyncCanonicalRecord> {
    const canAccess = access === "write" ? writeAccess : readable;
    if (entity === "vault") {
      const [record] = await content.read(schema.syncedVault, await db.select({ ...publicVaultColumns(), role: vaultRole(schema.syncedVault.vaultId) }).from(schema.syncedVault).where(and(
        eq(schema.syncedVault.vaultId, vaultId),
        canAccess(schema.syncedVault.vaultId),
      )).limit(1));
      return { entity, id: entityId, revision: record?.revision ?? null, record: record ?? null };
    }
    if (entity === "project") {
      const [record] = await content.read(schema.syncedProject, await db.select().from(schema.syncedProject).where(and(
        eq(schema.syncedProject.vaultId, vaultId),
        eq(schema.syncedProject.projectId, entityId),
        canAccess(schema.syncedProject.vaultId),
      )).limit(1));
      return { entity, id: entityId, revision: record?.revision ?? null, record: record ?? null };
    }
    if (["meeting", "summary", "transcript"].includes(entity)) {
      const [record] = await content.read(schema.syncedMeeting, await db.select().from(schema.syncedMeeting).where(and(
        eq(schema.syncedMeeting.vaultId, vaultId),
        eq(schema.syncedMeeting.meetingId, entityId),
        canAccess(schema.syncedMeeting.vaultId),
      )).limit(1));
      if (!record) return { entity, id: entityId, revision: null, record: null };
      if (entity === "transcript") {
        return { entity, id: entityId, revision: record.transcriptRevision ?? null,
          record: { meetingId: record.meetingId, transcript: await getTranscript(vaultId, entityId) } };
      }
      const summary = await getSummaryVersion(vaultId, entityId);
      if (entity === "summary") {
        return { entity, id: entityId, revision: record.summaryRevision ?? null, record: {
          meetingId: record.meetingId,
          id: summary?.id ?? null,
          version: summary?.version ?? null,
          title: summary?.title ?? null,
          document: summary?.document ?? null,
          createdAt: summary?.createdAt ?? null,
        } };
      }
      return { entity, id: entityId, revision: record.revision ?? null,
        record: { ...record, hasSummary: summary !== null } };
    }
    if (entity === "recording") {
      const [record] = await selectRecordings().where(and(
        eq(schema.syncedMeeting.vaultId, vaultId), eq(schema.syncedRecording.sessionId, entityId),
        canAccess(schema.syncedMeeting.vaultId),
      )).limit(1);
      return { entity, id: entityId, revision: record?.revision || null,
        record: record && record.revision > 0 ? recordingCanonical(record) : null };
    }
    if (entity === "file") {
      const [record] = await content.read(schema.syncedFile, await db.select().from(schema.syncedFile).where(and(
        eq(schema.syncedFile.vaultId, vaultId), eq(schema.syncedFile.fileId, entityId), canAccess(schema.syncedFile.vaultId),
        ...(access === "read" ? [eq(schema.syncedFile.active, true)] : []),
      )).limit(1));
      return { entity, id: entityId, revision: record?.active ? record.revision : null,
        record: record ? { ...fileResponse(record), active: record.active } : null };
    }
    const [record] = await db.select().from(schema.meetingAttachment).where(and(
      eq(schema.meetingAttachment.vaultId, vaultId), eq(schema.meetingAttachment.id, entityId), canAccess(schema.meetingAttachment.vaultId),
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
        vaultId: transaction.vaultId,
        transactionId: transaction.id,
      }))).returning({ sequence: schema.syncChange.sequence });
      if (!inserted.length) throw new SyncTransactionError(500, "sync_change_not_recorded");
      cursor = Math.max(...inserted.map(({ sequence }) => sequence));
    }
    if (cursor === undefined) throw new SyncTransactionError(500, "sync_change_not_recorded");
    await db.insert(schema.syncVaultState).values({
      vaultId: transaction.vaultId,
      latestSequence: cursor,
    }).onConflictDoUpdate({
      target: [schema.syncVaultState.vaultId],
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
        writeAccess(schema.syncedProject.vaultId),
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
        writeAccess(schema.syncedProject.vaultId),
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
        writeAccess(schema.syncedProject.vaultId),
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
        writeAccess(schema.syncedProject.vaultId),
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
        writeAccess(schema.syncedMeeting.vaultId),
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
    const [storedReceipt] = await db.select().from(schema.syncTransactionReceipt).where(
      eq(schema.syncTransactionReceipt.transactionId, transaction.id),
    ).limit(1);
    if (!storedReceipt) return null;
    if (storedReceipt.ownerUserId !== userPrincipalId || storedReceipt.vaultId !== transaction.vaultId) {
      throw new SyncTransactionError(404, "vault_not_found");
    }
    const [vault] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
      .where(and(eq(schema.syncedVault.vaultId, transaction.vaultId), readable(schema.syncedVault.vaultId))).limit(1);
    const receiptContent = createContentEncryption(db, schema, userPrincipalId, encryption, undefined, "receipt");
    const [receipt] = await receiptContent.read(schema.syncTransactionReceipt, [storedReceipt]);
    if (!receipt) return null;
    if (receipt.vaultId !== transaction.vaultId || receipt.requestHash !== transaction.requestHash) {
      throw new SyncTransactionError(409, "idempotency_key_reused");
    }
    // After Vault deletion only acknowledge the operation; do not expose old content.
    if (receipt.responseJson !== null && vault) {
      const response = searchBackend === "sqlite"
        ? JSON.parse(receipt.responseJson as string) as SyncTransactionResponse
        : receipt.responseJson as SyncTransactionResponse;
      // Project historical receipts without changing their committed content or revisions.
      return { ...response, records: response.records.map((entry) => {
        if (!entry.record) return entry;
        if (entry.entity === "file" && "content_type" in entry.record) {
          const { content_type, metadata, ...record } = entry.record;
          delete record.uri;
          delete record.offset;
          const { ocr_text, ...fields } = metadata as Record<string, unknown>;
          return { ...entry, record: { ...record, contentType: content_type,
            metadata: { ...fields, ...(ocr_text !== undefined ? { ocrText: ocr_text } : {}) } } };
        }
        if (entry.entity === "recording") {
          const audio = Object.fromEntries(Object.entries(entry.record.audio as Record<string, Record<string, unknown>>)
            .map(([source, value]) => {
              if (!("content_type" in value)) return [source, value];
              const { content_type, contentURL, ...fields } = value;
              return [source, { ...fields, contentType: content_type, contentUrl: contentURL }];
            }));
          return { ...entry, record: { ...entry.record, audio } };
        }
        return entry;
      }) };
    }
    const results = searchBackend === "sqlite"
      ? JSON.parse(receipt.resultsJson as string) as SyncTransactionResponse["records"]
      : receipt.resultsJson as SyncTransactionResponse["records"];
    return { id: transaction.id, status: "committed", receipt: "compact", cursor: encodeSyncCursor(receipt.cursor), records: results };
  }

  async function insertMeetingEvent(values: Omit<typeof schema.meetingEvent.$inferInsert, "ownerUserId">) {
    const [existing] = await db.select().from(schema.meetingEvent).where(eq(schema.meetingEvent.id, values.id)).limit(1);
    if (!existing) {
      await db.insert(schema.meetingEvent).values({ ...values, ownerUserId: userPrincipalId });
      return;
    }
    const fields = ["vaultId", "meetingId", "kind", "occurredAt", "sessionId", "relatedId", "audioSource", "segmentIndex", "changedFields"] as const;
    if (fields.some((field) => JSON.stringify(existing[field] ?? null) !== JSON.stringify(values[field] ?? null))) {
      throw new SyncTransactionError(409, "event_id_reused");
    }
  }

  async function redactMeetingEvents(vaultId: string, meetingId?: string) {
    await db.update(schema.meetingEvent).set({ sessionId: null, relatedId: null, audioSource: null, segmentIndex: null, changedFields: null })
      .where(and(eq(schema.meetingEvent.vaultId, vaultId), meetingId ? eq(schema.meetingEvent.meetingId, meetingId) : undefined));
  }

  async function clearVault(vaultId: string, preservePermissions: boolean) {
    await queueRecordingDeletes(vaultId);
    const files = await db.select({ id: schema.syncedFile.fileId }).from(schema.syncedFile).where(eq(schema.syncedFile.vaultId, vaultId));
    if (files.length) await db.insert(schema.storageDeleteJob).values(files.map(({ id }) => ({ storageKey: fileStorageKey(id) }))).onConflictDoNothing();
    if (preservePermissions) {
      await db.delete(schema.meetingAttachment).where(eq(schema.meetingAttachment.vaultId, vaultId));
      await db.delete(schema.syncedFile).where(eq(schema.syncedFile.vaultId, vaultId));
      await redactMeetingEvents(vaultId);
      await db.delete(schema.searchIndexJob).where(eq(schema.searchIndexJob.vaultId, vaultId));
      await db.delete(schema.syncedMeeting).where(eq(schema.syncedMeeting.vaultId, vaultId));
      await db.delete(schema.syncedProject).where(eq(schema.syncedProject.vaultId, vaultId));
      await db.update(schema.syncedVault).set({ revision: 0, updatedAt: new Date() }).where(eq(schema.syncedVault.vaultId, vaultId));
    } else {
      await db.delete(schema.syncedVault).where(eq(schema.syncedVault.vaultId, vaultId));
    }
  }

  async function governance(organizationId: string) {
    const [member] = await db.select({ kind: schema.organization.kind }).from(schema.member)
      .innerJoin(schema.organization, eq(schema.organization.id, schema.member.organizationId))
      .where(and(eq(schema.member.organizationId, organizationId), eq(schema.member.userId, userPrincipalId), inArray(schema.member.role, ["owner", "admin"]))).limit(1);
    if (!member) throw new SyncTransactionError(403, "organization_admin_required");
    if (searchBackend !== "sqlite") {
      await db.execute(sql`select set_config('app.maintenance', 'governance', true), set_config('app.maintenance_organization_id', ${organizationId}, true)`);
    }
    return member;
  }

  const governanceContent = (organizationId: string) => createContentEncryption(db, schema, userPrincipalId, encryption,
    (vault) => exists(db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault).where(and(eq(schema.syncedVault.vaultId, vault), eq(schema.syncedVault.organizationId, organizationId)))), "governance");
  const governanceColumns = () => ({ vaultId: schema.syncedVault.vaultId, name: schema.syncedVault.name, encryptedPayload: schema.syncedVault.encryptedPayload,
    revision: schema.syncedVault.revision, creatorId: sql<string>`${schema.syncedVault.createdBy}->>'id'` });
  async function confirmVaultDeletion(organizationId: string, vaultId: string) {
    await governance(organizationId);
    const rows = await db.select(governanceColumns()).from(schema.syncedVault).where(and(eq(schema.syncedVault.organizationId, organizationId), eq(schema.syncedVault.vaultId, vaultId)));
    const [vault] = await governanceContent(organizationId).read(schema.syncedVault, rows);
    if (!vault) throw new SyncTransactionError(404, "vault_not_found");
    const [state] = await db.select({ sequence: schema.syncVaultState.latestSequence }).from(schema.syncVaultState).where(eq(schema.syncVaultState.vaultId, vaultId));
    return { ...vault, changeCursor: encodeSyncCursor(state?.sequence ?? 0) };
  }

  async function forceDeleteVault(organizationId: string, transaction: SyncTransaction, revision: number, changeCursor: string) {
    await lockVault(transaction.vaultId);
    const organization = await governance(organizationId);
    if (organization.kind !== "team") throw new SyncTransactionError(403, "personal_vault_immutable");
    const previous = await resolveTransaction(transaction);
    if (previous) return previous;
    const confirmation = await confirmVaultDeletion(organizationId, transaction.vaultId);
    if (confirmation.revision !== revision || confirmation.changeCursor !== changeCursor) throw new SyncTransactionError(409, "vault_delete_confirmation_stale");
    const encrypted = governanceContent(organizationId);
    await encrypted.cipher(transaction.vaultId);
    if (searchBackend !== "sqlite") await db.execute(sql`select set_config('app.maintenance', 'governance-delete', true), set_config('app.maintenance_vault_id', ${transaction.vaultId}, true)`);
    await clearVault(transaction.vaultId, false);
    const cursor = await appendChange(transaction, "vault", transaction.vaultId, "reset", null);
    const records: SyncCanonicalRecord[] = [{ entity: "vault", id: transaction.vaultId, revision: null, record: null }];
    const response: SyncTransactionResponse = { id: transaction.id, status: "committed", cursor: encodeSyncCursor(cursor), records };
    await saveReceipt(transaction, response, encrypted);
    return response;
  }

  async function saveReceipt(transaction: SyncTransaction, response: SyncTransactionResponse, encrypted = content) {
    await db.insert(schema.syncTransactionReceipt).values(await encrypted.write(schema.syncTransactionReceipt, {
      transactionId: transaction.id, ownerUserId: userPrincipalId, vaultId: transaction.vaultId, requestHash: transaction.requestHash,
      responseJson: searchBackend === "sqlite" ? JSON.stringify(response) : response,
      resultsJson: searchBackend === "sqlite" ? JSON.stringify(response.records.map(({ entity, id, revision }) => ({ entity, id, revision })))
        : response.records.map(({ entity, id, revision }) => ({ entity, id, revision })),
      cursor: decodeSyncCursor(response.cursor),
    }));
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
        .where(writableVault(transaction.vaultId)).limit(1);
      if (!vault) throw new SyncTransactionError(409, "revision_conflict", [{
        entity: "vault",
        id: transaction.vaultId,
        clientBaseRevision: null,
        serverRevision: null,
        record: null,
      }], transaction.operations[0]?.id);
    }
    for (const operation of transaction.operations) {
      const data = operation.data ?? {};
      const now = new Date();
      if (operation.entity === "meeting_event") {
        if (operation.baseRevision !== null) throw new SyncTransactionError(400, "invalid_sync_operation", [], operation.id);
        const meetingId = String(data.meetingId);
        const meeting = await canonicalRecord("meeting", transaction.vaultId, meetingId);
        if (!meeting.record || meeting.record.active !== true || meeting.record.deletingAt) {
          throw new SyncTransactionError(410, "meeting_event_parent_unavailable", [], operation.id);
        }
        if (data.sessionId) {
          const [other] = await db.select({ meetingId: schema.meetingEvent.meetingId }).from(schema.meetingEvent).where(and(
            eq(schema.meetingEvent.vaultId, transaction.vaultId), eq(schema.meetingEvent.sessionId, data.sessionId as string),
            sql`${schema.meetingEvent.meetingId} <> ${meetingId}`,
          )).limit(1);
          if (other) throw new SyncTransactionError(409, "recording_session_meeting_mismatch", [], operation.id);
        }
        await insertMeetingEvent({
          id: operation.entityId, vaultId: transaction.vaultId, meetingId, kind: String(data.kind),
          occurredAt: data.occurredAt as Date, receivedAt: now,
          sessionId: data.sessionId as string | undefined, relatedId: data.relatedId as string | undefined,
          audioSource: data.audioSource as string | undefined, segmentIndex: data.segmentIndex as number | undefined,
        });
        // Invalidate the existing meeting projection; event history is not a sync entity to pull.
        cursor = await appendChange(transaction, "meeting", meetingId, "upsert", meeting.revision);
        records.push({ entity: "meeting_event", id: operation.entityId, revision: null, record: null });
        continue;
      }
      await assertCreateAvailable(transaction, operation);
      if (operation.entity === "vault") {
        if (operation.action !== "create") {
          const [managed] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault).where(adminVault(transaction.vaultId)).limit(1);
          if (!managed) throw new SyncTransactionError(403, "vault_admin_required");
        }
        if (operation.action === "create") {
          const [organization] = await db.select({ id: schema.organization.id }).from(schema.organization)
            .innerJoin(schema.member, and(eq(schema.member.organizationId, schema.organization.id), eq(schema.member.userId, userPrincipalId)))
            .where(and(eq(schema.organization.id, String(data.organizationId)), or(eq(schema.organization.kind, "team"), exists(db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault).where(and(adminVault(transaction.vaultId), eq(schema.syncedVault.revision, 0), eq(schema.syncedVault.organizationId, schema.organization.id))))))).limit(1);
          if (!organization) throw new SyncTransactionError(403, "organization_forbidden");
          const [existing] = await db.select({
            id: schema.syncedVault.vaultId,
            revision: schema.syncedVault.revision,
            encryption: schema.syncedVault.encryption,
            organizationId: schema.syncedVault.organizationId,
          }).from(schema.syncedVault)
            .where(eq(schema.syncedVault.vaultId, transaction.vaultId)).limit(1);
          if (existing && existing.organizationId !== data.organizationId) throw new SyncTransactionError(409, "vault_organization_immutable");
          if (existing && data.encryption !== undefined && data.encryption !== existing.encryption) throw new SyncTransactionError(409, "vault_encryption_immutable");
          if (existing?.revision === 0) {
            const [restored] = await db.update(schema.syncedVault).set(await content.write(schema.syncedVault, {
              name: String(data.name),
              icon: data.icon as string | null | undefined,
              color: data.color as string | null | undefined,
              revision: 1,
              createdAt: data.createdAt as Date,
              updatedAt: now,
            }, { vaultId: transaction.vaultId })).where(adminVault(transaction.vaultId)).returning({ id: schema.syncedVault.vaultId });
            if (!restored) throw new SyncTransactionError(404, "vault_not_found", [], operation.id);
          } else {
            if (existing) throw new SyncTransactionError(409, "revision_conflict", [{
              entity: "vault",
              id: operation.entityId,
              clientBaseRevision: null,
              serverRevision: (await canonicalRecord("vault", transaction.vaultId, operation.entityId)).revision,
              record: (await canonicalRecord("vault", transaction.vaultId, operation.entityId)).record,
            }], operation.id);
            const [creator] = await db.select({ id: schema.user.id, name: schema.user.name, email: schema.user.email })
              .from(schema.user).where(eq(schema.user.id, userPrincipalId)).limit(1);
            if (!creator) throw new SyncTransactionError(403, "organization_forbidden");
            const [used] = await db.select({ id: schema.syncVaultState.vaultId }).from(schema.syncVaultState).where(eq(schema.syncVaultState.vaultId, transaction.vaultId)).limit(1);
            if (used) throw new SyncTransactionError(409, "vault_id_reused");
            await db.insert(schema.syncedVault).values({
              organizationId: organization.id,
              createdBy: creator,
              encryption: "none",
              vaultId: transaction.vaultId,
              name: String(data.name),
              icon: data.icon as string | null | undefined,
              color: data.color as string | null | undefined,
              revision: 1,
              createdAt: data.createdAt as Date,
              updatedAt: now,
            });
            await db.insert(schema.syncedVaultPermission).values({
              vaultId: transaction.vaultId,
              principalType: "user",
              principalId: userPrincipalId,
              role: "admin",
              grantedByUserId: userPrincipalId,
            });
            if (data.encryption === "server") {
              await content.create(transaction.vaultId);
              await db.update(schema.syncedVault).set(await content.write(schema.syncedVault,
                { encryption: "server", name: String(data.name) }, { vaultId: transaction.vaultId })).where(adminVault(transaction.vaultId));
            }
          }
        } else if (operation.action === "update") {
          await assertRevision(transaction, "vault", operation.entityId, operation.baseRevision);
          if (data.encryption !== undefined) {
            const existing = await canonicalRecord("vault", transaction.vaultId, operation.entityId);
            if (data.encryption !== existing.record?.encryption) throw new SyncTransactionError(409, "vault_encryption_immutable");
          }
          await db.update(schema.syncedVault).set(await content.write(schema.syncedVault, {
            name: String(data.name),
            icon: data.icon as string | null | undefined,
            color: data.color as string | null | undefined,
            revision: sql`${schema.syncedVault.revision} + 1`,
            updatedAt: now,
          }, { vaultId: transaction.vaultId })).where(adminVault(transaction.vaultId));
        } else if (operation.action === "reset") {
          const [organization] = await db.select({ kind: schema.organization.kind }).from(schema.organization)
            .innerJoin(schema.syncedVault, eq(schema.syncedVault.organizationId, schema.organization.id))
            .where(eq(schema.syncedVault.vaultId, transaction.vaultId)).limit(1);
          if (organization?.kind === "personal" && data.preservePermissions !== true) throw new SyncTransactionError(403, "personal_vault_immutable");
          const [owned] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
            .where(adminVault(transaction.vaultId)).limit(1);
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
          if (data.preservePermissions !== true) {
            const [content] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
              .where(and(adminVault(transaction.vaultId), vaultHasResources(schema.syncedVault.vaultId))).limit(1);
            if (content) throw new SyncTransactionError(409, "vault_not_empty", [], operation.id);
          }
          await clearVault(transaction.vaultId, data.preservePermissions === true);
          cursor = await appendChange(transaction, "vault", operation.entityId, "reset", null);
          records.push({ entity: "vault", id: operation.entityId, revision: null, record: null });
          continue;
        }
      } else if (operation.entity === "project") {
        if (operation.action === "create") {
          const parentProjectId = data.parentProjectId as string | null;
          await assertProjectHierarchy(transaction.vaultId, operation.entityId, parentProjectId, operation.id);
          await db.insert(schema.syncedProject).values(await content.write(schema.syncedProject, {
            projectId: operation.entityId,
            vaultId: transaction.vaultId,
            parentProjectId,
            name: String(data.name),
            icon: parentProjectId ? null : data.icon as string | null | undefined,
            color: parentProjectId ? null : data.color as string | null | undefined,
            description: stringField(data, "description"),
            projectType: data.projectType as string | null,
            revision: 1,
            createdAt: data.createdAt as Date,
            updatedAt: now,
          }));
        } else if (operation.action === "update") {
          const parentProjectId = data.parentProjectId as string | null;
          await assertRevision(transaction, "project", operation.entityId, operation.baseRevision,
            parentProjectId ? [{ entity: "project", id: parentProjectId }] : []);
          await assertProjectHierarchy(transaction.vaultId, operation.entityId, parentProjectId, operation.id);
          await db.update(schema.syncedProject).set(await content.write(schema.syncedProject, {
            parentProjectId,
            name: String(data.name),
            icon: parentProjectId ? null : data.icon as string | null | undefined,
            color: parentProjectId ? null : data.color as string | null | undefined,
            description: stringField(data, "description"),
            projectType: data.projectType as string | null,
            revision: sql`${schema.syncedProject.revision} + 1`,
            updatedAt: now,
          }, { projectId: operation.entityId, vaultId: transaction.vaultId })).where(and(
            eq(schema.syncedProject.vaultId, transaction.vaultId),
            eq(schema.syncedProject.projectId, operation.entityId),
            writeAccess(schema.syncedProject.vaultId),
          ));
        } else if (operation.action === "delete") {
          await assertRevision(transaction, "project", operation.entityId, operation.baseRevision);
          await assertProjectDeletionAvailable(transaction.vaultId, operation.entityId, operation.id);
          await db.delete(schema.syncedProject).where(and(
            eq(schema.syncedProject.vaultId, transaction.vaultId),
            eq(schema.syncedProject.projectId, operation.entityId),
            writeAccess(schema.syncedProject.vaultId),
          ));
          cursor = await appendChange(transaction, "project", operation.entityId, "delete", null);
          records.push({ entity: "project", id: operation.entityId, revision: null, record: null });
          continue;
        }
      } else if (operation.entity === "meeting") {
        const previous = operation.action === "update" ? await canonicalRecord("meeting", transaction.vaultId, operation.entityId) : null;
        if (data.calendarEvent && typeof data.calendarEvent === "object" && !("attendees" in data.calendarEvent)) {
          const existing = previous?.record?.calendarEvent;
          if (existing && typeof existing === "object" && "attendees" in existing) {
            data.calendarEvent = { ...data.calendarEvent, attendees: existing.attendees };
          }
        }
        if (operation.action === "create") {
          const [existing] = await db.select({ active: schema.syncedMeeting.active })
            .from(schema.syncedMeeting).where(writableMeeting(transaction.vaultId, operation.entityId)).limit(1);
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
            icalUid: data.icalUid as string | null | undefined,
            recurrenceId: data.recurrenceId as string | null | undefined,
            calendarEvent: data.calendarEvent as CalendarEventSnapshot | null | undefined,
            createdAt: data.createdAt as Date,
            updatedAt: data.updatedAt as Date,
            revision: 1,
            active: true,
          };
          if (existing) {
            await db.update(schema.syncedMeeting).set(await content.write(schema.syncedMeeting, values, { meetingId: operation.entityId, vaultId: transaction.vaultId })).where(writableMeeting(transaction.vaultId, operation.entityId));
          } else {
            await db.insert(schema.syncedMeeting).values(await content.write(schema.syncedMeeting, values));
          }
        } else if (operation.action === "update") {
          const projectId = data.projectId as string | null;
          await assertRevision(transaction, "meeting", operation.entityId, operation.baseRevision,
            projectId ? [{ entity: "project", id: projectId }] : []);
          await assertProjectReference(transaction.vaultId, projectId, operation.id);
          await db.update(schema.syncedMeeting).set(await content.write(schema.syncedMeeting, {
            projectId,
            name: String(data.name),
            description: stringField(data, "description"),
            status: String(data.status),
            duration: data.duration as number | null,
            recordingStartedAt: data.recordingStartedAt as Date | null,
            icalUid: data.icalUid as string | null | undefined,
            recurrenceId: data.recurrenceId as string | null | undefined,
            calendarEvent: data.calendarEvent as CalendarEventSnapshot | null | undefined,
            updatedAt: data.updatedAt as Date,
            revision: sql`${schema.syncedMeeting.revision} + 1`,
          }, { meetingId: operation.entityId, vaultId: transaction.vaultId })).where(writableMeeting(transaction.vaultId, operation.entityId));
        } else if (operation.action === "delete") {
          await assertRevision(transaction, "meeting", operation.entityId, operation.baseRevision);
          const attachments = await db.select({ id: schema.meetingAttachment.id }).from(schema.meetingAttachment).where(and(
            eq(schema.meetingAttachment.vaultId, transaction.vaultId), eq(schema.meetingAttachment.meetingId, operation.entityId),
          ));
          const deletedRecordings = await queueRecordingDeletes(transaction.vaultId, operation.entityId);
          await redactMeetingEvents(transaction.vaultId, operation.entityId);
          await insertMeetingEvent({ id: operation.id, vaultId: transaction.vaultId, meetingId: operation.entityId, kind: "meeting_deleted", occurredAt: now, receivedAt: now });
          await db.delete(schema.syncedMeeting).where(writableMeeting(transaction.vaultId, operation.entityId));
          // A coalesced delete/recreate must still invalidate the old canonical children.
          cursor = await appendChanges(transaction, [
            { entity: "summary", entityId: operation.entityId, action: "delete", revision: null },
            { entity: "transcript", entityId: operation.entityId, action: "delete", revision: null },
            ...deletedRecordings.map(({ sessionId: entityId }) => ({ entity: "recording" as const, entityId, action: "delete" as const, revision: null })),
            ...attachments.map(({ id: entityId }) => ({ entity: "meeting_attachment" as const, entityId, action: "delete" as const, revision: null })),
            { entity: "meeting", entityId: operation.entityId, action: "delete", revision: null },
          ]);
          records.push({ entity: "meeting", id: operation.entityId, revision: null, record: null });
          continue;
        }
        const changedFields = operation.action === "update"
          ? ["projectId", "name", "description", "status", "duration", "recordingStartedAt", "icalUid", "recurrenceId", "calendarEvent"].filter((field) =>
            data[field] !== undefined &&
            JSON.stringify(previous?.record?.[field] ?? null) !== JSON.stringify(data[field] ?? null))
          : [];
        if (operation.action === "create" || changedFields.length) {
          await insertMeetingEvent({
            id: operation.id, vaultId: transaction.vaultId, meetingId: operation.entityId,
            kind: operation.action === "create" ? "meeting_created" : "meeting_updated",
            occurredAt: now, receivedAt: now, changedFields: changedFields.length ? JSON.stringify(changedFields) : null,
          });
        }
      } else if (operation.entity === "summary") {
        await assertRevision(transaction, "summary", operation.entityId, operation.baseRevision);
        if (operation.action === "delete") {
          await db.delete(schema.summary).where(readableSummary(transaction.vaultId, operation.entityId));
        } else {
          const latest = await getSummaryVersion(transaction.vaultId, operation.entityId);
          const metadata = summaryMetadata(String(data.document));
          await db.insert(schema.summary).values(await content.write(schema.summary, { id: uuidV7(), meetingId: operation.entityId,
            version: (latest?.version ?? 0) + 1, title: String(data.title), document: String(data.document),
            createdAt: data.createdAt as Date, savedAt: now, metadata }));
        }
        await db.update(schema.syncedMeeting).set({
          summaryRevision: sql`${schema.syncedMeeting.summaryRevision} + 1`,
        }).where(writableMeeting(transaction.vaultId, operation.entityId));
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
        const patchScope = and(
          eq(schema.transcriptPatchChunk.vaultId, transaction.vaultId),
          eq(schema.transcriptPatchChunk.meetingId, operation.entityId),
          eq(schema.transcriptPatchChunk.patchId, patchId),
        );
        const storedChunks = await content.read(schema.transcriptPatchChunk, await db.select({ vaultId: schema.transcriptPatchChunk.vaultId, meetingId: schema.transcriptPatchChunk.meetingId, patchId: schema.transcriptPatchChunk.patchId, encryptedPayload: schema.transcriptPatchChunk.encryptedPayload,
          chunkIndex: schema.transcriptPatchChunk.chunkIndex,
          contentHash: schema.transcriptPatchChunk.contentHash,
        }).from(schema.transcriptPatchChunk).where(patchScope).orderBy(asc(schema.transcriptPatchChunk.chunkIndex)));
        if (storedChunks.length !== expectedChunks.length) {
          throw new SyncTransactionError(422, "transcript_patch_incomplete", [], operation.id);
        }
        for (const [index, chunk] of storedChunks.entries()) {
          const expected = expectedChunks[index];
          if (!expected || chunk.chunkIndex !== expected.index || chunk.contentHash !== expected.sha256) {
            throw new SyncTransactionError(422, "transcript_patch_hash_mismatch", [], operation.id);
          }
        }
        const incoming = data.transcript as Pick<TranscriptVersion, "id" | "startedAt" | "endedAt" | "metadata">;
        const latest = await getTranscript(transaction.vaultId, operation.entityId);
        const sameVersion = latest?.id === incoming.id;
        const mode = data.mode as "replace" | "append";
        if (sameVersion) {
          if (latest.endedAt !== null || mode !== "append" || !sameTranscriptModel(latest.metadata, incoming.metadata)) {
            throw new SyncTransactionError(409, "transcript_version_immutable", [], operation.id);
          }
        } else {
          const [existing] = await db.select({ id: schema.transcript.id }).from(schema.transcript)
            .where(eq(schema.transcript.id, incoming.id)).limit(1);
          if (existing) throw new SyncTransactionError(409, "transcript_version_immutable", [], operation.id);
          if (mode === "append" && (incoming.endedAt !== null || (latest && !sameTranscriptModel(latest.metadata, incoming.metadata)))) {
            throw new SyncTransactionError(409, "transcript_model_changed", [], operation.id);
          }
          await db.insert(schema.transcript).values(await content.write(schema.transcript, { ...incoming, meetingId: operation.entityId,
            version: (latest?.version ?? 0) + 1, syncRevision: Number(operation.baseRevision) + 1, createdAt: now }));
          if (mode === "append" && latest) {
            if (!await content.cipher(transaction.vaultId)) {
              // Copy once at live-version start. Each version is independently readable.
              await db.insert(schema.syncedTranscriptSegment).select(db.select({
                ...getTableColumns(schema.syncedTranscriptSegment),
                transcriptId: sql<string>`${incoming.id}`.as("transcript_id"),
              }).from(schema.syncedTranscriptSegment).where(eq(schema.syncedTranscriptSegment.transcriptId, latest.id)));
            } else {
              // A different transcript ID changes the authenticated row identity.
              let afterSegment: string | undefined;
              while (true) {
                const page = await content.read(schema.syncedTranscriptSegment, await db.select().from(schema.syncedTranscriptSegment)
                  .where(and(eq(schema.syncedTranscriptSegment.transcriptId, latest.id),
                    afterSegment ? gt(schema.syncedTranscriptSegment.segmentId, afterSegment) : undefined))
                  .orderBy(asc(schema.syncedTranscriptSegment.segmentId)).limit(250), transaction.vaultId);
                if (!page.length) break;
                await db.insert(schema.syncedTranscriptSegment).values(await content.writeMany(schema.syncedTranscriptSegment,
                  page.map((segment) => ({ ...segment, transcriptId: incoming.id })), { vaultId: transaction.vaultId }));
                afterSegment = page.at(-1)!.segmentId;
              }
            }
          }
        }
        if (mode === "replace" && data.deletionCount) throw new SyncTransactionError(422, "invalid_transcript_replacement", [], operation.id);
        const segmentIds = new Set<string>();
        let segmentCount = 0;
        let deletionCount = 0;
        // Keep one chunk's text in memory. Every chunk still publishes in this single transaction.
        for (const expected of expectedChunks) {
          const [chunk] = await content.read(schema.transcriptPatchChunk, await db.select().from(schema.transcriptPatchChunk).where(and(
            patchScope, eq(schema.transcriptPatchChunk.chunkIndex, expected.index),
          )).limit(1));
          if (!chunk || chunk.contentHash !== expected.sha256) {
            throw new SyncTransactionError(422, "transcript_patch_hash_mismatch", [], operation.id);
          }
          const payload = (typeof chunk.payload === "string" ? JSON.parse(chunk.payload) : chunk.payload) as {
            segments: Array<Omit<SyncTranscriptSegment, "createdAt" | "startedAt" | "endedAt"> & { createdAt: Date | string | null; startedAt: Date | string; endedAt: Date | string | null }>;
            deletions: string[];
          };
          if (payload.segments.length !== expected.segmentCount || payload.deletions.length !== expected.deletionCount) {
            throw new SyncTransactionError(422, "transcript_patch_count_mismatch", [], operation.id);
          }
          segmentCount += payload.segments.length;
          deletionCount += payload.deletions.length;
          for (const id of [...payload.segments.map(({ segmentId }) => segmentId), ...payload.deletions]) {
            if (segmentIds.has(id)) throw new SyncTransactionError(422, "invalid_transcript_patch", [], operation.id);
            segmentIds.add(id);
          }
          if (payload.deletions.length) await db.delete(schema.syncedTranscriptSegment).where(and(
            eq(schema.syncedTranscriptSegment.transcriptId, incoming.id),
            inArray(schema.syncedTranscriptSegment.segmentId, payload.deletions),
          ));
          for (const batch of batches(payload.segments, 250)) {
            await db.insert(schema.syncedTranscriptSegment).values(await content.writeMany(schema.syncedTranscriptSegment, batch.map((segment) => ({
              ...segment, transcriptId: incoming.id,
              normalizedCharacterCount: normalizedCharacterCount(segment.text),
              startedAt: new Date(segment.startedAt),
              endedAt: segment.endedAt ? new Date(segment.endedAt) : null,
              createdAt: segment.createdAt ? new Date(segment.createdAt) : null,
            })), { vaultId: transaction.vaultId })).onConflictDoUpdate({
              target: [schema.syncedTranscriptSegment.transcriptId, schema.syncedTranscriptSegment.segmentId],
              set: {
                startedAt: sql`excluded.started_at`, endedAt: sql`excluded.ended_at`, text: sql`excluded.text`,
                audioSource: sql`excluded.audio_source`, speakerLabel: sql`excluded.speaker_label`,
                normalizedCharacterCount: sql`excluded.normalized_character_count`,
                encryptedPayload: sql`excluded.encrypted_payload`,
              },
            });
          }
        }
        if (segmentCount !== data.segmentCount || deletionCount !== data.deletionCount) {
          throw new SyncTransactionError(422, "invalid_transcript_patch", [], operation.id);
        }
        if (sameVersion) {
          await db.update(schema.transcript).set(await content.write(schema.transcript, { ...incoming, syncRevision: Number(operation.baseRevision) + 1 }, { vaultId: transaction.vaultId }))
            .where(eq(schema.transcript.id, incoming.id));
        }
        await db.update(schema.syncedMeeting).set({
          transcriptRevision: sql`${schema.syncedMeeting.transcriptRevision} + 1`,
        }).where(writableMeeting(transaction.vaultId, operation.entityId));
        await db.delete(schema.transcriptPatchChunk).where(patchScope);
      } else if (operation.entity === "recording") {
        const [record] = await selectRecordings().where(and(
          eq(schema.syncedMeeting.vaultId, transaction.vaultId), eq(schema.syncedRecording.sessionId, operation.entityId),
          writeAccess(schema.syncedMeeting.vaultId),
        )).limit(1);
        if (!record || !await ensureUploadTarget(transaction.vaultId, record.meetingId)) {
          throw new SyncTransactionError(409, "recording_not_found", [], operation.id);
        }
        if (record.revision > 0 || operation.baseRevision !== null) {
          await assertRevision(transaction, "recording", operation.entityId, operation.baseRevision);
        }
        const source = data.source as RecordingSource;
        const audio = record.audio[source];
        const [pendingDelete] = await db.select().from(schema.storageDeleteJob)
          .where(eq(schema.storageDeleteJob.storageKey, recordingStorageKey(record, source))).limit(1);
        if (pendingDelete || !audio?.uploadedAt || audio.checksum !== data.checksum
          || (!audio.active && new Date(audio.createdAt).getTime() <= now.getTime() - 86_400_000)) {
          throw new SyncTransactionError(409, "recording_content_missing", [], operation.id);
        }
        const manifest = data.manifest as RecordingManifest;
        if (audio.active && JSON.stringify(audio.manifest) !== JSON.stringify(manifest)) {
          throw new SyncTransactionError(409, "recording_immutable", [], operation.id);
        }
        await db.update(schema.syncedRecording).set({
          audio: { ...record.audio, [source]: { ...audio, active: true, manifest } },
          revision: record.revision + 1, updatedAt: now,
        }).where(eq(schema.syncedRecording.sessionId, operation.entityId));
      } else if (operation.entity === "file") {
        const [file] = await content.read(schema.syncedFile, await db.select().from(schema.syncedFile).where(and(
          eq(schema.syncedFile.fileId, operation.entityId), eq(schema.syncedFile.vaultId, transaction.vaultId),
          writeAccess(schema.syncedFile.vaultId),
        )).limit(1));
        if (!file && operation.baseRevision !== null) await assertRevision(transaction, "file", operation.entityId, operation.baseRevision);
        if (!file) throw new SyncTransactionError(422, "file_content_missing", [], operation.id);
        if (file.active || operation.baseRevision !== null) {
          await assertRevision(transaction, "file", operation.entityId, operation.baseRevision);
        }
        if (operation.action === "delete") {
          const [reference] = await db.select({ id: schema.meetingAttachment.id }).from(schema.meetingAttachment)
            .where(eq(schema.meetingAttachment.fileId, file.fileId)).limit(1);
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
        await db.update(schema.syncedFile).set(await content.write(schema.syncedFile, { active: true, metadata,
          name: typeof data.name === "string" ? data.name : file.name,
          revision: file.revision + 1, updatedAt: now,
        }, { fileId: file.fileId, vaultId: transaction.vaultId })).where(eq(schema.syncedFile.fileId, file.fileId));
      } else if (operation.entity === "meeting_attachment") {
        const previous = await canonicalRecord("meeting_attachment", transaction.vaultId, operation.entityId);
        if (previous.record !== null || operation.baseRevision !== null || operation.action === "delete") {
          await assertRevision(transaction, "meeting_attachment", operation.entityId, operation.baseRevision,
            operation.action === "delete" ? [] : [{ entity: "meeting", id: String(data.meetingId) }]);
        }
        if (operation.action === "delete") {
          await db.delete(schema.meetingAttachment).where(and(eq(schema.meetingAttachment.id, operation.entityId),
            eq(schema.meetingAttachment.vaultId, transaction.vaultId)));
          await db.delete(schema.searchIndexJob).where(and(eq(schema.searchIndexJob.vaultId, transaction.vaultId), eq(schema.searchIndexJob.documentId, operation.entityId)));
          await db.delete(schema.searchDocument).where(and(eq(schema.searchDocument.vaultId, transaction.vaultId), eq(schema.searchDocument.documentId, operation.entityId)));
          cursor = await appendChange(transaction, "meeting_attachment", operation.entityId, "delete", null);
          records.push({ entity: "meeting_attachment", id: operation.entityId, revision: null, record: null });
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
          throw new SyncTransactionError(409, "meeting_attachment_identity_immutable", [], operation.id);
        }
        const [file] = await content.read(schema.syncedFile, await db.select().from(schema.syncedFile).where(and(
          eq(schema.syncedFile.fileId, fileId), eq(schema.syncedFile.vaultId, transaction.vaultId), eq(schema.syncedFile.active, true),
        )).limit(1));
        if (!file) throw new SyncTransactionError(422, "file_not_found", [], operation.id);
        const values = { capturedAt: data.capturedAt as Date | null, sessionId: data.sessionId as string | null,
          revision: (previous.revision ?? 0) + 1 };
        if (previous.record) {
          await db.update(schema.meetingAttachment).set(values).where(and(eq(schema.meetingAttachment.id, operation.entityId),
            eq(schema.meetingAttachment.vaultId, transaction.vaultId)));
        } else {
          const [inserted] = await db.insert(schema.meetingAttachment).values({ ...values, id: operation.entityId,
            vaultId: transaction.vaultId, meetingId, fileId, createdAt: data.createdAt as Date,
          }).onConflictDoNothing().returning({ id: schema.meetingAttachment.id });
          if (!inserted) throw new SyncTransactionError(409, "meeting_attachment_id_conflict", [], operation.id);
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
          searchFields: data.searchFields as SearchDocumentFields,
          embeddingContentHash: data.embeddingContentHash as string | null,
          currentEmbeddingContentHash: current?.hash ?? null,
        }]);
      }
      if (operation.entity === "file" || operation.entity === "meeting_attachment") {
        const images = await readScreenshots(await db.select().from(schema.syncedScreenshot).where(and(
          eq(schema.syncedScreenshot.vaultId, transaction.vaultId),
          operation.entity === "file" ? eq(schema.syncedScreenshot.fileId, operation.entityId) : eq(schema.syncedScreenshot.screenshotId, operation.entityId),
        )));
        for (const image of images) {
          const [current] = await db.select({ hash: schema.searchDocument.embeddingContentHash }).from(schema.searchDocument)
            .where(and(eq(schema.searchDocument.vaultId, transaction.vaultId), eq(schema.searchDocument.documentId, image.screenshotId))).limit(1);
          await updateSearchDocuments([{
            documentId: image.screenshotId, vaultId: transaction.vaultId, meetingId: image.meetingId, kind: "screenshot",
            searchText: typeof data.searchText === "string" ? data.searchText : "",
            searchFields: data.searchFields as SearchDocumentFields,
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
    await saveReceipt(transaction, response);
    return searchBackend === "sqlite"
      ? JSON.parse(JSON.stringify(response)) as SyncTransactionResponse
      : response;
  }

  const imageClaimKey = (claim: ImageAnalysisClaim) => and(
    eq(schema.imageAnalysisJob.fileId, claim.fileId),
    eq(schema.imageAnalysisJob.vaultId, claim.vaultId),
    eq(schema.imageAnalysisJob.ownerUserId, userPrincipalId),
    eq(schema.imageAnalysisJob.model, claim.model),
    eq(schema.imageAnalysisJob.claimedAt, claim.claimedAt),
    eq(schema.imageAnalysisJob.status, "processing"),
    gt(schema.imageAnalysisJob.leaseExpiresAt, new Date()),
  );

  async function loadImageAnalysis(claim: ImageAnalysisClaim): Promise<ImageAnalysisInput | null> {
    if (claim.ownerUserId !== userPrincipalId) return null;
    const [file] = await db.select({ file: schema.syncedFile }).from(schema.syncedFile)
      .innerJoin(schema.imageAnalysisJob, eq(schema.imageAnalysisJob.fileId, schema.syncedFile.fileId))
      .where(and(
        imageClaimKey(claim), eq(schema.syncedFile.vaultId, claim.vaultId),
        eq(schema.syncedFile.active, true), isNotNull(schema.syncedFile.uploadedAt),
        writeAccess(schema.syncedFile.vaultId),
        exists(db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault).where(writableVault(claim.vaultId))),
        exists(db.select({ id: schema.meetingAttachment.id }).from(schema.meetingAttachment)
          .innerJoin(schema.syncedMeeting, and(
            eq(schema.syncedMeeting.vaultId, schema.meetingAttachment.vaultId),
            eq(schema.syncedMeeting.meetingId, schema.meetingAttachment.meetingId),
          )).where(and(eq(schema.meetingAttachment.fileId, claim.fileId), isNull(schema.syncedMeeting.deletingAt)))),
      )).limit(1);
    if (file) file.file = (await content.read(schema.syncedFile, [file.file]))[0]!;
    return file && imageContentTypes.has(file.file.contentType) && needsImageAnalysis(file.file.metadata)
      ? { ...claim, file: file.file } : null;
  }

  async function completeImageAnalysis(input: ImageAnalysisInput, transaction: SyncTransaction): Promise<boolean> {
    await lockVault(input.vaultId);
    const claimQuery = db.select({ id: schema.imageAnalysisJob.fileId }).from(schema.imageAnalysisJob)
      .where(imageClaimKey(input));
    const [claim] = searchBackend === "sqlite" ? await claimQuery : await claimQuery.for("update");
    if (!claim) return false;
    const current = await loadImageAnalysis(input);
    if (!current || current.file.checksum !== input.file.checksum || current.file.revision !== input.file.revision) return false;
    await commitTransaction(transaction);
    await db.delete(schema.imageAnalysisJob).where(imageClaimKey(input));
    return true;
  }

  async function listChanges(
    vaultId: string,
    after: number,
    through: number,
    limit: number,
  ): Promise<SyncChangeRecord[]> {
    await lockVault(vaultId);
    await assertCursorAvailable(vaultId, after);
    const [vault] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
      .where(and(readable(schema.syncedVault.vaultId), eq(schema.syncedVault.vaultId, vaultId))).limit(1);
    const [history] = await db.select({ id: schema.syncVaultState.vaultId }).from(schema.syncVaultState).where(and(eq(schema.syncVaultState.vaultId, vaultId), readableHistory(schema.syncVaultState.vaultId))).limit(1);
    if (!vault && !history) throw new SyncTransactionError(404, "vault_not_found");
    const [latestReset] = await db.select({
      sequence: schema.syncChange.sequence,
      revision: schema.syncChange.revision,
      transactionId: schema.syncChange.transactionId,
    })
      .from(schema.syncChange).where(and(
        eq(schema.syncChange.vaultId, vaultId),
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
      gt(schema.syncChange.sequence, effectiveAfter),
      lte(schema.syncChange.sequence, through),
    )).groupBy(schema.syncChange.entity, schema.syncChange.entityId).as("latest_changes");
    const rowLimit = Math.max(0, limit - (latestReset ? 1 : 0));
    const rows = rowLimit === 0 ? [] : await db.select({
      sequence: schema.syncChange.sequence,
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
        readableHistory(schema.syncVaultState.vaultId),
        ...(vaultId ? [eq(schema.syncVaultState.vaultId, vaultId)] : []),
      ));
    return Number(row?.sequence ?? 0);
  }

  async function assertCursorAvailable(vaultId: string, after: number): Promise<void> {
    const [state] = await db.select({ through: sql<number>`max(${schema.syncVaultState.prunedThrough})` })
      .from(schema.syncVaultState).where(and(
        eq(schema.syncVaultState.vaultId, vaultId),
        readableHistory(schema.syncVaultState.vaultId),
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
      if (entity === "meeting") {
        const meeting = schema.syncedMeeting;
        const rows = await db.select({
          ...getTableColumns(meeting),
          hasSummary: exists(db.select({ id: schema.summary.id }).from(schema.summary)
            .where(eq(schema.summary.meetingId, meeting.meetingId))),
        }).from(meeting).where(and(
          readableMeeting(vaultId), eq(meeting.active, true), isNull(meeting.deletingAt),
          afterId ? gt(meeting.meetingId, afterId) : undefined,
        )).orderBy(asc(meeting.meetingId)).limit(remaining + 1);
        for (const row of await content.read(schema.syncedMeeting, rows, vaultId)) {
          if (!append({ entity, id: row.meetingId, revision: row.revision,
            record: { ...row, hasSummary: Boolean(row.hasSummary) } })) return { items: records, hasMore: true };
        }
        continue;
      }
      const source = entity === "project"
        ? { table: schema.syncedProject, id: schema.syncedProject.projectId, active: undefined }
        : entity === "recording" ? { table: schema.syncedRecording, id: schema.syncedRecording.sessionId, active: gt(schema.syncedRecording.revision, 0) }
        : entity === "file" ? { table: schema.syncedFile, id: schema.syncedFile.fileId, active: eq(schema.syncedFile.active, true) }
        : entity === "meeting_attachment" ? { table: schema.meetingAttachment, id: schema.meetingAttachment.id, active: undefined }
          : { table: schema.syncedMeeting, id: schema.syncedMeeting.meetingId, active: and(
              eq(schema.syncedMeeting.active, true), isNull(schema.syncedMeeting.deletingAt),
              entity === "summary" ? exists(db.select({ id: schema.summary.id }).from(schema.summary).where(eq(schema.summary.meetingId, schema.syncedMeeting.meetingId))) : undefined,
              entity === "transcript" ? gt(schema.syncedMeeting.transcriptRevision, 0) : undefined,
            ) };
      const sourceVault = "vaultId" in source.table ? source.table.vaultId : schema.syncedMeeting.vaultId;
      const selection = db.select({ id: source.id }).from(source.table);
      const query = entity === "recording"
        ? selection.innerJoin(schema.syncedMeeting, eq(schema.syncedMeeting.meetingId, schema.syncedRecording.meetingId))
        : selection;
      const rows = await query.where(and(
        eq(sourceVault, vaultId), readable(sourceVault), source.active,
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
    vaultTransferAudience,
    transferVault,
    getVaultRelocations,
    getSummaryVersion,
    async listSummaryVersions(vaultId, meetingId, limit, before) {
      const columns = schema.summary;
      const rows = await content.read(schema.summary, await db.select({ encryptedPayload: columns.encryptedPayload, id: columns.id, meetingId: columns.meetingId, version: columns.version,
        title: columns.title, createdAt: columns.createdAt, savedAt: columns.savedAt, metadata: columns.metadata }).from(schema.summary).where(and(
        readableSummary(vaultId, meetingId), before === undefined ? undefined : lt(columns.version, before),
      )).orderBy(desc(columns.version)).limit(limit), vaultId);
      return rows.map((row) => ({ ...row, metadata: row.metadata ? summaryMetadataSchema.parse(row.metadata) : null }));
    },
    async getSummaryJob(vaultId, meetingId, id) {
      const [row] = await content.read(schema.summaryJob, await db.select().from(schema.summaryJob).where(and(
        eq(schema.summaryJob.vaultId, vaultId), eq(schema.summaryJob.meetingId, meetingId),
        eq(schema.summaryJob.ownerUserId, identity.userId),
        id ? eq(schema.summaryJob.id, id) : undefined,
        writeAccess(schema.summaryJob.vaultId),
      )).orderBy(desc(schema.summaryJob.createdAt), desc(schema.summaryJob.id)).limit(1));
      return row ? { ...row, settings: storedTranscriptSettingsSchema.parse(row.settings) } : null;
    },
    async insertSummaryJob(job) {
      const inserted = await db.insert(schema.summaryJob).values(await content.write(schema.summaryJob, { ...job })).onConflictDoNothing({ target: schema.summaryJob.id }).returning({ id: schema.summaryJob.id });
      if (!inserted.length) throw new SyncTransactionError(409, "summary_id_reused");
    },
    async cancelSummaryJob(vaultId, meetingId, id) {
      const jobs = schema.summaryJob;
      const [row] = await content.read(jobs, await db.update(jobs).set({ status: "cancelled", claimedAt: null, leaseExpiresAt: null })
        .where(and(eq(jobs.id, id), eq(jobs.vaultId, vaultId), eq(jobs.meetingId, meetingId),
          eq(jobs.ownerUserId, identity.userId), writeAccess(jobs.vaultId), inArray(jobs.status, ["pending", "processing"])))
        .returning(), vaultId);
      return row ? { ...row, settings: storedTranscriptSettingsSchema.parse(row.settings) } : null;
    },
    async completeSummaryTranscript(job, transaction, transcriptId) {
      const jobs = schema.summaryJob;
      const filter = and(eq(jobs.id, job.id), eq(jobs.ownerUserId, identity.userId),
        eq(jobs.status, "processing"), eq(jobs.claimedAt, job.claimedAt!), gt(jobs.leaseExpiresAt, new Date()));
      const query = db.select().from(jobs).where(filter);
      const [current] = await content.read(jobs, searchBackend === "sqlite" ? await query : await query.for("update"), job.vaultId);
      if (!current) return null;
      if (current.transcriptResult) return getTranscript(job.vaultId, job.meetingId, Number(current.transcriptResult.version));
      await commitTransaction(transaction);
      const transcript = await getTranscript(job.vaultId, job.meetingId);
      if (!transcript || transcript.id !== transcriptId) throw new SyncTransactionError(409, "summary_transcript_conflict");
      await db.update(jobs).set(await content.write(jobs, { stage: "summarizing", transcriptResult: { transcriptId, version: String(transcript.version) } }, { id: job.id, vaultId: job.vaultId })).where(filter);
      return transcript;
    },
    async completeSummaryJob(job, transaction) {
      const jobs = schema.summaryJob;
      const filter = and(eq(jobs.id, job.id), eq(jobs.ownerUserId, identity.userId),
        eq(jobs.status, "processing"), eq(jobs.claimedAt, job.claimedAt!), gt(jobs.leaseExpiresAt, new Date()));
      const query = db.select().from(jobs).where(filter);
      const [current] = await content.read(jobs, searchBackend === "sqlite" ? await query : await query.for("update"), job.vaultId);
      if (!current) return false;
      await commitTransaction(transaction);
      await db.update(jobs).set({ status: "succeeded", claimedAt: null, leaseExpiresAt: null, lastErrorCode: null }).where(filter);
      return true;
    },
    lockVault,
    loadImageAnalysis,
    completeImageAnalysis,
    commitTransaction,
    resolveTransaction,
    assertCursorAvailable,
    listSnapshot,
    listChanges,
    confirmVaultDeletion, forceDeleteVault,
    async listGovernanceVaults(organizationId, after) {
      await governance(organizationId);
      const rows = await db.select(governanceColumns()).from(schema.syncedVault)
        .where(and(eq(schema.syncedVault.organizationId, organizationId), after ? gt(schema.syncedVault.vaultId, after) : undefined))
        .orderBy(asc(schema.syncedVault.vaultId)).limit(51);
      return { items: await governanceContent(organizationId).read(schema.syncedVault, rows.slice(0, 50)), nextCursor: rows.length > 50 ? rows[49]!.vaultId : null };
    },
    latestChangeSequence,
    ensureUploadTarget,
    async putTranscriptChunk(vaultId, meetingId, patchId, chunkIndex, contentHash, segments, deletions) {
      await lockVault(vaultId);
      if (!await ensureUploadTarget(vaultId, meetingId)) return false;
      await db.delete(schema.transcriptPatchChunk).where(and(
        eq(schema.transcriptPatchChunk.vaultId, vaultId),
        lt(schema.transcriptPatchChunk.createdAt, new Date(Date.now() - TRANSCRIPT_PATCH_RETENTION_MS)),
      ));
      const payload = { segments, deletions };
      await db.insert(schema.transcriptPatchChunk).values(await content.write(schema.transcriptPatchChunk, {
        vaultId,
        meetingId,
        patchId,
        chunkIndex,
        contentHash,
        payload: searchBackend === "sqlite" ? JSON.stringify(payload) : payload,
      })).onConflictDoNothing();
      const [stored] = await content.read(schema.transcriptPatchChunk, await db.select({ vaultId: schema.transcriptPatchChunk.vaultId, meetingId: schema.transcriptPatchChunk.meetingId, patchId: schema.transcriptPatchChunk.patchId, chunkIndex: schema.transcriptPatchChunk.chunkIndex, encryptedPayload: schema.transcriptPatchChunk.encryptedPayload, contentHash: schema.transcriptPatchChunk.contentHash })
        .from(schema.transcriptPatchChunk).where(and(
          eq(schema.transcriptPatchChunk.vaultId, vaultId),
          eq(schema.transcriptPatchChunk.meetingId, meetingId),
          eq(schema.transcriptPatchChunk.patchId, patchId),
          eq(schema.transcriptPatchChunk.chunkIndex, chunkIndex),
        )).limit(1));
      return stored?.contentHash === contentHash;
    },
    async deleteTranscriptPatch(vaultId, meetingId, patchId) {
      await db.delete(schema.transcriptPatchChunk).where(and(
        eq(schema.transcriptPatchChunk.vaultId, vaultId),
        eq(schema.transcriptPatchChunk.meetingId, meetingId),
        eq(schema.transcriptPatchChunk.patchId, patchId),
      ));
    },
    async getScreenshot(vaultId, meetingId, screenshotId, activeOnly = false) {
      const [row] = await readScreenshots(await db.select().from(schema.syncedScreenshot).where(and(
        readable(schema.syncedScreenshot.vaultId),
        eq(schema.syncedScreenshot.vaultId, vaultId),
        eq(schema.syncedScreenshot.meetingId, meetingId),
        eq(schema.syncedScreenshot.screenshotId, screenshotId),
        ...(activeOnly ? [eq(schema.syncedScreenshot.active, true)] : []),
      )).limit(1));
      return (row as SyncScreenshotRecord | undefined) ?? null;
    },
    async getFile(fileId, activeOnly = false) {
      const [file] = await content.read(schema.syncedFile, await db.select().from(schema.syncedFile).where(and(
        eq(schema.syncedFile.fileId, fileId), readable(schema.syncedFile.vaultId),
        activeOnly ? eq(schema.syncedFile.active, true) : writeAccess(schema.syncedFile.vaultId),
      )).limit(1));
      return file ?? null;
    },
    async reserveRecording(vaultId, meetingId, sessionId, source) {
      await lockVault(vaultId);
      if (!await ensureUploadTarget(vaultId, meetingId)) throw new SyncTransactionError(404, "meeting_not_found");
      const [session] = await db.select().from(schema.recordingSession).where(and(
        eq(schema.recordingSession.vaultId, vaultId), eq(schema.recordingSession.meetingId, meetingId),
        eq(schema.recordingSession.sessionId, sessionId),
      )).limit(1);
      if (!session?.startedAt || !session.endedAt) throw new SyncTransactionError(409, "recording_session_not_finalized");
      let [record] = await selectRecordings()
        .where(eq(schema.syncedRecording.sessionId, sessionId)).limit(1);
      if (record && (record.vaultId !== vaultId || record.meetingId !== meetingId)) {
        throw new SyncTransactionError(409, "recording_session_meeting_mismatch");
      }
      const now = new Date();
      if (!record) {
        const [last] = await db.select({ number: schema.syncedRecording.number }).from(schema.syncedRecording)
          .where(eq(schema.syncedRecording.meetingId, meetingId)).orderBy(desc(schema.syncedRecording.number)).limit(1);
        const [inserted] = await db.insert(schema.syncedRecording).values({ sessionId, meetingId,
          number: (last?.number ?? 0) + 1, startedAt: session.startedAt, endedAt: session.endedAt,
          audio: {}, revision: 0, createdAt: now, updatedAt: now,
        }).returning();
        record = { ...inserted!, vaultId };
      }
      if (!record) throw new SyncTransactionError(409, "recording_session_conflict");
      const [pending] = await db.select().from(schema.storageDeleteJob)
        .where(eq(schema.storageDeleteJob.storageKey, recordingStorageKey(record, source))).limit(1);
      if (pending) throw new SyncTransactionError(503, "recording_storage_delete_pending");
      if (!record.audio[source]) {
        const audio = { ...record.audio, [source]: { generation: crypto.randomUUID(), createdAt: now.toISOString(),
          uploadedAt: null, active: false, content_type: "audio/mp4" as const, size: 0, checksum: null } };
        await db.update(schema.syncedRecording).set({ audio, updatedAt: now }).where(eq(schema.syncedRecording.sessionId, sessionId));
        record = { ...record, audio };
      }
      return record;
    },
    async getRecording(meetingId, number, ownerOnly = false) {
      const [record] = await selectRecordings().where(and(
        eq(schema.syncedRecording.meetingId, meetingId), eq(schema.syncedRecording.number, number),
        ownerOnly ? writeAccess(schema.syncedMeeting.vaultId) : readable(schema.syncedMeeting.vaultId),
      )).limit(1);
      return record ?? null;
    },
    async markRecordingUploaded(sessionId, source, generation, size, checksum) {
      const [initial] = await selectRecordings().where(and(
        eq(schema.syncedRecording.sessionId, sessionId), writeAccess(schema.syncedMeeting.vaultId),
      )).limit(1);
      if (!initial) return null;
      await lockVault(initial.vaultId);
      const [record] = await selectRecordings().where(eq(schema.syncedRecording.sessionId, sessionId)).limit(1);
      const audio = record?.audio[source];
      if (!record || audio?.generation !== generation || !await ensureUploadTarget(record.vaultId, record.meetingId)) return null;
      const [pending] = await db.select().from(schema.storageDeleteJob)
        .where(eq(schema.storageDeleteJob.storageKey, recordingStorageKey(record, source))).limit(1);
      if (pending) return null;
      const updated: RecordingRecord = { ...record, updatedAt: new Date(), audio: { ...record.audio,
        [source]: { ...audio, size, checksum, uploadedAt: new Date().toISOString() } } };
      await db.update(schema.syncedRecording).set({ audio: updated.audio, updatedAt: updated.updatedAt })
        .where(eq(schema.syncedRecording.sessionId, sessionId));
      return updated;
    },
    async hasPendingRecordings(meetingId) {
      const sessions = await db.select({ sessionId: schema.recordingSession.sessionId,
        startedAt: schema.recordingSession.startedAt, endedAt: schema.recordingSession.endedAt })
        .from(schema.recordingSession).innerJoin(schema.syncedMeeting, and(
          eq(schema.syncedMeeting.vaultId, schema.recordingSession.vaultId),
          eq(schema.syncedMeeting.meetingId, schema.recordingSession.meetingId),
        )).where(and(eq(schema.recordingSession.meetingId, meetingId), readable(schema.syncedMeeting.vaultId)));
      const records = await selectRecordings().where(and(
        eq(schema.syncedRecording.meetingId, meetingId), readable(schema.syncedMeeting.vaultId),
      ));
      const bySession = new Map(records.map((record) => [record.sessionId, record]));
      return sessions.some((session) => {
        const record = bySession.get(session.sessionId);
        return !session.startedAt || !session.endedAt || !record || record.revision < 1
          || Object.keys(record.audio).length === 0
          || Object.values(record.audio).some((audio) => !audio.active || !audio.uploadedAt || !audio.manifest || !audio.checksum);
      });
    },
    async listRecordings(meetingId, after, limit) {
      return selectRecordings().where(and(
        eq(schema.syncedRecording.meetingId, meetingId), gt(schema.syncedRecording.number, after),
        gt(schema.syncedRecording.revision, 0), readable(schema.syncedMeeting.vaultId),
      )).orderBy(asc(schema.syncedRecording.number)).limit(limit);
    },
    async expireRecordingUploads(vaultId, before) {
      await lockVault(vaultId);
      if (!await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault).where(writableVault(vaultId)).limit(1).then((rows) => rows.length)) return;
      await expireRecordingStaging(db, schema, searchBackend !== "sqlite", vaultId, before);
    },
    async reserveFile(input) {
      await lockVault(input.vaultId);
      const [vault] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
        .where(writableVault(input.vaultId)).limit(1);
      if (!vault) return null;
      await db.insert(schema.syncedFile).values(await content.write(schema.syncedFile, { ...input })).onConflictDoNothing();
      const [file] = await content.read(schema.syncedFile, await db.select().from(schema.syncedFile).where(and(
        eq(schema.syncedFile.fileId, input.fileId), eq(schema.syncedFile.vaultId, input.vaultId), writeAccess(schema.syncedFile.vaultId),
      )).limit(1));
      return file ?? null;
    },
    async markFileUploaded(pending, size, checksum) {
      const [file] = await content.read(schema.syncedFile, await db.update(schema.syncedFile).set(await content.write(schema.syncedFile, { size, checksum, uploadedAt: new Date(), updatedAt: new Date() }, { fileId: pending.fileId, vaultId: pending.vaultId }))
        .where(and(eq(schema.syncedFile.fileId, pending.fileId), eq(schema.syncedFile.vaultId, pending.vaultId),
          eq(schema.syncedFile.createdAt, pending.createdAt), isNull(schema.syncedFile.uploadedAt),
          eq(schema.syncedFile.active, false), writeAccess(schema.syncedFile.vaultId),
          notExists(db.select({ key: schema.storageDeleteJob.storageKey }).from(schema.storageDeleteJob)
            .where(eq(schema.storageDeleteJob.storageKey, fileStorageKey(pending.fileId))))))
        .returning(), pending.vaultId);
      return file ?? null;
    },
    async expireFileUploads(vaultId, before) {
      await lockVault(vaultId);
      const files = await db.select({ id: schema.syncedFile.fileId }).from(schema.syncedFile).where(and(
        eq(schema.syncedFile.vaultId, vaultId), eq(schema.syncedFile.active, false), lt(schema.syncedFile.updatedAt, before), writeAccess(schema.syncedFile.vaultId),
      )).limit(25);
      for (const file of files) {
        const deleted = await db.delete(schema.syncedFile).where(and(
          eq(schema.syncedFile.fileId, file.id), eq(schema.syncedFile.active, false), lt(schema.syncedFile.updatedAt, before),
        )).returning({ id: schema.syncedFile.fileId });
        if (deleted.length) await db.insert(schema.storageDeleteJob).values({ storageKey: fileStorageKey(file.id) }).onConflictDoNothing();
      }
    },
    async listFiles(vaultId, after, limit) {
      return content.read(schema.syncedFile, await db.select().from(schema.syncedFile).where(and(
        eq(schema.syncedFile.vaultId, vaultId), readable(schema.syncedFile.vaultId), eq(schema.syncedFile.active, true),
        after ? gt(schema.syncedFile.fileId, after) : undefined,
      )).orderBy(asc(schema.syncedFile.fileId)).limit(limit));
    },
    async listMeetingAttachments(vaultId, meetingId, after, limit) {
      const rows = await db.select({ link: schema.meetingAttachment, file: schema.syncedFile }).from(schema.meetingAttachment)
        .innerJoin(schema.syncedFile, eq(schema.syncedFile.fileId, schema.meetingAttachment.fileId)).where(and(
          eq(schema.meetingAttachment.vaultId, vaultId), eq(schema.meetingAttachment.meetingId, meetingId), readable(schema.meetingAttachment.vaultId),
          eq(schema.syncedFile.active, true), after ? gt(schema.meetingAttachment.id, after) : undefined,
        )).orderBy(asc(schema.meetingAttachment.id)).limit(limit);
      return Promise.all(rows.map(async ({ link, file }) => ({ ...link, file: (await content.read(schema.syncedFile, [file]))[0]! })));
    },
    async listOrganizations() {
      return db.select({
        id: schema.organization.id, name: schema.organization.name, slug: schema.organization.slug, kind: schema.organization.kind,
      }).from(schema.organization).where(exists(
        db.select({ value: sql`1` }).from(schema.member).where(and(
          eq(schema.member.organizationId, schema.organization.id),
          eq(schema.member.userId, userPrincipalId),
        )),
      )).orderBy(asc(schema.organization.name), asc(schema.organization.id));
    },
    async listVaults(organizationId) {
      const scope = organizationId ? eq(schema.syncedVault.organizationId, organizationId) : undefined;
      const rows = await content.read(schema.syncedVault, await db.select({ encryption: schema.syncedVault.encryption, encryptedPayload: schema.syncedVault.encryptedPayload,
        vaultId: schema.syncedVault.vaultId,
        organizationId: schema.syncedVault.organizationId,
        name: schema.syncedVault.name,
        icon: schema.syncedVault.icon, color: schema.syncedVault.color,
        revision: schema.syncedVault.revision,
        createdAt: schema.syncedVault.createdAt,
        updatedAt: schema.syncedVault.updatedAt,
        role: vaultRole(schema.syncedVault.vaultId),
      }).from(schema.syncedVault).where(and(
        readable(schema.syncedVault.vaultId),
        scope,
        isNull(schema.syncedVault.deletingAt),
      )).orderBy(desc(schema.syncedVault.updatedAt)));
      return rows;
    },
    async getVault(vaultId) {
      const [row] = await content.read(schema.syncedVault, await db.select({ encryption: schema.syncedVault.encryption, encryptedPayload: schema.syncedVault.encryptedPayload,
        vaultId: schema.syncedVault.vaultId,
        organizationId: schema.syncedVault.organizationId,
        name: schema.syncedVault.name,
        hasResources: vaultHasResources(schema.syncedVault.vaultId).mapWith(Boolean),
        icon: schema.syncedVault.icon, color: schema.syncedVault.color,
        revision: schema.syncedVault.revision,
        createdAt: schema.syncedVault.createdAt,
        updatedAt: schema.syncedVault.updatedAt,
        role: vaultRole(schema.syncedVault.vaultId),
      }).from(schema.syncedVault).where(and(
        readable(schema.syncedVault.vaultId),
        eq(schema.syncedVault.vaultId, vaultId),
        isNull(schema.syncedVault.deletingAt),
      )).limit(1));
      return row ?? null;
    },
    async listProjects(vaultId) {
      return projectViews(vaultId);
    },
    async resolveEntityVault(entity, id) {
      const table = entity === "meeting" ? schema.syncedMeeting : schema.syncedProject;
      const key = entity === "meeting" ? schema.syncedMeeting.meetingId : schema.syncedProject.projectId;
      const [row] = await db.select({ vaultId: table.vaultId }).from(table)
        .innerJoin(schema.syncedVault, eq(schema.syncedVault.vaultId, table.vaultId))
        .where(and(eq(key, id), readable(table.vaultId), isNull(schema.syncedVault.deletingAt),
          ...(entity === "meeting" ? [eq(schema.syncedMeeting.active, true), isNull(schema.syncedMeeting.deletingAt)] : []))).limit(1);
      return row?.vaultId ?? null;
    },
    async getProject(vaultId, projectId) {
      return (await projectViews(vaultId)).find((project) => project.projectId === projectId) ?? null;
    },
    async searchProjectActivity(vaultId, filters) {
      const rows = await db.select({ projectId: schema.syncedMeeting.projectId,
        updatedAt: max(schema.syncedMeeting.updatedAt) }).from(schema.syncedMeeting)
        .where(searchFilters(vaultId, "meeting", filters)).groupBy(schema.syncedMeeting.projectId);
      return rows.map((row) => ({ ...row, updatedAt: row.updatedAt!.toISOString() }));
    },
    async listMeetings(vaultId, query, limit, projectId, cursor, projectScope, filters) {
      if (query && query.tokens.length === 0) return [];
      const projectIds = projectId
        ? (await projectViews(vaultId)).filter((project) =>
            project.projectId === projectId || (projectScope !== "direct" && project.parentProjectId === projectId)).map((project) => project.projectId)
        : undefined;
      if (projectId && projectIds?.length === 0) return [];
      filters = { ...filters, ...(projectIds ? { projectIds } : {}), ...(projectScope === "unassigned" ? { unassigned: true } : {}) };
      const filter = and(
        searchFilters(vaultId, "meeting", filters),
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
        return await readMeetings(await db.select(meetingSelection(schema)).from(schema.syncedMeeting)
          .where(filter).orderBy(desc(schema.syncedMeeting.createdAt), desc(schema.syncedMeeting.meetingId))
          .limit(limit));
      }
      const ids = await rankedDocumentIds(vaultId, undefined, "meeting", { ...query, filters });
      if (ids.length === 0) return [];
      const rows = await readMeetings(await db.select(meetingSelection(schema)).from(schema.syncedMeeting)
        .where(and(filter, inArray(schema.syncedMeeting.meetingId, ids)))
        .orderBy(desc(schema.syncedMeeting.createdAt), desc(schema.syncedMeeting.meetingId)));
      const rank = new Map(ids.map((id, index) => [id, index]));
      return rows.sort((left, right) => rank.get(left.meetingId)! - rank.get(right.meetingId)!).slice(0, limit);
    },
    async getMeeting(vaultId, meetingId) {
      const [row] = await readMeetings(await db.select(meetingSelection(schema)).from(schema.syncedMeeting).where(and(
        readableMeeting(vaultId, meetingId),
        eq(schema.syncedMeeting.active, true),
        isNull(schema.syncedMeeting.deletingAt),
      )).limit(1));
      return row ?? null;
    },
    getTranscript,
    async listTranscriptVersions(vaultId, meetingId, limit, before) {
      const rows = await content.read(schema.transcript, await db.select(transcriptSelection).from(schema.transcript)
        .innerJoin(schema.syncedMeeting, eq(schema.transcript.meetingId, schema.syncedMeeting.meetingId)).where(and(
          readable(schema.syncedMeeting.vaultId), eq(schema.syncedMeeting.vaultId, vaultId), eq(schema.transcript.meetingId, meetingId),
          before === undefined ? undefined : lt(schema.transcript.version, before),
        )).orderBy(desc(schema.transcript.version)).limit(limit));
      const now = new Date();
      return rows.map((row: Omit<TranscriptVersion, "status">) => ({ ...row, status: transcriptStatus(row.endedAt, row.latestSegmentCreatedAt, now) }));
    },
    async countTranscript(vaultId, meetingId) {
      const latest = db.select({ id: schema.transcript.id }).from(schema.transcript)
        .innerJoin(schema.syncedMeeting, eq(schema.transcript.meetingId, schema.syncedMeeting.meetingId)).where(and(
          readable(schema.syncedMeeting.vaultId), eq(schema.syncedMeeting.vaultId, vaultId), eq(schema.transcript.meetingId, meetingId),
        )).orderBy(desc(schema.transcript.version)).limit(1);
      const [row] = await db.select({ count: sql<number>`count(*)` }).from(schema.syncedTranscriptSegment)
        .where(eq(schema.syncedTranscriptSegment.transcriptId, latest));
      return Number(row?.count ?? 0);
    },
    async searchTextPage(vaultId, query, kind, offset, limit) {
      if (query.tokens.length === 0) return [];
      const search = ftsExpressions(query);
      const common = and(readable(schema.searchDocument.vaultId), eq(schema.searchDocument.vaultId, vaultId),
        eq(schema.searchDocument.kind, kind), search.filter);
      const selection = { id: schema.searchDocument.documentId, meetingId: schema.searchDocument.meetingId,
        snippet: sql<string>`substr(${schema.searchDocument.searchText}, 1, 180)` };
      // The cursor tracks this Vault's revisions; corpus-wide BM25 changes cannot define stable pages.
      const rows = kind === "meeting"
        ? await db.select(selection).from(schema.searchDocument).innerJoin(schema.syncedMeeting, and(
            eq(schema.syncedMeeting.vaultId, schema.searchDocument.vaultId),
            eq(schema.syncedMeeting.meetingId, schema.searchDocument.documentId),
          )).where(and(common, eq(schema.syncedMeeting.active, true), isNull(schema.syncedMeeting.deletingAt)))
          .orderBy(asc(schema.searchDocument.documentId)).limit(limit).offset(offset)
        : await db.select(selection).from(schema.searchDocument).innerJoin(schema.syncedScreenshot, and(
            eq(schema.syncedScreenshot.vaultId, schema.searchDocument.vaultId),
            eq(schema.syncedScreenshot.screenshotId, schema.searchDocument.documentId),
          )).innerJoin(schema.syncedMeeting, and(eq(schema.syncedMeeting.vaultId, schema.syncedScreenshot.vaultId),
            eq(schema.syncedMeeting.meetingId, schema.syncedScreenshot.meetingId)))
          .where(and(common, eq(schema.syncedScreenshot.active, true), eq(schema.syncedMeeting.active, true), isNull(schema.syncedMeeting.deletingAt)))
          .orderBy(asc(schema.searchDocument.documentId)).limit(limit).offset(offset);
      return rows.map((row) => ({ ...row, meetingId: row.meetingId ?? row.id }));
    },
    async listTranscript(vaultId, meetingId, limit, cursor, version) {
      const [meeting] = await db.select({ id: schema.syncedMeeting.meetingId })
        .from(schema.syncedMeeting).where(and(
          readableMeeting(vaultId, meetingId),
          eq(schema.syncedMeeting.active, true),
          isNull(schema.syncedMeeting.deletingAt),
        )).limit(1);
      if (!meeting) return [];
      const transcript = await getTranscript(vaultId, meetingId, version);
      if (!transcript) return [];
      const query = db.select({
        encryptedPayload: schema.syncedTranscriptSegment.encryptedPayload,
        transcriptId: schema.syncedTranscriptSegment.transcriptId,
        segmentId: schema.syncedTranscriptSegment.segmentId,
        startedAt: schema.syncedTranscriptSegment.startedAt,
        endedAt: schema.syncedTranscriptSegment.endedAt,
        text: schema.syncedTranscriptSegment.text,
        createdAt: schema.syncedTranscriptSegment.createdAt,
        audioSource: schema.syncedTranscriptSegment.audioSource,
        speakerLabel: schema.syncedTranscriptSegment.speakerLabel,
      }).from(schema.syncedTranscriptSegment).where(and(
        eq(schema.syncedTranscriptSegment.transcriptId, transcript.id),
        ...(cursor ? [or(
          gt(schema.syncedTranscriptSegment.startedAt, cursor.startedAt),
          and(
            eq(schema.syncedTranscriptSegment.startedAt, cursor.startedAt),
            gt(schema.syncedTranscriptSegment.segmentId, cursor.segmentId),
          ),
        )] : []),
      )).orderBy(asc(schema.syncedTranscriptSegment.startedAt), asc(schema.syncedTranscriptSegment.segmentId));
      const rows = await content.read(schema.syncedTranscriptSegment, await (limit === undefined ? query : query.limit(limit)), vaultId);
      return rows.map(({ segmentId, startedAt, endedAt, text, createdAt, audioSource, speakerLabel }) => ({ segmentId, startedAt, endedAt, text, createdAt, audioSource, speakerLabel }));
    },
    async listTranscriptAnalytics(vaultId, meetingId, version) {
      const transcript = await getTranscript(vaultId, meetingId, version);
      if (!transcript) return [];
      const rows = await db.select({
        transcriptId: schema.syncedTranscriptSegment.transcriptId,
        segmentId: schema.syncedTranscriptSegment.segmentId,
        startedAt: schema.syncedTranscriptSegment.startedAt,
        endedAt: schema.syncedTranscriptSegment.endedAt,
        audioSource: schema.syncedTranscriptSegment.audioSource,
        normalizedCharacterCount: schema.syncedTranscriptSegment.normalizedCharacterCount,
      }).from(schema.syncedTranscriptSegment)
        .where(eq(schema.syncedTranscriptSegment.transcriptId, transcript.id))
        .orderBy(asc(schema.syncedTranscriptSegment.startedAt), asc(schema.syncedTranscriptSegment.segmentId));
      const backfilledCounts = new Map<string, number>();
      if (rows.some((row) => row.normalizedCharacterCount === null)) {
        const legacy = await db.select({
          encryptedPayload: schema.syncedTranscriptSegment.encryptedPayload,
          transcriptId: schema.syncedTranscriptSegment.transcriptId,
          segmentId: schema.syncedTranscriptSegment.segmentId,
          text: schema.syncedTranscriptSegment.text,
        }).from(schema.syncedTranscriptSegment).where(and(
          eq(schema.syncedTranscriptSegment.transcriptId, transcript.id),
          isNull(schema.syncedTranscriptSegment.normalizedCharacterCount),
        ));
        const plaintext = await content.read(schema.syncedTranscriptSegment, legacy, vaultId);
        const counts = plaintext.map((row) => ({ ...row, count: normalizedCharacterCount(row.text) }));
        for (const batch of batches(counts, 200)) {
          await db.update(schema.syncedTranscriptSegment).set({
            normalizedCharacterCount: sql<number>`case ${schema.syncedTranscriptSegment.segmentId} ${sql.join(
              batch.map((row) => sql`when ${row.segmentId} then ${row.count}`), sql.raw(" "),
            )} else ${schema.syncedTranscriptSegment.normalizedCharacterCount} end`,
          }).where(and(
            eq(schema.syncedTranscriptSegment.transcriptId, transcript.id),
            inArray(schema.syncedTranscriptSegment.segmentId, batch.map((row) => row.segmentId)),
          ));
        }
        for (const row of counts) backfilledCounts.set(row.segmentId, row.count);
      }
      return rows.map((row) => ({
        segmentId: row.segmentId, startedAt: row.startedAt, endedAt: row.endedAt, audioSource: row.audioSource,
        normalizedCharacterCount: backfilledCounts.get(row.segmentId) ?? row.normalizedCharacterCount!,
      }));
    },
    async listScreenshots(vaultId, meetingId, query, limit, cursor, filters) {
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
        ...(meetingId ? [eq(schema.syncedScreenshot.meetingId, meetingId)] : []),
        searchFilters(vaultId, "screenshot", filters),
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
        return await readScreenshots(await db.select(screenshotSelection(schema)).from(schema.syncedScreenshot).where(filter)
          .orderBy(meetingId ? asc(schema.syncedScreenshot.capturedAt) : desc(schema.syncedScreenshot.capturedAt),
            meetingId ? asc(schema.syncedScreenshot.screenshotId) : desc(schema.syncedScreenshot.screenshotId)).limit(limit));
      }
      const ids = await rankedDocumentIds(vaultId, meetingId, "screenshot", { ...query, filters });
      if (ids.length === 0) return [];
      const rows = await readScreenshots(await db.select(screenshotSelection(schema)).from(schema.syncedScreenshot)
        .where(and(filter, inArray(schema.syncedScreenshot.screenshotId, ids)))
        .orderBy(asc(schema.syncedScreenshot.capturedAt), asc(schema.syncedScreenshot.screenshotId)));
      const rank = new Map(ids.map((id, index) => [id, index]));
      return rows.sort((left, right) => rank.get(left.screenshotId)! - rank.get(right.screenshotId)!).slice(0, limit);
    },
    async searchPermissionTargets(vaultId, query, offset) {
      const [vault] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
        .where(and(adminVault(vaultId), isNull(schema.syncedVault.deletingAt))).limit(1);
      if (!vault) return null;
      const organizations = db.select({ id: schema.member.organizationId }).from(schema.member)
        .where(eq(schema.member.userId, userPrincipalId));
      const pattern = `%${query.toLowerCase().replace(/[\\%_]/g, "\\$&")}%`;
      const matches = (column: AnyColumn) => sql`lower(${column}) like ${pattern} escape '\\'`;
      const organizationsFound = await db.select({ principalId: schema.organization.id, name: schema.organization.name, detail: schema.organization.slug })
        .from(schema.organization).where(and(and(inArray(schema.organization.id, organizations), eq(schema.organization.kind, "team")),
          or(matches(schema.organization.name), matches(schema.organization.slug)))).orderBy(asc(schema.organization.name), asc(schema.organization.id)).limit(51).offset(offset);
      const teamsFound = await db.select({ principalId: schema.team.id, name: schema.team.name, detail: schema.organization.name })
        .from(schema.team).innerJoin(schema.organization, eq(schema.organization.id, schema.team.organizationId))
        .where(and(inArray(schema.team.organizationId, organizations), matches(schema.team.name)))
        .orderBy(asc(schema.team.name), asc(schema.team.id)).limit(51).offset(offset);
      const usersFound = await db.select({ principalId: schema.user.id, name: schema.user.name, detail: schema.user.email }).from(schema.user)
        .where(and(sql`${schema.user.id} <> ${userPrincipalId}`, inArray(schema.user.id,
          db.select({ id: schema.member.userId }).from(schema.member).where(inArray(schema.member.organizationId, organizations))),
          or(matches(schema.user.name), matches(schema.user.email)))).orderBy(asc(schema.user.name), asc(schema.user.id)).limit(51).offset(offset);
      return {
        items: [...organizationsFound.slice(0, 50).map((row) => ({ ...row, principalType: "organization" as const })),
          ...teamsFound.slice(0, 50).map((row) => ({ ...row, principalType: "team" as const })),
          ...usersFound.slice(0, 50).map((row) => ({ ...row, principalType: "user" as const }))],
        nextCursor: [organizationsFound, teamsFound, usersFound].some((rows) => rows.length > 50) ? String(offset + 50) : null,
      };
    },
    async listPermissions(vaultId) {
      const [vault] = await db.select({ role: vaultRole(schema.syncedVault.vaultId) })
        .from(schema.syncedVault).where(and(
          readable(schema.syncedVault.vaultId),
          eq(schema.syncedVault.vaultId, vaultId),
          isNull(schema.syncedVault.deletingAt),
        )).limit(1);
      if (!vault) return null;
      const permissions = await db.select({
        vaultId: schema.syncedVaultPermission.vaultId,
        principalType: schema.syncedVaultPermission.principalType,
        principalId: schema.syncedVaultPermission.principalId,
        role: schema.syncedVaultPermission.role,
        createdAt: schema.syncedVaultPermission.createdAt,
      }).from(schema.syncedVaultPermission).where(and(
        eq(schema.syncedVaultPermission.vaultId, vaultId),
        ...(vault.role === "admin" ? [] : [matchingPrincipal()]),
      ));
      const organizations = db.select({ id: schema.member.organizationId }).from(schema.member).where(eq(schema.member.userId, userPrincipalId));
      const ids = (type: string) => permissions.filter((p) => p.principalType === type).map((p) => p.principalId);
      const [users, orgs, teams] = await Promise.all([
        ids("user").length ? db.select({ id: schema.user.id, name: schema.user.name, detail: schema.user.email }).from(schema.user).where(and(inArray(schema.user.id, ids("user")), inArray(schema.user.id, db.select({ id: schema.member.userId }).from(schema.member).where(inArray(schema.member.organizationId, organizations))))) : [],
        ids("organization").length ? db.select({ id: schema.organization.id, name: schema.organization.name, detail: schema.organization.slug }).from(schema.organization).where(and(inArray(schema.organization.id, ids("organization")), inArray(schema.organization.id, organizations))) : [],
        ids("team").length ? db.select({ id: schema.team.id, name: schema.team.name, detail: schema.organization.name }).from(schema.team).innerJoin(schema.organization, eq(schema.organization.id, schema.team.organizationId)).where(and(inArray(schema.team.id, ids("team")), inArray(schema.team.organizationId, organizations))) : [],
      ]);
      return permissions.map((permission) => {
        const label = (permission.principalType === "user" ? users : permission.principalType === "team" ? teams : orgs).find((p) => p.id === permission.principalId);
        return { ...permission, ...(label ? { name: label.name, detail: label.detail } : {}) } as import("./types").VaultPermissionRecord;
      });
    },
    async putPermission(vaultId, principalType, principalId, role) {
      await lockVault(vaultId);
      const [vault] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
        .innerJoin(schema.organization, eq(schema.organization.id, schema.syncedVault.organizationId))
        .where(and(adminVault(vaultId), eq(schema.organization.kind, "team"), isNull(schema.syncedVault.deletingAt))).limit(1);
      if (!vault) return false;
      const target = principalType === "user" ? schema.user : principalType === "team" ? schema.team : schema.organization;
      const [found] = await db.select({ id: target.id }).from(target).where(and(eq(target.id, principalId),
        principalType === "organization" ? eq(schema.organization.kind, "team") : undefined)).limit(1);
      if (!found) return false;
      await db.insert(schema.syncedVaultPermission).values({ vaultId, principalType, principalId, role, grantedByUserId: userPrincipalId })
        .onConflictDoUpdate({ target: [schema.syncedVaultPermission.vaultId, schema.syncedVaultPermission.principalType, schema.syncedVaultPermission.principalId], set: { role } });
      await validateSharing();
      return true;
    },
    async deletePermission(vaultId, principalType, principalId) {
      await lockVault(vaultId);
      const [vault] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
        .innerJoin(schema.organization, eq(schema.organization.id, schema.syncedVault.organizationId))
        .where(and(adminVault(vaultId), eq(schema.organization.kind, "team"))).limit(1);
      if (!vault) return false;
      const [deleted] = await db.delete(schema.syncedVaultPermission).where(and(
        eq(schema.syncedVaultPermission.vaultId, vaultId), eq(schema.syncedVaultPermission.principalType, principalType),
        eq(schema.syncedVaultPermission.principalId, principalId),
      )).returning({ vaultId: schema.syncedVaultPermission.vaultId });
      await validateSharing();
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
    encryptedPayload: schema.syncedMeeting.encryptedPayload,
    meetingId: schema.syncedMeeting.meetingId,
    vaultId: schema.syncedMeeting.vaultId,
    projectId: schema.syncedMeeting.projectId,
    name: schema.syncedMeeting.name,
    description: schema.syncedMeeting.description,
    status: schema.syncedMeeting.status,
    duration: schema.syncedMeeting.duration,
    recordingStartedAt: schema.syncedMeeting.recordingStartedAt,
    icalUid: schema.syncedMeeting.icalUid,
    recurrenceId: schema.syncedMeeting.recurrenceId,
    calendarEvent: schema.syncedMeeting.calendarEvent,
    isRecording: sql<boolean>`exists (
      select 1 from ${schema.meetingEvent} as started
      where started.vault_id = "meetings"."vault_id"
        and started.meeting_id = "meetings"."meeting_id"
        and started.kind = 'recording_started'
        and started.session_id is not null
        and not exists (
          select 1 from ${schema.meetingEvent} as ended
          where ended.vault_id = started.vault_id and ended.meeting_id = started.meeting_id
            and ended.session_id = started.session_id and ended.kind = 'recording_ended'
        )
    )`.mapWith(Boolean),
    createdAt: schema.syncedMeeting.createdAt,
    updatedAt: schema.syncedMeeting.updatedAt,
    // Keep the outer reference explicit: Drizzle unqualifies column objects in single-table selections.
    summaryTitle: sql<string | null>`(select ${schema.summary.title} from ${schema.summary} where ${schema.summary.meetingId} = "meetings"."meeting_id" order by ${schema.summary.version} desc limit 1)`,
    summaryDocument: sql<string | null>`(select ${schema.summary.document} from ${schema.summary} where ${schema.summary.meetingId} = "meetings"."meeting_id" order by ${schema.summary.version} desc limit 1)`,
    summaryCreatedAt: sql<Date | null>`(select ${schema.summary.createdAt} from ${schema.summary} where ${schema.summary.meetingId} = "meetings"."meeting_id" order by ${schema.summary.version} desc limit 1)`.mapWith(schema.summary.createdAt),
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
