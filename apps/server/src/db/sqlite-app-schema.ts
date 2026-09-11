import type { CalendarEventSnapshot } from "../sync/schemas";
import type { TranscriptMetadata } from "../sync/transcript";
import type { SummaryMetadata } from "../summary/metadata";
import type { SummaryJob } from "../summary/model";
import type { RecordingRecord } from "../recordings/model";
import { sql } from "drizzle-orm";
import { blob, check, foreignKey, index, integer, primaryKey, real, sqliteTable, sqliteView, text, unique, uniqueIndex } from "drizzle-orm/sqlite-core";

import type { FileMetadata } from "../files/model";
import { DEFAULT_ACCOUNT_SETTINGS, type AccountSettings } from "../account-settings-model";
import { DEFAULT_SEARCH_SETTINGS, type SearchSettings } from "../search/settings-model";

import { user as authUser } from "./generated/sqlite-auth-schema";

const sqliteTimestamp = (name: string) => integer(name, { mode: "timestamp_ms" });

export const serverSettings = sqliteTable("server_settings", {
  id: integer("id").primaryKey(),
  searchWeights: text("search_weights", { mode: "json" }).$type<SearchSettings>().default(DEFAULT_SEARCH_SETTINGS).notNull(),
}, (table) => [check("server_settings_singleton", sql`${table.id} = 1`)]);

export const serverInitializations = sqliteTable("server_initializations", {
  name: text("name").primaryKey(),
  initializedAt: sqliteTimestamp("initialized_at").notNull(),
});

export const accountSettings = sqliteTable("account_settings", {
  userId: text("user_id").primaryKey().references(() => authUser.id, { onDelete: "cascade" }),
  summary: text("summary", { mode: "json" }).$type<AccountSettings["summary"]>().default(DEFAULT_ACCOUNT_SETTINGS.summary).notNull(),
  processing: text("processing", { mode: "json" }).$type<AccountSettings["processing"]>().default(DEFAULT_ACCOUNT_SETTINGS.processing).notNull(),
  revision: integer("revision").default(1).notNull(),
  outputLanguage: text("output_language").$type<AccountSettings["outputLanguage"]>().notNull(),
  analysisLanguages: text("analysis_languages", { mode: "json" }).$type<AccountSettings["analysisLanguages"]>().notNull(),
});

