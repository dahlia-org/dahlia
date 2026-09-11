import { z } from "@hono/zod-openapi";
import { appearanceSchema } from "../appearance-model";
import { transcriptWriteSchema } from "./transcript";
import { summaryMetadataSchema } from "../summary/metadata";
import { recordingSourceSchema, recordingManifestSchema } from "../recordings/model";
import { fileWireMetadataSchema, fileMetadataFromWire } from "../files/model";

export const uuidSchema = z.uuid().transform((value) => value.toLowerCase());
export const dateSchema = z.iso.datetime().transform((value) => new Date(value));
const instantParts = (value: string) => {
  const zoneIndex = value.endsWith("Z") ? value.length - 1 : value.length - 6;
  const fractionIndex = value.indexOf(".");
  return {
    second: Date.parse(fractionIndex < 0 ? value : value.slice(0, fractionIndex) + value.slice(zoneIndex)),
    fraction: fractionIndex < 0 ? "" : value.slice(fractionIndex + 1, zoneIndex),
  };
};
const orderedInstants = (start: string, end: string) => {
  const startParts = instantParts(start);
  const endParts = instantParts(end);
  if (startParts.second !== endParts.second) return startParts.second < endParts.second;
  const precision = Math.max(startParts.fraction.length, endParts.fraction.length);
  return startParts.fraction.padEnd(precision, "0") <= endParts.fraction.padEnd(precision, "0");
};
export const calendarEventSchema = z.object({
  start: z.iso.datetime({ offset: true }),
  end: z.iso.datetime({ offset: true }),
  is_all_day: z.boolean(),
}).strict().refine(
  (value) => orderedInstants(value.start, value.end),
  "Calendar event end must be on or after start",
);
export type CalendarEventSnapshot = z.infer<typeof calendarEventSchema>;

const calendarIdentityFields = {
  calendarEvent: calendarEventSchema.nullable().optional(),
  icalUid: z.string().min(1).max(2048).nullable().optional(),
  recurrenceId: z.string().regex(/^(?:|[0-9]{8}|[0-9]{8}T[0-9]{6}Z)$/).nullable().optional(),
};
const pairedCalendarIdentity = (value: { icalUid?: string | null; recurrenceId?: string | null }) =>
  (value.icalUid === undefined && value.recurrenceId === undefined)
  || (value.icalUid === null && value.recurrenceId === null)
  || (typeof value.icalUid === "string" && typeof value.recurrenceId === "string");

export const nullableDateSchema = dateSchema.nullable();
export const projectNameSchema = z.string().trim().min(1).refine((value) =>
  ![".", ".."].includes(value)
  && ![".", "_"].includes(value[0] ?? "")
  && ![...value].some((character) => "/:".includes(character) || character.charCodeAt(0) <= 31 || character.charCodeAt(0) === 127)
  && new TextEncoder().encode(value).byteLength <= 255,
);
export const projectTypeSchema = z.enum(["customer", "internal", "personal", "undefined"]);
export const meetingStatusSchema = z.enum([
  "TRANSCRIPT_NOT_FOUND",
  "PROCESSING_TRANSCRIPT",
  "READY",
  "RECORDING",
]).transform((status) => status === "RECORDING" ? "READY" : status);
export const transcriptSegmentSchema = z.object({
  segmentId: uuidSchema,
  startedAt: dateSchema,
  endedAt: nullableDateSchema,
  text: z.string(),
  createdAt: nullableDateSchema,
  audioSource: z.enum(["mic", "system"]).nullable(),
  speakerLabel: z.string().nullable(),
}).strict();
export const transcriptChunkSchema = z.object({
  segments: z.array(transcriptSegmentSchema).max(500),
  deletions: z.array(uuidSchema).max(500),
}).strict();

