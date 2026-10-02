import type { SyncLocks } from "../sync/locks";
import { and, asc, desc, lt, eq, gt, inArray, isNull, lte, or, sql, type AnyColumn, type SQL } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type * as Schema from "../db/auth-schema";
import type { Identity } from "../auth/identity";
import type { createContentEncryption } from "../encryption/store";
import { RequestError } from "../storage/upload";
import { uuidV7 } from "../id";
import { DocumentCore, decodeBinary, encodeBinary, documentSchemaVersion, documentStateLimit, emptyDocumentUpdate, type DocumentRecovery } from "./core";
import { documentRecoveryPageBytes } from "./model";

type DocumentRow = typeof Schema.document.$inferSelect;
export type SharedDocument = Pick<DocumentRow, "id" | "workspaceId" | "meetingId" | "kind" | "title" | "schemaVersion" | "generation" | "revision" | "text" | "createdAt" | "updatedAt"> & { checkpoint: string };
export interface DocumentExchangeRequest { generation: string; vector: string; update?: string }
export interface DocumentMetadata { meetingId: string | null; kind: "notes" | "summary" | "general"; title: string; legacyUpdate?: string }
export interface DocumentStore {
  notesHeads(targets: { workspaceId: string; meetingId: string }[]): Promise<{ workspaceId: string; meetingId: string; id: string | null; generation: string | null; revision: number | null }[]>;
  getMeetingNotes(workspaceId: string, meetingId: string): Promise<SharedDocument | null>;
  initializeMeetingNotes(workspaceId: string, meetingId: string, proposedId: string, legacyUpdate?: string): Promise<SharedDocument>;
  documentHead(workspaceId: string, id: string): Promise<{ generation: string; revision: number } | null>;
  getDocument(workspaceId: string, id: string): Promise<SharedDocument | null>;
  listDocuments(workspaceId: string, after?: string): Promise<{ items: { id: string; meetingId: string | null; kind: DocumentMetadata["kind"]; revision: number; generation: string }[]; nextCursor: string | null }>;
  initializeDocument(workspaceId: string, id: string, metadata: DocumentMetadata): Promise<SharedDocument>;
  exchangeDocument(workspaceId: string, id: string, request: DocumentExchangeRequest): Promise<{ accepted: boolean; reason?: "document_too_large"; generation: string; revision: number; vector: string; update: string }>;
  documentRecoveries(workspaceId: string, id: string, after?: string, mode?: "sync" | "display"): Promise<{ items: (DocumentRecovery & { sequence: number; createdAt: Date })[]; nextCursor: string | null; cursor: string }>;
  saveDocumentRecovery(workspaceId: string, id: string, recovery: DocumentRecovery): Promise<void>;
  documentPresence(workspaceId: string, id: string, sessionId?: string): Promise<{ userId: string; name: string }[]>;
}

