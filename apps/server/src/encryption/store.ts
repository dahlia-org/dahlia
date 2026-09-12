import { and, eq, exists, getTableColumns, getTableName, inArray, type AnyColumn, type SQL } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type * as Schema from "../db/auth-schema";
import { vaultPermissions } from "../auth/vault-permissions";
import { createVaultCipher, EncryptionError, unwrapDataKey, wrapDataKey, type EncryptionConfig, type VaultCipher } from "./crypto";

type ContentSchema = typeof Schema;
type Row = Record<string, unknown>;
type ContentTable = ContentSchema["syncedVault" | "syncedProject" | "syncedMeeting" | "transcript" | "syncedTranscriptSegment" | "transcriptPatchChunk" | "syncedFile" | "syncTransactionReceipt" | "summaryJob" | "summary"];

const policies: Record<string, { ids: string[]; fields: Row; hashes?: string[] }> = {
  vaults: { ids: ["vaultId"], fields: { name: "" } },
  projects: { ids: ["projectId"], fields: { name: "", description: "" } },
  meetings: { ids: ["meetingId"], fields: { name: "", description: "", calendarEvent: null } },
  transcripts: { ids: ["id"], fields: { metadata: null } },
  transcript_segments: { ids: ["transcriptId", "segmentId"], fields: { text: "", speakerLabel: null } },
  transcript_patch_chunks: { ids: ["vaultId", "meetingId", "patchId", "chunkIndex"], fields: { payload: {}, contentHash: "" }, hashes: ["contentHash"] },
  files: { ids: ["fileId"], fields: { name: "", uri: "", metadata: {}, checksum: "" }, hashes: ["checksum"] },
  transaction_receipts: { ids: ["transactionId"], fields: { responseJson: null, requestHash: "" }, hashes: ["requestHash"] },
  jobs_summary: { ids: ["id"], fields: { settings: {}, input: null, transcriptResult: null, inputVersion: "", requestHash: "" }, hashes: ["inputVersion", "requestHash"] },
  summaries: { ids: ["id"], fields: { title: "", document: "", metadata: null } },
};