export const SCREENSHOT_DELETE_BATCH_SIZE = 25;
export const STORAGE_OPERATION_CONCURRENCY = 4;
export const QUERY_EMBEDDING_DEADLINE_MS = 2_000;
export const QUERY_EMBEDDING_CONCURRENCY = 8;
export const permissionPrincipalSchema = z.string().trim().min(1).max(200);
export const SYNC_READ_PAGE_SIZE = 200;
export const TRANSCRIPT_READ_PAGE_SIZE = 10_000;
export const TRANSCRIPT_PATCH_ITEM_LIMIT = 50_000;
export const TRANSCRIPT_PATCH_CHUNK_LIMIT = 100;
export const SUMMARY_DOCUMENT_MAX_SERIALIZED_BYTES = 6 * 1024 * 1024;
export const summaryDocumentSchema = z.string().refine(
  (value) => new TextEncoder().encode(JSON.stringify(value)).byteLength <= SUMMARY_DOCUMENT_MAX_SERIALIZED_BYTES,
  "Summary document is too large",
).refine((document) => {
  try {
    const value: unknown = JSON.parse(document);
    return !value || typeof value !== "object" || !("metadata" in value) || value.metadata === null
      || summaryMetadataSchema.safeParse(value.metadata).success;
  } catch { return true; } // Preserve the existing document contract for legacy non-JSON summaries.
}, "Invalid summary metadata");
export const meetingCursorSchema = z.tuple([dateSchema, uuidSchema]);
export const screenshotCursorSchema = z.tuple([dateSchema, uuidSchema]);
export const transcriptCursorSchema = z.tuple([dateSchema, uuidSchema]);
export const uuidV7Schema = z.string()
  .regex(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i)
  .transform((value) => value.toLowerCase()).meta({ format: "uuidv7" });
