import { and, asc, eq, gt, inArray, isNull, lte, sql, type AnyColumn, type SQL } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type * as Schema from "../db/auth-schema";
import type { Identity } from "../auth/identity";
import type { createContentEncryption } from "../encryption/store";
import { RequestError } from "../storage/upload";
import { uuidV7 } from "../id";
import { DocumentCore, documentStateLimit, emptyDocumentUpdate, removedBlocks, type DocumentRecovery } from "./core";
import { documentRecoveryPageBytes } from "./model";

type DocumentRow = typeof Schema.document.$inferSelect;
export type SharedDocument = Pick<DocumentRow, "id" | "workspaceId" | "meetingId" | "schemaVersion" | "generation" | "revision" | "text" | "createdAt" | "updatedAt"> & { checkpoint: string };
export interface DocumentExchangeRequest { generation: string; vector: string; update?: string }
export interface DocumentStore {
  documentHead(workspaceId: string, id: string): Promise<{ generation: string; revision: number } | null>;
  getDocument(workspaceId: string, id: string): Promise<SharedDocument | null>;
  listDocuments(workspaceId: string, after?: string): Promise<{ items: { id: string; revision: number; generation: string }[]; nextCursor: string | null }>;
  initializeDocument(workspaceId: string, id: string, legacyUpdate?: string): Promise<SharedDocument>;
  exchangeDocument(workspaceId: string, id: string, request: DocumentExchangeRequest): Promise<{ generation: string; revision: number; update: string }>;
  documentRecoveries(workspaceId: string, id: string, after?: string): Promise<{ items: (DocumentRecovery & { createdAt: Date })[]; nextCursor: string | null }>;
  saveDocumentRecovery(workspaceId: string, id: string, recovery: DocumentRecovery): Promise<void>;
  documentPresence(workspaceId: string, id: string, sessionId?: string): Promise<{ userId: string; name: string }[]>;
}

