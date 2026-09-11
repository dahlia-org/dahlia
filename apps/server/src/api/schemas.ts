import { z } from "@hono/zod-openapi";
import { fileWireResponseMetadataSchema } from "../files/model";
import { recordingManifestSchema } from "../recordings/model";
import { transcriptMetadataSchema } from "../sync/transcript";
import { summaryMetadataSchema } from "../summary/metadata";
import { summaryInputSchema, transcriptSettingsSchema } from "../summary/model";
import { calendarEventSchema, transactionDataSchemas, transactionOperationSchema, transactionSchema } from "../sync/schemas";

export const id = z.string().uuid();
export const principalId = z.string().min(1).max(200);
export const date = z.string().datetime({ offset: true });
export const integer = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
export const cursor = z.string().min(1).openapi({ description: "Opaque cursor. Pass back unchanged with the original filters." });
export const pageQuery = z.object({ cursor: cursor.optional() }).strict();
export const historyQuery = pageQuery.extend({ limit: z.string().regex(/^[1-9][0-9]*$/).optional().openapi({ description: "1–100; defaults to 20." }) });
export const manifestQuery = z.object({ manifest: z.literal("1").optional() }).strict();
export const contentQuery = manifestQuery.extend({ cursor: cursor.optional() }).refine((v) => !(v.manifest && v.cursor));
export const page = <T extends z.ZodType>(item: T) => z.object({ items: z.array(item), nextCursor: cursor.nullable() });
const appearance = { icon: z.string().nullable().optional(), color: z.string().nullable().optional() };
const syncFields = { active: z.boolean().optional(), deletingAt: date.nullable().optional(), revision: integer };
const contentFields = { contentOmitted: z.boolean().optional(), contentPresent: z.boolean().optional() };
export const vault = z.object({ encryption: z.enum(["none", "server"]).optional(), vaultId: id, name: z.string(), ...appearance, ...syncFields,
  createdAt: date, updatedAt: date, role: z.enum(["owner", "member"]).optional(), hasResources: z.boolean().optional(),
}).openapi("Vault");
export const project = z.object({ projectId: id, vaultId: id, parentProjectId: id.nullable(), name: z.string(), description: z.string(),
  projectType: z.enum(["customer", "internal", "personal", "undefined"]).nullable(), ...appearance, ...syncFields,
  createdAt: date, path: z.string().optional(), rootProjectId: id.optional(), effectiveType: z.string().optional(),
  typeOwnerProjectId: id.optional(), directMeetingCount: integer.optional(), subtreeMeetingCount: integer.optional(),
}).openapi("Project");
export const meeting = z.object({ meetingId: id, vaultId: id, projectId: id.nullable(), name: z.string(), description: z.string(),
  status: z.enum(["PROCESSING_TRANSCRIPT", "TRANSCRIPT_NOT_FOUND", "READY", "RECORDING"]), duration: z.number().nonnegative().nullable(), recordingStartedAt: date.nullable(), isRecording: z.boolean().optional(),
  icalUid: z.string().nullable(), recurrenceId: z.string().nullable(), calendarEvent: calendarEventSchema.nullable(),
  createdAt: date, updatedAt: date, ...syncFields, ...contentFields, hasSummary: z.boolean().optional(),
  summaryRevision: integer.optional(), transcriptRevision: integer.optional(),
}).openapi("Meeting");
export const file = z.object({ id, vaultId: id, name: z.string(), contentType: z.string(), size: integer, checksum: z.string(),
  metadata: fileWireResponseMetadataSchema, revision: integer, createdAt: date, updatedAt: date, active: z.boolean().optional(),
  contentUrl: z.string().optional(), variants: z.record(z.string(), z.string()).optional(), ...contentFields,
}).openapi("File");
export const meetingFile = z.object({ id, vaultId: id, meetingId: id, fileId: id, capturedAt: date.nullable(), sessionId: id.nullable(),
  createdAt: date, revision: integer,
}).openapi("MeetingFile");
export const transcript = z.object({ id, meetingId: id, version: integer, syncRevision: integer,
  status: z.enum(["active", "inactive", "ended", "unknown"]), startedAt: date.nullable(), endedAt: date.nullable(),
  latestSegmentCreatedAt: date.nullable(), createdAt: date, metadata: transcriptMetadataSchema.nullable().openapi("NullableTranscriptMetadata"),
}).openapi("Transcript");
export const segment = z.object({ segmentId: id, startedAt: date, endedAt: date.nullable(), text: z.string(), createdAt: date.nullable(),
  audioSource: z.string().nullable(), speakerLabel: z.string().nullable(),
}).openapi("TranscriptSegment");
export const summary = z.object({ id, meetingId: id, version: integer, title: z.string(), document: z.string(),
  createdAt: date.nullable(), savedAt: date, metadata: summaryMetadataSchema.nullable().openapi("NullableSummaryMetadata"),
}).openapi("Summary");
const summaryProjection = z.object({ id: id.nullable(), meetingId: id, version: integer.nullable(), title: z.string().nullable(),
  createdAt: date.nullable(), document: z.string().nullable().optional(), ...contentFields,
}).openapi("SummaryProjection");
const nullableTranscript = z.object(transcript.shape).nullable().openapi("NullableTranscript");
const transcriptProjection = z.object({ meetingId: id, transcript: nullableTranscript, contentCount: integer.optional(), ...contentFields }).openapi("TranscriptProjection");
export const audio = z.object({ fileId: id.optional(), contentType: z.literal("audio/mp4"), size: integer, checksum: z.string().nullable(),
  contentUrl: z.string(), manifest: recordingManifestSchema.optional(),
}).openapi("RecordingAudio");
export const recording = z.object({ id: integer, startedAt: date, endedAt: date,
  audio: z.object({ mic: audio.optional(), system: audio.optional() }),
}).openapi("Recording");
const recordingProjection = recording.extend({ recordingNumber: integer, sessionId: id, meetingId: id, vaultId: id, revision: integer }).openapi("RecordingProjection");
const canonicalSchemas = { vault, project, meeting, summary: summaryProjection, transcript: transcriptProjection, file,
  meeting_attachment: meetingFile, recording: recordingProjection, meeting_event: z.object({}) };
