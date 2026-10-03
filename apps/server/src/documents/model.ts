import { z } from "@hono/zod-openapi";
import { documentStateLimit, documentUpdateLimit } from "@dahlia-ai/ui/documents/core";

// Two base64 states (update/vector) and JSON overhead; separate from domain transactions.
export const documentRequestLimit = 24 * 1024 * 1024;
export const documentResponseLimit = 32 * 1024 * 1024;
export const documentRecoveryPageBytes = 6 * 1024 * 1024;

const opaqueUUID = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
const checkpoint = z.string().max(Math.ceil(documentStateLimit / 3) * 4);
const binary = z.string().max(Math.ceil(documentUpdateLimit / 3) * 4);
export const documentKindSchema = z.enum(["notes", "summary", "general"]);
export const documentInitializeSchema = z.object({ meetingId: z.uuid().nullable(), kind: documentKindSchema, title: z.string().max(1000), legacyUpdate: binary.optional() }).strict().openapi("DocumentInitialize");
export const meetingNotesInitializeSchema = z.object({ id: z.uuid(), legacyUpdate: binary.optional() }).strict().openapi("MeetingNotesInitialize");
export const documentExchangeSchema = z.object({ protocolVersion: z.literal(3), generation: opaqueUUID, vector: binary, update: binary.optional() }).strict().openapi("DocumentExchange");
export const documentExchangeResultSchema = z.object({ accepted: z.boolean(), reason: z.literal("document_too_large").optional(), generation: opaqueUUID, revision: z.number().int(), vector: binary, update: checkpoint }).openapi("DocumentExchangeResult");
export const sharedDocumentSchema = z.object({ id: z.uuid(), workspaceId: z.uuid(), meetingId: z.uuid().nullable(), kind: documentKindSchema, title: z.string(), schemaVersion: z.literal(2),
  generation: opaqueUUID, revision: z.number().int(), checkpoint, text: z.string(), createdAt: z.iso.datetime(), updatedAt: z.iso.datetime(),
}).openapi("SharedDocument");
export const documentEnvelopeSchema = z.object({ document: z.object(sharedDocumentSchema.shape).nullable().openapi("NullableSharedDocument") }).openapi("DocumentEnvelope");
export const documentListSchema = z.object({ items: z.array(z.object({ id: z.uuid(), meetingId: z.uuid().nullable(), kind: documentKindSchema, revision: z.number().int(), generation: opaqueUUID })), nextCursor: z.uuid().nullable() }).openapi("DocumentList");
export const documentRecoverySchema = z.object({ id: z.uuid(), reason: z.enum(["deleted", "concurrent_delete"]),
  blocks: z.array(z.object({ id: z.string().max(128), type: z.enum(["paragraph", "heading", "codeBlock"]), text: z.string().max(2_000_000) }).strict()).min(1).max(50_000),
}).strict().openapi("DocumentRecovery");
export const documentRecoveryListSchema = z.object({ items: z.array(documentRecoverySchema.extend({ sequence: z.number().int().nonnegative(), createdAt: z.iso.datetime() })), nextCursor: z.string().nullable(), cursor: z.string() }).openapi("DocumentRecoveryList");
export const documentPresenceSchema = z.object({ items: z.array(z.object({ userId: z.uuid(), name: z.string() })) }).openapi("DocumentPresence");
export const documentPresenceRequestSchema = z.object({ sessionId: opaqueUUID }).strict().openapi("DocumentPresenceRequest");