/** One instance per authorized database transaction; plaintext keys are never persisted. */
export function createContentEncryption(db: NodePgDatabase, schema: ContentSchema, userId: string, config?: EncryptionConfig, canRead?: (vault: AnyColumn) => SQL | undefined, maintenance?: "receipt" | "retention" | "governance") {
  const keys = new Map<string, Promise<VaultCipher | null>>();
  async function load(vaultId: string): Promise<VaultCipher | null> {
    const readAccess = canRead ?? (maintenance ? () => undefined : vaultPermissions(db, schema, userId).read);
    const [vault] = await db.select({ encryption: schema.syncedVault.encryption }).from(schema.syncedVault)
      .where(and(eq(schema.syncedVault.vaultId, vaultId), readAccess(schema.syncedVault.vaultId))).limit(1);
    if (vault?.encryption === "none") return null;
    if (!vault && !maintenance) return null;
    const [record] = await db.select().from(schema.vaultKey).where(and(eq(schema.vaultKey.vaultId, vaultId),
      maintenance === "receipt" ? exists(db.select({ id: schema.syncTransactionReceipt.transactionId }).from(schema.syncTransactionReceipt)
        .where(and(eq(schema.syncTransactionReceipt.vaultId, vaultId), eq(schema.syncTransactionReceipt.ownerUserId, userId)))) : undefined)).limit(1);
    if (!record && !vault) return null;
    if (!record) throw new EncryptionError();
    const raw = await unwrapDataKey(config, vaultId, record.wrappedKey);
    try { return await createVaultCipher(vaultId, raw); }
    finally { raw.fill(0); }
  }
  function cipher(vaultId: string) {
    if (!keys.has(vaultId)) keys.set(vaultId, load(vaultId));
    return keys.get(vaultId)!;
  }
  async function vaultFor(row: Row): Promise<string> {
    if (typeof row.vaultId === "string") return row.vaultId;
    if (typeof row.meetingId === "string") {
      const [meeting] = await db.select({ vaultId: schema.syncedMeeting.vaultId }).from(schema.syncedMeeting)
        .where(eq(schema.syncedMeeting.meetingId, row.meetingId)).limit(1);
      if (meeting) return meeting.vaultId;
    }
    if (typeof row.transcriptId === "string") {
      const [transcript] = await db.select({ meetingId: schema.transcript.meetingId }).from(schema.transcript)
        .where(eq(schema.transcript.id, row.transcriptId)).limit(1);
      if (transcript) return vaultFor(transcript);
    }
    throw new EncryptionError();
  }
  // Persisted AAD and HMAC purposes must survive physical table renames in either dialect.
  const encryptionName = (table: ContentTable) => table === schema.summaryJob ? "jobs_summary" : getTableName(table);
  function identity(table: ContentTable, row: Row) {
    const policy = policies[encryptionName(table)]!;
    if (policy.ids.some((id) => row[id] === undefined)) throw new EncryptionError();
    return JSON.stringify(policy.ids.map((id) => row[id]));
  }
  async function read<T extends Row>(table: ContentTable, rows: T[], vaultId?: string): Promise<T[]> {
    if (maintenance && table !== schema.syncTransactionReceipt && !(maintenance === "governance" && table === schema.syncedVault)) throw new EncryptionError();
    const result: T[] = [];
    for (const row of rows) {
      const { encryptedPayload, ...plain } = row;
      const key = await cipher(vaultId ?? await vaultFor(row));
      if (key) {
        if (typeof encryptedPayload !== "string") throw new EncryptionError();
        const fields = await key.decrypt<Row>(encryptionName(table), identity(table, row), "content", encryptedPayload);
        for (const field of Object.keys(policies[encryptionName(table)]!.fields)) {
          if (field in plain && field in fields) plain[field as keyof typeof plain] = fields[field] as never;
        }
      } else if (encryptedPayload) throw new EncryptionError();
      result.push(plain as T);
    }
    return result;
  }
  async function write<T extends Row>(table: ContentTable, values: T, keyFields: Row = {}): Promise<T & { encryptedPayload?: string | null }> {
    if (maintenance === "receipt" || ((maintenance === "retention" || maintenance === "governance") && table !== schema.syncTransactionReceipt)) throw new EncryptionError();
    const context = { ...keyFields, ...values };
    const tableName = encryptionName(table);
    const policy = policies[tableName]!;
    const vaultId = await vaultFor(context);
    const key = await cipher(vaultId);
    if (!key) return { ...values, encryptedPayload: undefined };
    let previous: Row = {};
    // Fully supplied protected fields need no preservation read, including segment upserts and copies.
    if (Object.keys(policy.fields).some((field) => values[field] === undefined)) {
      const columns = getTableColumns(table) as Record<string, AnyColumn>;
      let sameVault: SQL;
      if (columns.vaultId) {
        sameVault = eq(columns.vaultId, vaultId);
      } else if (columns.meetingId) {
        sameVault = inArray(columns.meetingId, db.select({ id: schema.syncedMeeting.meetingId }).from(schema.syncedMeeting)
          .where(eq(schema.syncedMeeting.vaultId, vaultId)));
      } else {
        sameVault = inArray(columns.transcriptId!, db.select({ id: schema.transcript.id }).from(schema.transcript)
          .innerJoin(schema.syncedMeeting, eq(schema.syncedMeeting.meetingId, schema.transcript.meetingId))
          .where(eq(schema.syncedMeeting.vaultId, vaultId)));
      }
      // Preserve omitted fields only within this Vault; ID collisions follow the caller's normal conflict handling.
      const [existing] = await db.select().from(table).where(and(sameVault, ...policy.ids.map((id) => eq(columns[id]!, context[id])))).limit(1);
      previous = existing ? (await read(table, [{ ...existing, ...keyFields }], vaultId))[0]! : {};
    }
    const fields = Object.fromEntries(Object.entries(policy.fields).map(([field, fallback]) => [field,
      values[field] !== undefined ? values[field] : previous[field] ?? fallback]));
    const masked: Row = { ...values };
    for (const [field, fallback] of Object.entries(policy.fields)) {
      masked[field] = typeof fields[field] === "string" && fallback !== null && typeof fallback === "object" ? JSON.stringify(fallback) : fallback;
      if (policy.hashes?.includes(field)) masked[field] = await key.hash(`${tableName}.${field}`, String(fields[field]));
    }
    switch (tableName) {
      case "transaction_receipts":
        if (fields.responseJson === null) masked.responseJson = null;
        else masked.responseJson = typeof fields.responseJson === "string" ? "{}" : {};
        break;
      case "files":
        masked.metadata = { source: (fields.metadata as Row).source };
        break;
    }
    masked.encryptedPayload = await key.encrypt(tableName, identity(table, context), "content", fields);
    return masked as T & { encryptedPayload: string };
  }
  return {
    cipher, read, write,
    async writeMany<T extends Row>(table: ContentTable, rows: T[], keyFields: Row = {}) {
      const result: Array<T & { encryptedPayload?: string | null }> = [];
      for (const row of rows) result.push(await write(table, row, keyFields));
      return result;
    },
    async create(vaultId: string) {
      if (!config || maintenance) throw new EncryptionError();
      const [vault] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
        .where(and(eq(schema.syncedVault.vaultId, vaultId), vaultPermissions(db, schema, userId).write(schema.syncedVault.vaultId))).limit(1);
      if (!vault) throw new EncryptionError();
      const raw = crypto.getRandomValues(new Uint8Array(32));
      try {
        await db.insert(schema.vaultKey).values({ vaultId, wrappedKey: await wrapDataKey(config, vaultId, raw) });
        const created = await createVaultCipher(vaultId, raw);
        keys.set(vaultId, Promise.resolve(created));
      } finally { raw.fill(0); }
    },
  };
}