/** Instantiated inside the existing identity transaction, for both SQL adapters. */
export function createDocumentStore(db: NodePgDatabase, schema: typeof Schema, identity: Identity,
  content: ReturnType<typeof createContentEncryption>, lockWorkspace: (id: string) => Promise<void>,
  access: { read: (column: AnyColumn) => SQL | undefined; write: (column: AnyColumn) => SQL | undefined },
): DocumentStore {
  async function authorize(workspaceId: string, id: string, write = false) {
    await lockWorkspace(workspaceId);
    if (write && identity.impersonated) throw new RequestError(403, "impersonation_read_only");
    const meeting = schema.syncedMeeting;
    const [parent] = await db.select({ id: meeting.meetingId }).from(meeting)
      .innerJoin(schema.syncedWorkspace, eq(schema.syncedWorkspace.workspaceId, meeting.workspaceId))
      .where(and(eq(meeting.meetingId, id), eq(meeting.workspaceId, workspaceId), eq(meeting.active, true),
        isNull(meeting.deletedAt), isNull(meeting.deletingAt), isNull(schema.syncedWorkspace.deletingAt),
        (write ? access.write : access.read)(meeting.workspaceId))).limit(1);
    if (!parent) throw new RequestError(404, "document_unavailable");
  }
  async function load(workspaceId: string, id: string) {
    const table = schema.document;
    const [row] = await content.read(table, await db.select().from(table).where(and(eq(table.id, id), eq(table.workspaceId, workspaceId))));
    if (!row) return null;
    const core = new DocumentCore(row.checkpoint);
    try {
      const updates = await content.read(schema.documentUpdate, await db.select().from(schema.documentUpdate).where(and(
        eq(schema.documentUpdate.documentId, id), eq(schema.documentUpdate.workspaceId, workspaceId),
        gt(schema.documentUpdate.revision, row.checkpointRevision), lte(schema.documentUpdate.revision, row.revision),
      )).orderBy(asc(schema.documentUpdate.revision)));
      if (updates.length !== row.revision - row.checkpointRevision || row.projectionRevision !== row.revision) throw new RequestError(503, "document_projection_pending");
      for (const update of updates) core.apply(update.update);
      return { row, core };
    } catch (error) { core.destroy(); throw error; }
  }
  const shared = (row: DocumentRow, core: DocumentCore): SharedDocument => ({ id: row.id, workspaceId: row.workspaceId,
    meetingId: row.meetingId, schemaVersion: row.schemaVersion, generation: row.generation, revision: row.revision,
    text: row.text, checkpoint: core.checkpoint(), createdAt: row.createdAt, updatedAt: row.updatedAt });
  async function recordRecovery(workspaceId: string, id: string, recovery: DocumentRecovery) {
    const table = schema.documentRecovery;
    const inserted = await db.insert(table).values(await content.write(table,
      { ...recovery, documentId: id, workspaceId, createdAt: new Date() })).onConflictDoNothing().returning({ id: table.id });
    if (!inserted.length) {
      const [existing] = await content.read(table, await db.select().from(table).where(and(eq(table.id, recovery.id), eq(table.documentId, id), eq(table.workspaceId, workspaceId))));
      if (!existing || existing.reason !== recovery.reason || JSON.stringify(existing.blocks) !== JSON.stringify(recovery.blocks)) {
        throw new RequestError(409, "document_recovery_id_reused");
      }
    }
  }
  function validProjection(core: DocumentCore) {
    try {
      if (core.stateBytes() > documentStateLimit) throw new Error("document_too_large");
      return core.projection();
    }
    catch { throw new RequestError(400, "invalid_document_content"); }
  }
  return {
    async documentHead(workspaceId, id) {
      await authorize(workspaceId, id);
      const [row] = await db.select({ generation: schema.document.generation, revision: schema.document.revision }).from(schema.document)
        .where(and(eq(schema.document.workspaceId, workspaceId), eq(schema.document.id, id)));
      return row ?? null;
    },
    async getDocument(workspaceId, id) {
      await authorize(workspaceId, id);
      const loaded = await load(workspaceId, id);
      if (!loaded) return null;
      try { return shared(loaded.row, loaded.core); } finally { loaded.core.destroy(); }
    },
    async listDocuments(workspaceId, after) {
      const table = schema.document, meeting = schema.syncedMeeting;
      const rows = await db.select({ id: table.id, revision: table.revision, generation: table.generation }).from(table)
        .innerJoin(meeting, eq(meeting.meetingId, table.meetingId))
        .innerJoin(schema.syncedWorkspace, eq(schema.syncedWorkspace.workspaceId, table.workspaceId))
        .where(and(eq(table.workspaceId, workspaceId), eq(meeting.workspaceId, workspaceId), access.read(table.workspaceId),
          isNull(schema.syncedWorkspace.deletingAt), isNull(meeting.deletedAt), isNull(meeting.deletingAt), eq(meeting.active, true), after ? gt(table.id, after) : undefined))
        .orderBy(asc(table.id)).limit(101);
      return { items: rows.slice(0, 100), nextCursor: rows.length > 100 ? rows[99]!.id : null };
    },
    async initializeDocument(workspaceId, id, legacyUpdate) {
      await authorize(workspaceId, id, true);
      const existing = await load(workspaceId, id);
      if (existing) {
        try {
          if (legacyUpdate) {
            let imported: DocumentCore;
            try { imported = new DocumentCore(legacyUpdate); } catch { throw new RequestError(400, "invalid_document_content"); }
            try {
              validProjection(imported);
              if (emptyDocumentUpdate(imported.difference(existing.core.vector()))) return shared(existing.row, existing.core);
            } finally { imported.destroy(); }
          }
          // An imported empty paragraph still has CRDT history. Never seed twice, even after deletion.
          if (legacyUpdate && existing.row.revision !== 0) throw new RequestError(409, "document_already_initialized");
          if (!legacyUpdate) return shared(existing.row, existing.core);
        } finally { existing.core.destroy(); }
      }
      const core = new DocumentCore();
      try {
        if (legacyUpdate) {
          try { core.apply(legacyUpdate); validProjection(core); core.repairBlockIDs(uuidV7); }
          catch { throw new RequestError(400, "invalid_document_content"); }
        }
        const now = new Date(), revision = legacyUpdate ? 1 : 0;
        const row = { id, workspaceId, meetingId: id, schemaVersion: 1, generation: existing?.row.generation ?? uuidV7(),
          revision, checkpointRevision: revision, projectionRevision: revision, checkpoint: core.checkpoint(),
          text: validProjection(core).text, createdAt: existing?.row.createdAt ?? now, updatedAt: now, encryptedPayload: null };
        const values = await content.write(schema.document, row);
        if (existing) await db.update(schema.document).set(values).where(eq(schema.document.id, id));
        else await db.insert(schema.document).values(values);
        return shared(row, core);
      } finally { core.destroy(); }
    },
    async exchangeDocument(workspaceId, id, request) {
      await authorize(workspaceId, id, request.update !== undefined);
      const loaded = await load(workspaceId, id);
      if (!loaded) throw new RequestError(404, "document_unavailable");
      const { row, core } = loaded;
      try {
        if (request.generation !== row.generation) throw new RequestError(409, "document_generation_changed");
        const before = validProjection(core), checkpoint = core.checkpoint(), vector = core.vector();
        let difference: string;
        try {
          if (request.update) { core.apply(request.update); validProjection(core); core.repairBlockIDs(uuidV7); }
          difference = core.difference(request.vector);
        } catch { throw new RequestError(400, "invalid_document_update"); }
        if (request.update && core.checkpoint() !== checkpoint) {
          const projection = validProjection(core), revision = row.revision + 1;
          const blocks = removedBlocks(before, projection);
          if (blocks.length) await recordRecovery(workspaceId, id, { id: uuidV7(), reason: "deleted", blocks });
          const now = new Date();
          await db.insert(schema.documentUpdate).values(await content.write(schema.documentUpdate,
            { documentId: id, workspaceId, revision, update: core.difference(vector), createdAt: now }));
          const compact = revision - row.checkpointRevision >= 32;
          await db.update(schema.document).set(await content.write(schema.document,
            { revision, projectionRevision: revision, text: projection.text, updatedAt: now,
              ...(compact ? { checkpoint: core.checkpoint(), checkpointRevision: revision } : {}) }, { id, workspaceId }))
            .where(eq(schema.document.id, id));
          if (compact) await db.delete(schema.documentUpdate).where(and(eq(schema.documentUpdate.documentId, id), lte(schema.documentUpdate.revision, revision)));
          row.revision = revision;
        }
        return { generation: row.generation, revision: row.revision, update: difference };
      } finally { core.destroy(); }
    },
    async documentRecoveries(workspaceId, id, after) {
      await authorize(workspaceId, id);
      const table = schema.documentRecovery;
      // Select a bounded payload before reading/decrypting it. Four bytes per SQL
      // character conservatively covers UTF-8 in both dialects and encrypted JSON.
      const candidates = await db.select({ id: table.id,
        bytes: sql<number>`4 * (length(cast(${table.blocks} as text)) + coalesce(length(${table.encryptedPayload}), 0)) + 256`,
      }).from(table).where(and(eq(table.documentId, id), eq(table.workspaceId, workspaceId),
        after ? gt(table.id, after) : undefined)).orderBy(asc(table.id)).limit(101);
      const selected: string[] = [];
      let bytes = 128;
      for (const candidate of candidates) {
        // A single legal record must make progress even above the usual page budget.
        if (selected.length && (selected.length >= 100 || bytes + Number(candidate.bytes) > documentRecoveryPageBytes)) break;
        selected.push(candidate.id); bytes += Number(candidate.bytes);
      }
      const rows = selected.length ? await content.read(table, await db.select().from(table).where(and(
        eq(table.documentId, id), eq(table.workspaceId, workspaceId), inArray(table.id, selected),
      )).orderBy(asc(table.id))) : [];
      return { items: rows.map(({ id, blocks, reason, createdAt }) => ({ id, blocks, reason, createdAt })),
        nextCursor: candidates.length > selected.length ? selected.at(-1)! : null };
    },
    async saveDocumentRecovery(workspaceId, id, recovery) {
      await authorize(workspaceId, id, true);
      const loaded = await load(workspaceId, id);
      if (!loaded) throw new RequestError(404, "document_unavailable");
      loaded.core.destroy();
      await recordRecovery(workspaceId, id, recovery);
    },
    async documentPresence(workspaceId, id, sessionId) {
      await authorize(workspaceId, id, sessionId !== undefined);
      const table = schema.documentPresence, now = new Date();
      await db.delete(table).where(and(eq(table.workspaceId, workspaceId), lte(table.expiresAt, now)));
      if (sessionId) await db.insert(table).values({ id: sessionId, workspaceId, documentId: id, userId: identity.userId, expiresAt: new Date(now.getTime() + 15_000) })
        .onConflictDoUpdate({ target: table.id, set: { expiresAt: new Date(now.getTime() + 15_000) },
          setWhere: and(eq(table.userId, identity.userId), eq(table.documentId, id), eq(table.workspaceId, workspaceId)) });
      const rows = await db.selectDistinct({ userId: table.userId, name: schema.user.name }).from(table)
        .innerJoin(schema.user, eq(schema.user.id, table.userId)).where(and(eq(table.workspaceId, workspaceId), eq(table.documentId, id), gt(table.expiresAt, now)));
      return rows;
    },
  };
}