/** Instantiated inside the existing identity transaction, for both SQL adapters. */
export function createDocumentStore(db: NodePgDatabase, schema: typeof Schema, identity: Identity,
  content: ReturnType<typeof createContentEncryption>, lockWorkspace: (id: string) => Promise<void>,
  access: { read: (column: AnyColumn) => SQL | undefined; write: (column: AnyColumn) => SQL | undefined },
  locks: SyncLocks,
  deletionGraceHours = 24,
): DocumentStore {
  async function authorizeParent(workspaceId: string, meetingId: string | null, write = false) {
    await lockWorkspace(workspaceId);
    if (write && identity.impersonated) throw new RequestError(403, "impersonation_read_only");
    const workspace = schema.syncedWorkspace;
    const [allowed] = await db.select({ id: workspace.workspaceId }).from(workspace).where(and(
      eq(workspace.workspaceId, workspaceId), isNull(workspace.deletingAt),
      (write ? access.write : access.read)(workspace.workspaceId),
    )).limit(1);
    if (!allowed) throw new RequestError(404, "document_unavailable");
    if (meetingId === null) return;
    const meeting = schema.syncedMeeting;
    const [parent] = await db.select({ id: meeting.meetingId }).from(meeting).where(and(
      eq(meeting.meetingId, meetingId), eq(meeting.workspaceId, workspaceId), eq(meeting.active, true),
      isNull(meeting.deletedAt), isNull(meeting.deletingAt),
    )).limit(1);
    if (!parent) throw new RequestError(404, "document_unavailable");
  }
  async function authorize(workspaceId: string, id: string, write = false) {
    await authorizeParent(workspaceId, null, write);
    await locks.document(id, write ? "exclusive" : "shared");
    const [row] = await db.select({ meetingId: schema.document.meetingId }).from(schema.document)
      .where(and(eq(schema.document.id, id), eq(schema.document.workspaceId, workspaceId))).limit(1);
    if (!row) throw new RequestError(404, "document_unavailable");
    if (row.meetingId) await authorizeParent(workspaceId, row.meetingId, write);
  }
  async function notesID(workspaceId: string, meetingId: string) {
    const table = schema.document;
    const [row] = await db.select({ id: table.id }).from(table).where(and(
      eq(table.workspaceId, workspaceId), eq(table.meetingId, meetingId), eq(table.kind, "notes"),
    )).limit(1);
    return row?.id;
  }
  async function load(workspaceId: string, id: string) {
    const table = schema.document;
    const [row] = await content.read(table, await db.select().from(table).where(and(eq(table.id, id), eq(table.workspaceId, workspaceId))));
    if (!row) return null;
    if (row.schemaVersion !== documentSchemaVersion) throw new RequestError(422, "unsupported_document_schema");
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
    meetingId: row.meetingId, kind: row.kind, title: row.title, schemaVersion: documentSchemaVersion, generation: row.generation, revision: row.revision,
    text: row.text, checkpoint: core.checkpoint(), createdAt: row.createdAt, updatedAt: row.updatedAt });
  async function recordRecovery(workspaceId: string, id: string, recovery: DocumentRecovery) {
    const table = schema.documentRecovery;
    const [head] = await db.select({ sequence: sql<number>`coalesce(max(${table.sequence}), 0)` }).from(table).where(eq(table.documentId, id));
    const inserted = await db.insert(table).values(await content.write(table,
      { ...recovery, sequence: Number(head!.sequence) + 1, documentId: id, workspaceId, createdAt: new Date() })).onConflictDoNothing().returning({ id: table.id });
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
    catch (error) { throw documentError(error, "invalid_document_content"); }
  }
  function documentError(error: unknown, fallback = "invalid_document_update") {
    const code = error instanceof Error ? error.message : fallback;
    return new RequestError(code === "unsupported_document_schema" ? 422 : 400,
      ["unsupported_document_schema", "invalid_document_update", "document_too_large"].includes(code) ? code : fallback);
  }
  async function initializeDocument(workspaceId: string, id: string, metadata: DocumentMetadata) {
    const { meetingId, kind, title, legacyUpdate } = metadata;
    if (kind === "notes" && !meetingId) throw new RequestError(400, "document_notes_require_meeting");
    await authorizeParent(workspaceId, meetingId, true);
    if (kind === "notes" && meetingId) await locks.notes(meetingId, "exclusive");
    await locks.document(id, "exclusive");
    const existing = await load(workspaceId, id);
    if (existing) {
      if (existing.row.meetingId !== meetingId || existing.row.kind !== kind) { existing.core.destroy(); throw new RequestError(409, "document_identity_conflict"); }
      try {
        if (legacyUpdate) {
          let imported: DocumentCore;
          try { imported = new DocumentCore(legacyUpdate); } catch (error) { throw documentError(error, "invalid_document_content"); }
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
        try { core.apply(legacyUpdate); validProjection(core); }
        catch (error) { throw documentError(error, "invalid_document_content"); }
      }
      const now = new Date(), revision = legacyUpdate ? 1 : 0;
      const row = { id, workspaceId, meetingId, kind, title: existing?.row.title ?? title, schemaVersion: documentSchemaVersion, generation: existing?.row.generation ?? uuidV7(),
        revision, checkpointRevision: revision, projectionRevision: revision, checkpoint: core.checkpoint(),
        text: validProjection(core).text, createdAt: existing?.row.createdAt ?? now, updatedAt: now, encryptedPayload: null };
      const values = await content.write(schema.document, row);
      if (existing) await db.update(schema.document).set(values).where(eq(schema.document.id, id));
      else {
        const inserted = await db.insert(schema.document).values(values).onConflictDoNothing().returning({ id: schema.document.id });
        if (!inserted.length) throw new RequestError(409, "document_identity_conflict");
      }
      return shared(row, core);
    } finally { core.destroy(); }
  }
  return {
    async notesHeads(targets) {
      if (!targets.length) return [];
      const meeting = schema.syncedMeeting, workspace = schema.syncedWorkspace, document = schema.document;
      for (const id of [...new Set(targets.map((target) => target.workspaceId))].sort()) await lockWorkspace(id);
      // One bounded metadata query; no checkpoint decoding or writes.
      return db.select({ workspaceId: meeting.workspaceId, meetingId: meeting.meetingId,
        id: document.id, generation: document.generation, revision: document.revision }).from(meeting)
        .innerJoin(workspace, eq(workspace.workspaceId, meeting.workspaceId))
        .leftJoin(document, and(eq(document.workspaceId, meeting.workspaceId), eq(document.meetingId, meeting.meetingId), eq(document.kind, "notes")))
        .where(and(or(...targets.map((target) => and(eq(meeting.workspaceId, target.workspaceId), eq(meeting.meetingId, target.meetingId)))),
          access.read(workspace.workspaceId), isNull(workspace.deletingAt), eq(meeting.active, true), isNull(meeting.deletedAt), isNull(meeting.deletingAt)));
    },
    async getMeetingNotes(workspaceId, meetingId) {
      await authorizeParent(workspaceId, meetingId);
      await locks.notes(meetingId, "shared");
      const id = await notesID(workspaceId, meetingId);
      if (!id) return null;
      await locks.document(id, "shared");
      const loaded = await load(workspaceId, id);
      if (!loaded) return null;
      try { return shared(loaded.row, loaded.core); } finally { loaded.core.destroy(); }
    },
    async initializeMeetingNotes(workspaceId, meetingId, proposedId, legacyUpdate) {
      await authorizeParent(workspaceId, meetingId, true);
      await locks.notes(meetingId, "exclusive");
      const id = await notesID(workspaceId, meetingId) ?? proposedId;
      return initializeDocument(workspaceId, id, { meetingId, kind: "notes", title: "", legacyUpdate });
    },
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
      await authorizeParent(workspaceId, null);
      const rows = await db.select({ id: table.id, meetingId: table.meetingId, kind: table.kind, revision: table.revision, generation: table.generation }).from(table)
        .leftJoin(meeting, and(eq(meeting.meetingId, table.meetingId), eq(meeting.workspaceId, table.workspaceId)))
        .innerJoin(schema.syncedWorkspace, eq(schema.syncedWorkspace.workspaceId, table.workspaceId))
        .where(and(eq(table.workspaceId, workspaceId), access.read(table.workspaceId),
          isNull(schema.syncedWorkspace.deletingAt), or(isNull(table.meetingId), and(eq(meeting.active, true), isNull(meeting.deletedAt), isNull(meeting.deletingAt))), after ? gt(table.id, after) : undefined))
        .orderBy(asc(table.id)).limit(101);
      return { items: rows.slice(0, 100), nextCursor: rows.length > 100 ? rows[99]!.id : null };
    },
    initializeDocument,
    async exchangeDocument(workspaceId, id, request) {
      await authorize(workspaceId, id, request.update !== undefined);
      const loaded = await load(workspaceId, id);
      if (!loaded) throw new RequestError(404, "document_unavailable");
      const { row, core } = loaded;
      try {
        if (request.generation !== row.generation) throw new RequestError(409, "document_generation_changed");
        const checkpoint = core.checkpoint(false), vector = core.vector();
        let difference: string;
        let blocks: DocumentRecovery["blocks"] = [];
        try {
          if (request.update) {
            blocks = core.apply(request.update);
            core.purgeDeletedBlocks(Date.now() - deletionGraceHours * 60 * 60 * 1000);
            validProjection(core);
          }
          difference = core.difference(request.vector);
        } catch (error) {
          if (!(error instanceof Error) || error.message !== "document_too_large") throw documentError(error);
          const canonical = new DocumentCore(checkpoint);
          try { return { accepted: false, reason: "document_too_large", generation: row.generation, revision: row.revision,
            vector: canonical.vector(), update: canonical.difference(request.vector) }; }
          finally { canonical.destroy(); }
        }
        if (request.update && core.checkpoint() !== checkpoint) {
          const projection = validProjection(core), revision = row.revision + 1;
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
        return { accepted: true, generation: row.generation, revision: row.revision, vector: core.vector(), update: difference };
      } finally { core.destroy(); }
    },
    async documentRecoveries(workspaceId, id, after, mode = "sync") {
      await authorize(workspaceId, id);
      if (mode !== "sync" && mode !== "display") throw new RequestError(400, "invalid_document_cursor");
      const table = schema.documentRecovery;
      const [document] = await db.select({ generation: schema.document.generation }).from(schema.document).where(eq(schema.document.id, id));
      const [head] = await db.select({ sequence: sql<number>`coalesce(max(${table.sequence}), 0)` }).from(table).where(eq(table.documentId, id));
      let highWater = Number(head!.sequence), position = mode === "sync" ? 0 : highWater + 1;
      if (after) {
        try {
          const cursor = JSON.parse(new TextDecoder().decode(decodeBinary(after, 1024))) as { version: number; document: string; generation: string; mode: string; after: number; highWater: number | null };
          if (cursor.version !== 1 || cursor.document !== id || cursor.generation !== document!.generation || cursor.mode !== mode
            || !Number.isSafeInteger(cursor.after) || cursor.after < 0
            || (cursor.highWater !== null && (!Number.isSafeInteger(cursor.highWater) || cursor.highWater < 0))) throw new Error();
          position = cursor.after; highWater = cursor.highWater ?? highWater;
        } catch { throw new RequestError(400, "invalid_document_cursor"); }
      }
      const order = mode === "sync" ? asc(table.sequence) : desc(table.sequence);
      const candidates = await db.select({ id: table.id, sequence: table.sequence,
        bytes: sql<number>`4 * (length(cast(${table.blocks} as text)) + coalesce(length(${table.encryptedPayload}), 0)) + 256`,
      }).from(table).where(and(eq(table.documentId, id), eq(table.workspaceId, workspaceId), lte(table.sequence, highWater),
        mode === "sync" ? gt(table.sequence, position) : lt(table.sequence, position))).orderBy(order).limit(101);
      const selected: string[] = []; let bytes = 128;
      for (const candidate of candidates) {
        if (selected.length && (selected.length >= 100 || bytes + Number(candidate.bytes) > documentRecoveryPageBytes)) break;
        selected.push(candidate.id); bytes += Number(candidate.bytes);
      }
      const rows = selected.length ? await content.read(table, await db.select().from(table).where(and(
        eq(table.documentId, id), eq(table.workspaceId, workspaceId), inArray(table.id, selected),
      )).orderBy(order)) : [];
      const more = candidates.length > selected.length;
      const token = (position: number, ceiling: number | null) => encodeBinary(new TextEncoder().encode(JSON.stringify({
        version: 1, document: id, generation: document!.generation, mode, after: position, highWater: ceiling,
      })));
      const nextCursor = more ? token(rows.at(-1)!.sequence, highWater) : null;
      return { items: rows.map(({ id, blocks, reason, sequence, createdAt }) => ({ id, blocks, reason, sequence, createdAt })),
        nextCursor, cursor: nextCursor ?? token(mode === "sync" ? highWater : (rows.at(-1)?.sequence ?? position), mode === "sync" ? null : highWater) };
    },
    async saveDocumentRecovery(workspaceId, id, recovery) {
      await authorize(workspaceId, id, true);
      await recordRecovery(workspaceId, id, recovery);
    },
    async documentPresence(workspaceId, id, sessionId) {
      await authorize(workspaceId, id, sessionId !== undefined);
      const table = schema.documentPresence, now = new Date();
      if (sessionId) {
        await db.delete(table).where(and(eq(table.workspaceId, workspaceId), lte(table.expiresAt, now)));
        await db.insert(table).values({ id: sessionId, workspaceId, documentId: id, userId: identity.userId, expiresAt: new Date(now.getTime() + 15_000) })
        .onConflictDoUpdate({ target: table.id, set: { expiresAt: new Date(now.getTime() + 15_000) },
          setWhere: and(eq(table.userId, identity.userId), eq(table.documentId, id), eq(table.workspaceId, workspaceId)) });
      }
      const rows = await db.selectDistinct({ userId: table.userId, name: schema.user.name }).from(table)
        .innerJoin(schema.user, eq(schema.user.id, table.userId)).where(and(eq(table.workspaceId, workspaceId), eq(table.documentId, id), gt(table.expiresAt, now)));
      return rows;
    },
  };
}