export const syncedVault = sqliteTable("vaults", {
  encryption: text("encryption").$type<"none" | "server">().default("none").notNull(),
  encryptedPayload: text("encrypted_payload"),
  vaultId: text("vault_id").primaryKey(),
  name: text("name").notNull(),
  icon: text("icon"),
  color: text("color"),
  revision: integer("revision").default(1).notNull(),
  deletingAt: sqliteTimestamp("deleting_at"),
  createdAt: sqliteTimestamp("created_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
  updatedAt: sqliteTimestamp("updated_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
});

export const syncedProject = sqliteTable("projects", {
  encryptedPayload: text("encrypted_payload"),
  projectId: text("project_id").primaryKey(),
  vaultId: text("vault_id").notNull(),
  parentProjectId: text("parent_project_id"),
  name: text("name").notNull(),
  icon: text("icon"),
  color: text("color"),
  description: text("description").default("").notNull(),
  projectType: text("project_type"),
  revision: integer("revision").notNull(),
  createdAt: sqliteTimestamp("created_at").notNull(),
  updatedAt: sqliteTimestamp("updated_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
}, (table) => [
  unique("project_vault_project_unique").on(table.vaultId, table.projectId),
  foreignKey({ columns: [table.vaultId], foreignColumns: [syncedVault.vaultId] }).onDelete("cascade"),
  foreignKey({
    columns: [table.vaultId, table.parentProjectId],
    foreignColumns: [table.vaultId, table.projectId],
  }).onDelete("restrict"),
  check("project_type_check", sql`(
    (${table.parentProjectId} IS NULL AND ${table.projectType} IN ('customer', 'internal', 'personal', 'undefined'))
    OR (${table.parentProjectId} IS NOT NULL AND ${table.projectType} IS NULL)
  )`),
  check("project_revision_check", sql`${table.revision} >= 1`),
  check("project_parent_check", sql`${table.parentProjectId} IS NULL OR ${table.parentProjectId} <> ${table.projectId}`),
  index("project_vault_parent_name_idx").on(table.vaultId, table.parentProjectId, table.name),
]);

export const syncedVaultPermission = sqliteTable("vault_permissions", {
  vaultId: text("vault_id").notNull(),
  principalType: text("principal_type").notNull(),
  principalId: text("principal_id").notNull(),
  role: text("role").notNull(),
  grantedByUserId: text("granted_by_user_id").notNull(),
  createdAt: sqliteTimestamp("created_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
}, (table) => [
  primaryKey({ columns: [table.vaultId, table.principalType, table.principalId] }),
  foreignKey({
    columns: [table.vaultId],
    foreignColumns: [syncedVault.vaultId],
  }).onDelete("cascade"),
  foreignKey({
    columns: [table.grantedByUserId],
    foreignColumns: [authUser.id],
  }).onDelete("restrict"),
  check("vault_permission_principal_type_check", sql`${table.principalType} IN ('user', 'organization', 'team')`),
  check("vault_permission_role_check", sql`${table.role} IN ('owner', 'member')`),
  check("vault_permission_owner_user_check", sql`${table.role} <> 'owner' OR ${table.principalType} = 'user'`),
  uniqueIndex("vault_permission_single_owner_idx").on(table.vaultId).where(sql`${table.role} = 'owner'`),
  index("vault_permission_principal_vault_idx")
    .on(table.principalType, table.principalId, table.role, table.vaultId),
]);

export const syncedMeeting = sqliteTable("meetings", {
  encryptedPayload: text("encrypted_payload"),
  meetingId: text("meeting_id").primaryKey(),
  vaultId: text("vault_id").notNull(),
  projectId: text("project_id"),
  name: text("name").notNull(),
  description: text("description").default("").notNull(),
  status: text("status").notNull(),
  duration: real("duration"),
  recordingStartedAt: sqliteTimestamp("recording_started_at"),
  icalUid: text("ical_uid"),
  recurrenceId: text("recurrence_id"),
  calendarEvent: text("calendar_event", { mode: "json" }).$type<CalendarEventSnapshot>(),
  createdAt: sqliteTimestamp("created_at").notNull(),
  updatedAt: sqliteTimestamp("updated_at").notNull(),
  revision: integer("revision").default(1).notNull(),
  summaryRevision: integer("summary_revision").default(0).notNull(),
  transcriptRevision: integer("transcript_revision").default(0).notNull(),
  active: integer("active", { mode: "boolean" }).default(false).notNull(),
  deletingAt: sqliteTimestamp("deleting_at"),
}, (table) => [
  index("meetings_calendar_event_idx").on(table.icalUid, table.recurrenceId),
  unique("synced_meeting_vault_meeting_unique").on(table.vaultId, table.meetingId),
  foreignKey({
    columns: [table.vaultId],
    foreignColumns: [syncedVault.vaultId],
  }).onDelete("cascade"),
  foreignKey({
    columns: [table.vaultId, table.projectId],
    foreignColumns: [syncedProject.vaultId, syncedProject.projectId],
  }),
  index("synced_meeting_vault_created_id_idx").on(table.vaultId, table.createdAt, table.meetingId),
]);

// Domain history survives meeting deletion; Vault deletion removes it.
export const meetingEvent = sqliteTable("meeting_events", {
  id: text("id").primaryKey(),
  vaultId: text("vault_id").notNull().references(() => syncedVault.vaultId, { onDelete: "cascade" }),
  ownerUserId: text("owner_user_id").notNull().references(() => authUser.id, { onDelete: "cascade" }),
  meetingId: text("meeting_id").notNull(),
  kind: text("kind").notNull(),
  occurredAt: sqliteTimestamp("occurred_at").notNull(),
  receivedAt: sqliteTimestamp("received_at").notNull(),
  sessionId: text("session_id"),
  relatedId: text("related_id"),
  audioSource: text("audio_source"),
  segmentIndex: integer("segment_index"),
  changedFields: text("changed_fields"),
}, (table) => [
  index("meeting_events_meeting_time_idx").on(table.vaultId, table.meetingId, table.occurredAt, table.id),
  index("meeting_events_session_idx").on(table.vaultId, table.sessionId),
  check("meeting_events_kind_check", sql`${table.kind} IN ('meeting_created', 'meeting_updated', 'meeting_deleted', 'tag_added', 'tag_removed', 'recording_started', 'recording_ended', 'segment_rotated')`),
  check("meeting_events_source_check", sql`${table.audioSource} IN ('mic', 'system')`),
]);

export const recordingSession = sqliteView("recording_sessions", {
  vaultId: text("vault_id").notNull(),
  meetingId: text("meeting_id").notNull(),
  sessionId: text("session_id").notNull(),
  startedAt: sqliteTimestamp("started_at"),
  endedAt: sqliteTimestamp("ended_at"),
}).as(sql`
  SELECT vault_id, meeting_id, session_id,
    min(CASE WHEN kind = 'recording_started' THEN occurred_at END) AS started_at,
    max(CASE WHEN kind = 'recording_ended' THEN occurred_at END) AS ended_at
  FROM meeting_events
  WHERE session_id IS NOT NULL AND kind IN ('recording_started', 'recording_ended')
  GROUP BY vault_id, meeting_id, session_id
`);

export const transcript = sqliteTable("transcripts", {
  encryptedPayload: text("encrypted_payload"),
  id: text("id").primaryKey(),
  meetingId: text("meeting_id").notNull(),
  version: integer("version").notNull(),
  syncRevision: integer("sync_revision").notNull(),
  startedAt: sqliteTimestamp("started_at"),
  endedAt: sqliteTimestamp("ended_at"),
  createdAt: sqliteTimestamp("created_at").notNull(),
  metadata: text("metadata", { mode: "json" }).$type<TranscriptMetadata>(),
}, (table) => [
  unique("transcript_meeting_version_unique").on(table.meetingId, table.version),
  foreignKey({ columns: [table.meetingId], foreignColumns: [syncedMeeting.meetingId] }).onDelete("cascade"),
  check("transcript_version_check", sql`${table.version} >= 1`),
]);

export const syncedTranscriptSegment = sqliteTable("transcript_segments", {
  encryptedPayload: text("encrypted_payload"),
  transcriptId: text("transcript_id").notNull(),
  segmentId: text("segment_id").notNull(),
  startedAt: sqliteTimestamp("started_at").notNull(),
  endedAt: sqliteTimestamp("ended_at"),
  text: text("text").notNull(),
  createdAt: sqliteTimestamp("created_at"),
  audioSource: text("audio_source"),
  speakerLabel: text("speaker_label"),
  normalizedCharacterCount: integer("normalized_character_count"),
}, (table) => [
  primaryKey({
    columns: [table.transcriptId, table.segmentId],
  }),
  foreignKey({
    columns: [table.transcriptId],
    foreignColumns: [transcript.id],
  }).onDelete("cascade"),
  index("transcript_segment_created_idx").on(table.transcriptId, table.createdAt),
  index("transcript_segment_start_id_idx")
    .on(table.transcriptId, table.startedAt, table.segmentId),
  check("transcript_segment_normalized_character_count_check", sql`${table.normalizedCharacterCount} IS NULL OR ${table.normalizedCharacterCount} >= 0`),
]);

export const transcriptPatchChunk = sqliteTable("transcript_patch_chunks", {
  encryptedPayload: text("encrypted_payload"),
  vaultId: text("vault_id").notNull(),
  meetingId: text("meeting_id").notNull(),
  patchId: text("patch_id").notNull(),
  chunkIndex: integer("chunk_index").notNull(),
  contentHash: text("content_hash").notNull(),
  payload: text("payload").notNull(),
  createdAt: sqliteTimestamp("created_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
}, (table) => [
  primaryKey({ columns: [table.vaultId, table.meetingId, table.patchId, table.chunkIndex] }),
  foreignKey({
    columns: [table.vaultId, table.meetingId],
    foreignColumns: [syncedMeeting.vaultId, syncedMeeting.meetingId],
  }).onDelete("cascade"),
]);

export const syncedFile = sqliteTable("files", {
  encryptedPayload: text("encrypted_payload"),
  fileId: text("file_id").primaryKey(),
  vaultId: text("vault_id").notNull().references(() => syncedVault.vaultId, { onDelete: "cascade" }),
  uri: text("uri").notNull(),
  offset: integer("offset").notNull().default(0),
  size: integer("size").notNull(),
  contentType: text("content_type").notNull(),
  checksum: text("checksum").notNull(),
  name: text("name").notNull(),
  metadata: text("metadata", { mode: "json" }).$type<FileMetadata>().notNull(),
  active: integer("active", { mode: "boolean" }).default(false).notNull(),
  uploadedAt: sqliteTimestamp("uploaded_at"),
  revision: integer("revision").default(0).notNull(),
  createdAt: sqliteTimestamp("created_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
  updatedAt: sqliteTimestamp("updated_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
}, (table) => [
  unique("files_vault_file_unique").on(table.vaultId, table.fileId),
  index("files_vault_file_idx").on(table.vaultId, table.fileId),
  check("files_offset_check", sql`${table.offset} = 0`),
  check("files_size_check", sql`${table.size} >= 0`)
]);


export const syncedRecording = sqliteTable("recordings", {
  sessionId: text("session_id").primaryKey(),
  meetingId: text("meeting_id").notNull(),
  number: integer("number").notNull(),
  startedAt: integer("started_at", { mode: "timestamp_ms" }).notNull(),
  endedAt: integer("ended_at", { mode: "timestamp_ms" }).notNull(),
  audio: text("audio", { mode: "json" }).$type<RecordingRecord["audio"]>().notNull(),
  revision: integer("revision").default(0).notNull(),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull(),
}, (table) => [
  foreignKey({ columns: [table.meetingId], foreignColumns: [syncedMeeting.meetingId] }).onDelete("cascade"),
  unique("recordings_meeting_number_unique").on(table.meetingId, table.number),
  index("recordings_meeting_session_idx").on(table.meetingId, table.sessionId),
  check("recordings_number_check", sql`${table.number} > 0`),

]);

export const meetingAttachment = sqliteTable("meeting_attachments", {
  id: text("id").primaryKey(),
  vaultId: text("vault_id").notNull(),
  meetingId: text("meeting_id").notNull(),
  fileId: text("file_id").notNull(),
  capturedAt: sqliteTimestamp("captured_at"),
  sessionId: text("session_id"),
  createdAt: sqliteTimestamp("created_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
  revision: integer("revision").default(1).notNull(),
}, (table) => [
  foreignKey({ columns: [table.vaultId, table.meetingId], foreignColumns: [syncedMeeting.vaultId, syncedMeeting.meetingId] }).onDelete("cascade"),
  foreignKey({ columns: [table.vaultId, table.fileId], foreignColumns: [syncedFile.vaultId, syncedFile.fileId] }),
  unique("meeting_attachments_meeting_attachment_unique").on(table.meetingId, table.fileId),
  index("meeting_attachments_vault_meeting_id_idx").on(table.vaultId, table.meetingId, table.id)
]);

// Read-only image projection. All writes belong to files and meeting_attachments.
export const syncedScreenshot = sqliteView("meeting_images", {
  screenshotId: text("screenshot_id").notNull(),
  fileId: text("file_id").notNull(),
  vaultId: text("vault_id").notNull(),
  meetingId: text("meeting_id").notNull(),
  capturedAt: sqliteTimestamp("captured_at").notNull(),
  contentType: text("content_type").notNull(),
  storageKey: text("storage_key").notNull(),
  contentLength: integer("content_length").notNull(),
  contentHash: text("content_hash").notNull(),
  active: integer("active", { mode: "boolean" }).notNull(),
  ocrText: text("ocr_text"),
  caption: text("caption"),
  revision: integer("revision").notNull(),
}).as(sql`
  SELECT m.id AS screenshot_id, f.file_id, m.vault_id, m.meeting_id,
    coalesce(m.captured_at, m.created_at) AS captured_at, f.content_type,
    'files/' || f.file_id || '/original' AS storage_key,
    f.size AS content_length, substr(f.checksum, 9) AS content_hash, f.active,
    json_extract(f.metadata, '$.ocr_text') AS ocr_text,
    json_extract(f.metadata, '$.caption') AS caption,
    m.revision
  FROM meeting_attachments m JOIN files f ON f.file_id = m.file_id AND f.vault_id = m.vault_id
  WHERE json_extract(f.metadata, '$.source') = 'screenshot'
`);

export const searchDocument = sqliteTable("search_documents", {
  documentId: text("document_id").notNull(),
  vaultId: text("vault_id").notNull(),
  meetingId: text("meeting_id").notNull(),
  kind: text("kind").notNull(),
  searchText: text("search_text").default("").notNull(),
  titleText: text("title_text").default("").notNull(),
  tagsText: text("tags_text").default("").notNull(),
  descriptionText: text("description_text").default("").notNull(),
  summaryText: text("summary_text").default("").notNull(),
  ocrText: text("ocr_text").default("").notNull(),
  captionText: text("caption_text").default("").notNull(),
  embeddingContentHash: text("embedding_content_hash"),
  embedding: blob("embedding", { mode: "buffer" }),
  embeddingModel: text("embedding_model"),
  updatedAt: sqliteTimestamp("updated_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
}, (table) => [
  primaryKey({ columns: [table.vaultId, table.documentId] }),
  foreignKey({
    columns: [table.vaultId, table.meetingId],
    foreignColumns: [syncedMeeting.vaultId, syncedMeeting.meetingId],
  }).onDelete("cascade"),
  check("search_document_embedding_dimensions_check", sql`${table.embedding} IS NULL OR (length(${table.embedding}) BETWEEN 128 AND 4096 AND length(${table.embedding}) % 4 = 0)`),
  check("search_document_kind_check", sql`${table.kind} IN ('meeting', 'screenshot')`),
  index("search_document_vault_kind_meeting_document_idx")
    .on(table.vaultId, table.kind, table.meetingId, table.documentId),
]);

export const searchIndexJob = sqliteTable("jobs_search_index", {
  vaultId: text("vault_id").notNull(),
  documentId: text("document_id").notNull(),
  ownerUserId: text("owner_user_id").notNull(),
  model: text("model").notNull(),
  dimensions: integer("dimensions").notNull(),
  generation: integer("generation").default(1).notNull(),
  status: text("status").default("pending").notNull(),
  attempts: integer("attempts").default(0).notNull(),
  availableAt: sqliteTimestamp("available_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
  claimedAt: sqliteTimestamp("claimed_at"),
  leaseExpiresAt: sqliteTimestamp("lease_expires_at"),
  lastErrorCode: text("last_error_code"),
  updatedAt: sqliteTimestamp("updated_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
}, (table) => [
  primaryKey({ columns: [table.vaultId, table.documentId] }),
  foreignKey({
    columns: [table.vaultId],
    foreignColumns: [syncedVault.vaultId],
  }).onDelete("cascade"),
  foreignKey({
    columns: [table.ownerUserId],
    foreignColumns: [authUser.id],
  }).onDelete("cascade"),
  check("search_index_job_status_check", sql`${table.status} IN ('pending', 'processing', 'failed')`),
  check("search_index_job_dimensions_check", sql`${table.dimensions} BETWEEN 32 AND 1024`),
  index("search_index_job_claim_idx").on(table.status, table.availableAt, table.leaseExpiresAt),
]);

export const syncTransactionReceipt = sqliteTable("transaction_receipts", {
  encryptedPayload: text("encrypted_payload"),
  transactionId: text("transaction_id").primaryKey(),
  ownerUserId: text("owner_user_id").notNull(),
  vaultId: text("vault_id").notNull(),
  requestHash: text("request_hash").notNull(),
  responseJson: text("response_json"),
  resultsJson: text("results_json").default("[]").notNull(),
  cursor: integer("cursor").notNull(),
  createdAt: sqliteTimestamp("created_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
}, (table) => [
  foreignKey({ columns: [table.ownerUserId], foreignColumns: [authUser.id] }).onDelete("cascade"),
  index("transaction_receipt_owner_created_idx").on(table.ownerUserId, table.createdAt),
]);

export const syncChange = sqliteTable("sync_changes", {
  sequence: integer("sequence").primaryKey({ autoIncrement: true }),
  ownerUserId: text("owner_user_id").notNull(),
  vaultId: text("vault_id").notNull(),
  entity: text("entity").notNull(),
  entityId: text("entity_id").notNull(),
  action: text("action").notNull(),
  revision: integer("revision"),
  transactionId: text("transaction_id").notNull(),
  createdAt: sqliteTimestamp("created_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
}, (table) => [
  check("sync_change_entity_check", sql`${table.entity} IN ('vault', 'project', 'meeting', 'summary', 'transcript', 'file', 'meeting_attachment', 'recording')`),
  check("sync_change_action_check", sql`${table.action} IN ('upsert', 'delete', 'reset')`),
  index("sync_change_owner_vault_sequence_idx").on(table.ownerUserId, table.vaultId, table.sequence),
  index("sync_change_owner_sequence_idx").on(table.ownerUserId, table.sequence),
]);

// Survives Vault deletion and ledger pruning; contains no canonical content.
export const syncVaultState = sqliteTable("sync_vault_state", {
  ownerUserId: text("owner_user_id").notNull().references(() => authUser.id, { onDelete: "cascade" }),
  vaultId: text("vault_id").notNull(),
  latestSequence: integer("latest_sequence").default(0).notNull(),
  prunedThrough: integer("pruned_through").default(0).notNull(),
}, (table) => [
  primaryKey({ columns: [table.ownerUserId, table.vaultId] }),
  check("sync_vault_state_boundary_check", sql`${table.prunedThrough} >= 0 AND ${table.latestSequence} >= ${table.prunedThrough}`),
]);

export const storageDeleteJob = sqliteTable("jobs_storage_delete", {
  storageKey: text("storage_key").primaryKey(),
  attempts: integer("attempts").default(0).notNull(),
  status: text("status").default("pending").notNull(),
  availableAt: sqliteTimestamp("available_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
  claimedAt: sqliteTimestamp("claimed_at"),
  leaseExpiresAt: sqliteTimestamp("lease_expires_at"),
  lastErrorCode: text("last_error_code"),
  createdAt: sqliteTimestamp("created_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
}, (table) => [
  check("storage_delete_job_status_check", sql`${table.status} IN ('pending', 'processing', 'failed')`),
  index("storage_delete_job_claim_idx").on(table.status, table.availableAt, table.leaseExpiresAt),
]);

// Operational queue metadata only; canonical image/text access remains owner-scoped.
export const imageAnalysisJob = sqliteTable("jobs_image_analysis", {
  fileId: text("file_id").primaryKey().references(() => syncedFile.fileId, { onDelete: "cascade" }),
  vaultId: text("vault_id").notNull().references(() => syncedVault.vaultId, { onDelete: "cascade" }),
  ownerUserId: text("owner_user_id").notNull().references(() => authUser.id, { onDelete: "cascade" }),
  model: text("model").notNull(),
  status: text("status").default("pending").notNull(),
  attempts: integer("attempts").default(0).notNull(),
  availableAt: sqliteTimestamp("available_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
  claimedAt: sqliteTimestamp("claimed_at"),
  leaseExpiresAt: sqliteTimestamp("lease_expires_at"),
  lastErrorCode: text("last_error_code"),
}, (table) => [
  check("image_analysis_job_status_check", sql`${table.status} IN ('pending', 'processing', 'failed')`),
  index("image_analysis_job_claim_idx").on(table.status, table.availableAt, table.leaseExpiresAt),
]);

// Settings and input fingerprints are owner-private; no transcript or provider credentials are queued.
export const summaryJob = sqliteTable("jobs_summary", {
  encryptedPayload: text("encrypted_payload"),
  id: text("id").primaryKey(),
  vaultId: text("vault_id").notNull().references(() => syncedVault.vaultId, { onDelete: "cascade" }),
  meetingId: text("meeting_id").notNull().references(() => syncedMeeting.meetingId, { onDelete: "cascade" }),
  ownerUserId: text("owner_user_id").notNull().references(() => authUser.id, { onDelete: "cascade" }),
  method: text("method").$type<"transcript" | "audio">().notNull(),
  settings: text("settings", { mode: "json" }).$type<SummaryJob["settings"]>().notNull(),
  input: text("input", { mode: "json" }).$type<SummaryJob["input"]>(),
  stage: text("stage").$type<SummaryJob["stage"]>(),
  transcriptRevision: integer("transcript_revision"),
  transcriptResult: text("transcript_result", { mode: "json" }).$type<SummaryJob["transcriptResult"]>(),
  outputLanguage: text("output_language").notNull(),
  status: text("status").default("pending").notNull(),
  attempts: integer("attempts").default(0).notNull(),
  createdAt: sqliteTimestamp("created_at").notNull(),
  availableAt: sqliteTimestamp("available_at").notNull(),
  claimedAt: sqliteTimestamp("claimed_at"),
  leaseExpiresAt: sqliteTimestamp("lease_expires_at"),
  lastErrorCode: text("last_error_code"),
  summaryRevision: integer("summary_revision").notNull(),
  inputVersion: text("input_version").notNull(),
  requestHash: text("request_hash").notNull(),
}, (table) => [
  check("summary_job_status_check", sql`${table.status} IN ('pending', 'processing', 'succeeded', 'failed', 'cancelled')`),
  uniqueIndex("summary_job_active_meeting_idx").on(table.meetingId).where(sql`${table.status} IN ('pending', 'processing')`),
  index("summary_job_owner_created_idx").on(table.ownerUserId, table.createdAt),
]);

export const summary = sqliteTable("summaries", {
  encryptedPayload: text("encrypted_payload"),
  id: text("id").primaryKey(),
  meetingId: text("meeting_id").notNull(),
  version: integer("version").notNull(),
  title: text("title").notNull(),
  document: text("document").notNull(),
  createdAt: sqliteTimestamp("created_at"),
  savedAt: sqliteTimestamp("saved_at").notNull(),
  metadata: text("metadata", { mode: "json" }).$type<SummaryMetadata>(),
}, (table) => [
  unique("summary_meeting_version_unique").on(table.meetingId, table.version),
  foreignKey({ columns: [table.meetingId], foreignColumns: [syncedMeeting.meetingId] }).onDelete("cascade"),
]);

// Retained independently of Vault deletion and ordinary sync-history pruning.
export const vaultTransfer = sqliteTable("vault_transfers", {
  sequence: integer("sequence").primaryKey({ autoIncrement: true }),
  id: text("id").notNull().unique(),
  ownerUserId: text("owner_user_id").notNull().references(() => authUser.id, { onDelete: "cascade" }),
  idempotencyKey: text("idempotency_key").notNull(),
  requestHash: text("request_hash").notNull(),
  sourceVaultId: text("source_vault_id").notNull(),
  destinationVaultId: text("destination_vault_id").notNull(),
  manifest: text("manifest", { mode: "json" }).$type<{ projects: string[]; meetings: string[]; files: string[] }>().notNull(),
}, (table) => [
  unique("vault_transfer_owner_key_unique").on(table.ownerUserId, table.idempotencyKey),
  index("vault_transfer_owner_sequence_idx").on(table.ownerUserId, table.sequence),
]);

export const vaultKey = sqliteTable("vault_keys", {
  vaultId: text("vault_id").primaryKey(),
  ownerUserId: text("owner_user_id").notNull(),
  wrappedKey: text("wrapped_key").notNull(),
  createdAt: sqliteTimestamp("created_at").default(sql`(unixepoch() * 1000)`).notNull(),
});
