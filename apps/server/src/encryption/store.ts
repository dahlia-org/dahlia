import { and, eq, exists, getTableColumns, getTableName, inArray, type AnyColumn, type SQL } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type * as Schema from "../db/auth-schema";
import { workspacePermissions } from "../auth/workspace-permissions";
import { createWorkspaceCipher, EncryptionError, unwrapDataKey, wrapDataKey, type EncryptionConfig, type WorkspaceCipher } from "./crypto";

type ContentSchema = typeof Schema;
type Row = Record<string, unknown>;
type ContentTable = ContentSchema["syncedWorkspace" | "syncedProject" | "syncedMeeting" | "transcript" | "syncedTranscriptSegment" | "transcriptPatchChunk" | "syncedFile" | "syncTransactionReceipt" | "summaryJob" | "summary"];

const policies: Record<string, { ids: string[]; fields: Row; hashes?: string[] }> = {
  workspaces: { ids: ["workspaceId"], fields: { name: "" } },
  projects: { ids: ["projectId"], fields: { name: "", description: "" } },
  meetings: { ids: ["meetingId"], fields: { name: "", description: "", calendarEvent: null } },
  transcripts: { ids: ["id"], fields: { metadata: null } },
  transcript_segments: { ids: ["transcriptId", "segmentId"], fields: { text: "", speakerLabel: null } },
  transcript_patch_chunks: { ids: ["workspaceId", "meetingId", "patchId", "chunkIndex"], fields: { payload: {}, contentHash: "" }, hashes: ["contentHash"] },
  files: { ids: ["fileId"], fields: { name: "", uri: "", metadata: {}, checksum: "" }, hashes: ["checksum"] },
  transaction_receipts: { ids: ["transactionId"], fields: { responseJson: null, requestHash: "" }, hashes: ["requestHash"] },
  jobs_summary: { ids: ["id"], fields: { settings: {}, input: null, transcriptResult: null, inputVersion: "", requestHash: "" }, hashes: ["inputVersion", "requestHash"] },
  summaries: { ids: ["id"], fields: { title: "", document: "", metadata: null } },
};

/** One instance per authorized database transaction; plaintext keys are never persisted. */
export function createContentEncryption(db: NodePgDatabase, schema: ContentSchema, userId: string, config?: EncryptionConfig, canRead?: (workspace: AnyColumn) => SQL | undefined, maintenance?: "receipt" | "retention" | "governance") {
  const keys = new Map<string, Promise<WorkspaceCipher | null>>();
  async function load(workspaceId: string): Promise<WorkspaceCipher | null> {
    const readAccess = canRead ?? (maintenance ? () => undefined : workspacePermissions(db, schema, userId).read);
    const [workspace] = await db.select({ encryption: schema.syncedWorkspace.encryption }).from(schema.syncedWorkspace)
      .where(and(eq(schema.syncedWorkspace.workspaceId, workspaceId), readAccess(schema.syncedWorkspace.workspaceId))).limit(1);
    if (workspace?.encryption === "none") return null;
    if (!workspace && !maintenance) return null;
    const [record] = await db.select().from(schema.workspaceKey).where(and(eq(schema.workspaceKey.workspaceId, workspaceId),
      maintenance === "receipt" ? exists(db.select({ id: schema.syncTransactionReceipt.transactionId }).from(schema.syncTransactionReceipt)
        .where(and(eq(schema.syncTransactionReceipt.workspaceId, workspaceId), eq(schema.syncTransactionReceipt.ownerUserId, userId)))) : undefined)).limit(1);
    if (!record && !workspace) return null;
    if (!record) throw new EncryptionError();
    const raw = await unwrapDataKey(config, workspaceId, record.wrappedKey);
    try { return await createWorkspaceCipher(workspaceId, raw); }
    finally { raw.fill(0); }
  }
  function cipher(workspaceId: string) {
    if (!keys.has(workspaceId)) keys.set(workspaceId, load(workspaceId));
    return keys.get(workspaceId)!;
  }
  async function workspaceFor(row: Row): Promise<string> {
    if (typeof row.workspaceId === "string") return row.workspaceId;
    if (typeof row.meetingId === "string") {
      const [meeting] = await db.select({ workspaceId: schema.syncedMeeting.workspaceId }).from(schema.syncedMeeting)
        .where(eq(schema.syncedMeeting.meetingId, row.meetingId)).limit(1);
      if (meeting) return meeting.workspaceId;
    }
    if (typeof row.transcriptId === "string") {
      const [transcript] = await db.select({ meetingId: schema.transcript.meetingId }).from(schema.transcript)
        .where(eq(schema.transcript.id, row.transcriptId)).limit(1);
      if (transcript) return workspaceFor(transcript);
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
  async function read<T extends Row>(table: ContentTable, rows: T[], workspaceId?: string): Promise<T[]> {
    if (maintenance && table !== schema.syncTransactionReceipt && !(maintenance === "governance" && table === schema.syncedWorkspace)) throw new EncryptionError();
    const result: T[] = [];
    for (const row of rows) {
      const { encryptedPayload, ...plain } = row;
      const key = await cipher(workspaceId ?? await workspaceFor(row));
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
    const workspaceId = await workspaceFor(context);
    const key = await cipher(workspaceId);
    if (!key) return { ...values, encryptedPayload: undefined };
    let previous: Row = {};
    // Fully supplied protected fields need no preservation read, including segment upserts and copies.
    if (Object.keys(policy.fields).some((field) => values[field] === undefined)) {
      const columns = getTableColumns(table) as Record<string, AnyColumn>;
      let sameWorkspace: SQL;
      if (columns.workspaceId) {
        sameWorkspace = eq(columns.workspaceId, workspaceId);
      } else if (columns.meetingId) {
        sameWorkspace = inArray(columns.meetingId, db.select({ id: schema.syncedMeeting.meetingId }).from(schema.syncedMeeting)
          .where(eq(schema.syncedMeeting.workspaceId, workspaceId)));
      } else {
        sameWorkspace = inArray(columns.transcriptId!, db.select({ id: schema.transcript.id }).from(schema.transcript)
          .innerJoin(schema.syncedMeeting, eq(schema.syncedMeeting.meetingId, schema.transcript.meetingId))
          .where(eq(schema.syncedMeeting.workspaceId, workspaceId)));
      }
      // Preserve omitted fields only within this Workspace; ID collisions follow the caller's normal conflict handling.
      const [existing] = await db.select().from(table).where(and(sameWorkspace, ...policy.ids.map((id) => eq(columns[id]!, context[id])))).limit(1);
      previous = existing ? (await read(table, [{ ...existing, ...keyFields }], workspaceId))[0]! : {};
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
    async create(workspaceId: string) {
      if (!config || maintenance) throw new EncryptionError();
      const [workspace] = await db.select({ id: schema.syncedWorkspace.workspaceId }).from(schema.syncedWorkspace)
        .where(and(eq(schema.syncedWorkspace.workspaceId, workspaceId), workspacePermissions(db, schema, userId).write(schema.syncedWorkspace.workspaceId))).limit(1);
      if (!workspace) throw new EncryptionError();
      const raw = crypto.getRandomValues(new Uint8Array(32));
      try {
        await db.insert(schema.workspaceKey).values({ workspaceId, wrappedKey: await wrapDataKey(config, workspaceId, raw) });
        const created = await createWorkspaceCipher(workspaceId, raw);
        keys.set(workspaceId, Promise.resolve(created));
      } finally { raw.fill(0); }
    },
  };
}