// Name the nullable object itself: Swift cannot generate the equivalent anyOf([$ref, null]).
const nullableCanonicalSchemas = Object.fromEntries(Object.entries(canonicalSchemas).map(([entity, record]) => [
  entity, z.object(record.shape).nullable().openapi(`Nullable${entity.split("_").map((part) => part[0]!.toUpperCase() + part.slice(1)).join("")}Record`),
]));
export const canonicalRecord = z.union(Object.entries(nullableCanonicalSchemas).map(([entity, record]) => z.object({
  entity: z.literal(entity), id, revision: integer.nullable(), record: record.optional(),
}))).openapi("CanonicalRecord");
export const syncEntity = z.enum(["vault", "project", "meeting", "summary", "transcript", "file", "meeting_attachment", "recording", "meeting_event"]);
export const conflict = z.union(Object.entries(nullableCanonicalSchemas).map(([entity, record]) => z.object({
  entity: z.literal(entity), id, clientBaseRevision: integer.nullable(), serverRevision: integer.nullable(),
  record,
}))).openapi("RevisionConflict");
export const problem = z.object({ type: z.string(), title: z.string(), status: z.number().int(), code: z.string(),
  detail: z.string().optional(), conflicts: z.array(conflict).optional(), operationId: id.optional(),
}).openapi("Problem", { description: "RFC 9457 problem details. Branch on code, not the human-readable title." });
// Each operation carries the schema for its entity/action, rather than an arbitrary data dictionary.
export const transaction = transactionSchema.extend({ operations: z.array(z.union(Object.entries(transactionDataSchemas).map(([key, data]) => {
  const [entity, action] = key.split(":");
  return transactionOperationSchema.extend({ entity: z.literal(entity!), action: z.literal(action!), data });
}))).min(1).max(10_000) }).openapi("Transaction");
export const receipt = z.object({ id, status: z.literal("committed"), cursor, receipt: z.enum(["full", "compact"]).optional(),
  records: z.array(canonicalRecord),
}).openapi("TransactionReceipt");
export const resolution = z.union([receipt, z.object({ id, status: z.literal("unknown") })]).openapi("TransactionResolution");
export const changes = z.object({ items: z.array(z.union(Object.entries(nullableCanonicalSchemas).map(([entity, record]) => z.object({
  sequence: integer, vaultId: id, entity: z.literal(entity), entityId: id,
  action: z.enum(["upsert", "delete", "reset"]), revision: integer.nullable(), transactionId: id,
  record,
})))), cursor, highWaterCursor: cursor, hasMore: z.boolean() }).openapi("Changes");
export const snapshot = page(canonicalRecord).extend({ startCursor: cursor }).openapi("Snapshot");
const envelope = { formatVersion: z.literal(1), version: integer, entityId: id, present: z.boolean(), count: integer, byteCount: integer, sha256: z.string(), nextCursor: cursor.nullable().optional() };
export const latestSummary = z.object({ ...envelope, entity: z.literal("summary"), revision: integer,
  record: summary.partial().extend({ title: z.string().nullable(), document: z.string().nullable(), createdAt: date.nullable() }).optional(),
}).openapi("SummaryContent");
export const transcriptContent = z.object({ ...envelope, entity: z.literal("transcript"), syncRevision: integer,
  transcript: nullableTranscript, items: z.array(segment).optional(),
}).openapi("TranscriptContent");
export const summaryJob = z.object({ id, method: z.enum(["transcript", "audio"]), input: summaryInputSchema.optional(),
  stage: z.enum(["transcribing", "summarizing", "generating", "saving"]).nullable().optional(),
  transcriptResult: z.object({ transcriptId: id, version: z.string() }).nullable().optional(), settings: transcriptSettingsSchema,
  outputLanguage: z.string(), status: z.enum(["pending", "processing", "succeeded", "failed", "cancelled"]), attempts: integer,
  createdAt: date, error: z.string().nullable(),
}).openapi("SummaryJob");
export const capabilities = z.object({
  vaultEncryption: z.object({ version: integer }).optional(),
  sync: z.object({ version: integer }).optional(), vaultTransfers: z.object({ version: integer }).optional(),
  recordingArchive: z.object({ version: integer }).optional(), meetingEvents: z.object({ version: integer }).optional(),
  search: z.object({ version: integer }).optional(), imageAnalysis: z.object({ version: integer }).optional(),
  meetingSummaryGeneration: z.object({ version: integer, sources: z.array(z.enum(["transcript", "audio"])) }).optional(),
}).openapi("Capabilities");
export const person = z.object({ id: principalId, name: z.string(), email: z.string() }).openapi("Person");
export const organization = z.object({ id: principalId, name: z.string(), slug: z.string(), role: z.string().optional() }).openapi("Organization");
export const team = z.object({ id: principalId, name: z.string(), organizationId: principalId, memberCount: integer,
  createdAt: date, updatedAt: date.nullable(),
}).openapi("Team");
export const permission = z.object({ vaultId: id, principalType: z.enum(["user", "organization", "team"]), principalId,
  role: z.enum(["owner", "member"]), createdAt: date,
}).openapi("VaultPermission");
export const searchHit = z.object({ id, kind: z.enum(["meeting", "screenshot", "project"]), title: z.string(), date: z.string(), snippet: z.string(),
  meetingId: id.optional(), projectId: id.optional(), projectPath: z.string().optional(), fileId: id.optional(), meetingCount: integer.optional(),
}).openapi("SearchHit");
export const searchResults = z.object({ vaultId: id, meetings: z.array(searchHit), screenshots: z.array(searchHit), projects: z.array(searchHit),
  limited: z.object({ meeting: z.boolean(), screenshot: z.boolean(), project: z.boolean() }),
}).openapi("SearchResults");
export const textSearchRequest = z.object({ query: z.string().min(1).max(500), kind: z.enum(["meeting", "screenshot"]),
  cursor: cursor.optional(), limit: z.number().int().min(1).max(200).optional(),
}).strict().openapi("TextSearchRequest");
export const textSearchResults = page(z.object({ id, meetingId: id, snippet: z.string() })).extend({ version: z.literal(1), scope: z.literal("server") }).openapi("TextSearchResults");