export const transactionOperationSchema = z.object({
  id: uuidV7Schema,
  entity: z.enum(["vault", "project", "meeting", "summary", "transcript", "file", "meeting_attachment", "meeting_event", "recording"]),
  action: z.enum(["create", "update", "delete", "upsert", "patch", "reset"]),
  entityId: uuidSchema,
  baseRevision: z.number().int().nonnegative().nullable(),
  data: z.record(z.string(), z.unknown()).nullable(),
}).strict();
export const transactionSchema = z.object({
  schemaVersion: z.literal(2),
  id: uuidV7Schema,
  vaultId: uuidSchema,
  createdAt: dateSchema,
  operations: z.array(transactionOperationSchema).min(1).max(10_000),
}).strict();
export const appearanceFields = {
  icon: appearanceSchema.shape.icon.nullable().optional(),
  color: appearanceSchema.shape.color.nullable().optional(),
};
export const transactionDataSchemas = {
  "meeting_event:create": z.discriminatedUnion("kind", [
    z.object({ meetingId: uuidSchema, kind: z.enum(["tag_added", "tag_removed"]), occurredAt: dateSchema, relatedId: z.string().regex(/^[0-9]{1,19}$/) }).strict(),
    z.object({ meetingId: uuidSchema, kind: z.enum(["recording_started", "recording_ended"]), occurredAt: dateSchema, sessionId: uuidSchema }).strict(),
    z.object({ meetingId: uuidSchema, kind: z.literal("segment_rotated"), occurredAt: dateSchema, sessionId: uuidSchema, relatedId: uuidSchema, audioSource: z.enum(["mic", "system"]), segmentIndex: z.number().int().positive().max(2147483647) }).strict(),
  ]),
  "vault:create": z.object({ encryption: z.enum(["none", "server"]).optional(), ...appearanceFields, name: z.string().trim().min(1), createdAt: dateSchema }).strict(),
  "vault:update": z.object({ encryption: z.enum(["none", "server"]).optional(), ...appearanceFields, name: z.string().trim().min(1) }).strict(),
  "vault:reset": z.object({ preservePermissions: z.boolean().optional() }).strict(),
  "project:create": z.object({ ...appearanceFields, parentProjectId: uuidSchema.nullable(), name: projectNameSchema, description: z.string().max(20_000).default(""), projectType: projectTypeSchema.nullable(), createdAt: dateSchema }).strict().refine((data) => data.parentProjectId === null || (data.icon == null && data.color == null), { message: "Child projects inherit their parent appearance", path: ["icon"] }),
  "project:update": z.object({ ...appearanceFields, parentProjectId: uuidSchema.nullable(), name: projectNameSchema, description: z.string().max(20_000).default(""), projectType: projectTypeSchema.nullable() }).strict().refine((data) => data.parentProjectId === null || (data.icon == null && data.color == null), { message: "Child projects inherit their parent appearance", path: ["icon"] }),
  "project:delete": z.object({}).strict(),
  "meeting:create": z.object({ ...calendarIdentityFields, projectId: uuidSchema.nullable(), name: z.string(), description: z.string().default(""), status: meetingStatusSchema, duration: z.number().finite().nonnegative().nullable(), recordingStartedAt: nullableDateSchema, createdAt: dateSchema, updatedAt: dateSchema }).strict().refine(pairedCalendarIdentity, "Calendar UID and recurrence ID must be supplied together"),
  "meeting:update": z.object({ ...calendarIdentityFields, projectId: uuidSchema.nullable(), name: z.string(), description: z.string().default(""), status: meetingStatusSchema, duration: z.number().finite().nonnegative().nullable(), recordingStartedAt: nullableDateSchema, updatedAt: dateSchema }).strict().refine(pairedCalendarIdentity, "Calendar UID and recurrence ID must be supplied together"),
  "meeting:delete": z.object({}).strict(),
  "summary:upsert": z.object({ title: z.string(), document: summaryDocumentSchema, createdAt: dateSchema }).strict(),
  "summary:delete": z.object({}).strict(),
  "transcript:patch": z.object({
    transcript: transcriptWriteSchema,
    mode: z.enum(["replace", "append"]),
    patchId: uuidV7Schema,
    segmentCount: z.number().int().nonnegative(),
    deletionCount: z.number().int().nonnegative().max(TRANSCRIPT_PATCH_ITEM_LIMIT),
    chunks: z.array(z.object({
      index: z.number().int().nonnegative(),
      sha256: z.string().regex(/^[0-9a-f]{64}$/),
      segmentCount: z.number().int().nonnegative().max(500),
      deletionCount: z.number().int().nonnegative().max(500),
    }).strict()),
  }).strict().superRefine((patch, context) => {
    // Full snapshots use bounded staged chunks; only incremental patches retain the patch-wide limits.
    if ((patch.mode === "append" && (patch.segmentCount > TRANSCRIPT_PATCH_ITEM_LIMIT || patch.chunks.length > TRANSCRIPT_PATCH_CHUNK_LIMIT))
      || patch.chunks.reduce((sum, chunk) => sum + chunk.segmentCount, 0) !== patch.segmentCount
      || patch.chunks.reduce((sum, chunk) => sum + chunk.deletionCount, 0) !== patch.deletionCount
      || patch.chunks.some((chunk, index) => chunk.index !== index)) {
      context.addIssue({ code: "custom", message: "Invalid transcript patch manifest" });
    }
  }),
  "recording:upsert": z.object({ source: recordingSourceSchema, checksum: z.string().regex(/^SHA-256:[0-9a-f]{64}$/), manifest: recordingManifestSchema }).strict(),
  "file:upsert": z.object({ name: z.string().min(1).max(255).optional(), checksum: z.string().regex(/^SHA-256:[0-9a-f]{64}$/), metadata: fileWireMetadataSchema.partial().transform(fileMetadataFromWire) }).strict(),
  "file:delete": z.object({}).strict(),
  "meeting_attachment:upsert": z.object({ meetingId: uuidSchema, fileId: uuidSchema, capturedAt: nullableDateSchema, sessionId: uuidSchema.nullable(), createdAt: dateSchema }).strict(),
  "meeting_attachment:delete": z.object({}).strict(),
} as const;
export const SYNC_CHANGE_PAGE_SIZE = 100;
