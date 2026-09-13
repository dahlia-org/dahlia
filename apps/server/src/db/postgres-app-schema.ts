import type { CalendarEventSnapshot } from "../sync/schemas";
import type { TranscriptMetadata } from "../sync/transcript";
import type { SummaryMetadata } from "../summary/metadata";
import type { SummaryJob } from "../summary/model";
import type { RecordingRecord } from "../recordings/model";
import { sql } from "drizzle-orm";
import {
  type AnyPgColumn,
  bigint,
  bigserial,
  boolean,
  check,
  customType,
  doublePrecision,
  foreignKey,
  index,
  integer,
  jsonb,
  pgPolicy,
  pgSchema,
  primaryKey,
  real,
  text,
  timestamp,
  unique,
  uniqueIndex,
  uuid,
  varchar,
} from "drizzle-orm/pg-core";

import { fileMetadataLimits, type FileMetadata } from "../files/model";
import { DEFAULT_ACCOUNT_SETTINGS, type AccountSettings } from "../account-settings-model";
import { DEFAULT_SEARCH_SETTINGS, type SearchSettings } from "../search/settings-model";

import { user as authUser, organization as authOrganization } from "./generated/postgres-auth-schema";

export const appSchema = pgSchema("app");
export const jobsSchema = pgSchema("jobs");
export const searchSchema = pgSchema("search");
const tsvector = customType<{ data: string }>({ dataType: () => "tsvector" });

export const serverSettings = appSchema.table("server_settings", {
  id: integer("id").primaryKey(),
  searchWeights: jsonb("search_weights").$type<SearchSettings>().default(DEFAULT_SEARCH_SETTINGS).notNull(),
}, (table) => [check("server_settings_singleton", sql`${table.id} = 1`)]);

export const accountSettings = appSchema.table("account_settings", {
  userId: uuid("user_id").primaryKey().references(() => authUser.id, { onDelete: "cascade" }),
  summary: jsonb("summary").$type<AccountSettings["summary"]>().default(DEFAULT_ACCOUNT_SETTINGS.summary).notNull(),
  processing: jsonb("processing").$type<AccountSettings["processing"]>().default(DEFAULT_ACCOUNT_SETTINGS.processing).notNull(),
  revision: integer("revision").default(1).notNull(),
  outputLanguage: text("output_language").$type<AccountSettings["outputLanguage"]>().notNull(),
  analysisLanguages: jsonb("analysis_languages").$type<AccountSettings["analysisLanguages"]>().notNull(),
}, (table) => [
  pgPolicy("account_settings_owner", {
    for: "all",
    using: sql`${table.userId} = nullif(current_setting('app.user_id', true), '')::uuid`,
    withCheck: sql`${table.userId} = nullif(current_setting('app.user_id', true), '')::uuid`,
  }),
]).enableRLS();

const governanceWorkspace = (workspaceId: AnyPgColumn) => sql`current_setting('app.maintenance', true) = 'governance-delete' AND ${workspaceId} = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid`;

export const syncedWorkspace = appSchema.table("workspaces", {
  encryption: text("encryption").$type<"none" | "server">().default("none").notNull(),
  encryptedPayload: text("encrypted_payload"),
  workspaceId: uuid("workspace_id").primaryKey(),
  organizationId: uuid("organization_id").notNull().references(() => authOrganization.id, { onDelete: "restrict" }),
  createdBy: jsonb("created_by").$type<{ id: string; name: string; email: string }>().notNull(),
  name: text("name").notNull(),
  icon: text("icon"),
  color: text("color"),
  revision: integer("revision").default(1).notNull(),
  deletingAt: timestamp("deleting_at"),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
}, (table) => [
  check("workspace_encryption_check", sql`${table.encryption} IN ('none', 'server')`),
  pgPolicy("workspace_select", {
    for: "select",
    using: sql`"app"."current_identity_can_read_workspace"(${table.workspaceId}) OR (current_setting('app.maintenance', true) = 'search' AND ${table.workspaceId} = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR current_setting('app.maintenance', true) = 'authorization' OR (current_setting('app.maintenance', true) = 'governance' AND ${table.organizationId} = nullif(current_setting('app.maintenance_organization_id', true), '')::uuid) OR (${governanceWorkspace(table.workspaceId)})`,
  }),
  pgPolicy("workspace_insert", {
    for: "insert",
    withCheck: sql`coalesce(current_setting('app.user_id', true), '') <> ''`,
  }),
  pgPolicy("workspace_update", {
    for: "update",
    using: sql`"app"."current_identity_can_admin_workspace"(${table.workspaceId})`,
    withCheck: sql`"app"."current_identity_can_admin_workspace"(${table.workspaceId})`,
  }),
  pgPolicy("workspace_delete", {
    for: "delete",
    using: sql`"app"."current_identity_can_admin_workspace"(${table.workspaceId}) OR (${governanceWorkspace(table.workspaceId)})`,
  }),
]).enableRLS();

export const syncedProject = appSchema.table("projects", {
  encryptedPayload: text("encrypted_payload"),
  projectId: uuid("project_id").primaryKey(),
  workspaceId: uuid("workspace_id").notNull(),
  parentProjectId: uuid("parent_project_id"),
  name: text("name").notNull(),
  icon: text("icon"),
  color: text("color"),
  description: text("description").default("").notNull(),
  projectType: text("project_type"),
  revision: integer("revision").notNull(),
  createdAt: timestamp("created_at").notNull(),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
}, (table) => [
  unique("project_workspace_project_unique").on(table.workspaceId, table.projectId),
  foreignKey({
    name: "project_workspace_fk",
    columns: [table.workspaceId],
    foreignColumns: [syncedWorkspace.workspaceId],
  }).onDelete("cascade"),
  foreignKey({
    name: "project_parent_fk",
    columns: [table.workspaceId, table.parentProjectId],
    foreignColumns: [table.workspaceId, table.projectId],
  }).onDelete("restrict"),
  check("project_type_check", sql`(
    (${table.parentProjectId} IS NULL AND ${table.projectType} IN ('customer', 'internal', 'personal', 'undefined'))
    OR (${table.parentProjectId} IS NOT NULL AND ${table.projectType} IS NULL)
  )`),
  check("project_revision_check", sql`${table.revision} >= 1`),
  check("project_parent_check", sql`${table.parentProjectId} IS NULL OR ${table.parentProjectId} <> ${table.projectId}`),
  index("project_workspace_parent_name_idx").on(table.workspaceId, table.parentProjectId, table.name),
  pgPolicy("project_select", {
    for: "select",
    using: sql`"app"."current_identity_can_read_workspace"(${table.workspaceId})`,
  }),
  pgPolicy("project_insert", {
    for: "insert",
    withCheck: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId})`,
  }),
  pgPolicy("project_update", {
    for: "update",
    using: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId})`,
    withCheck: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId})`,
  }),
  pgPolicy("project_delete", {
    for: "delete",
    using: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId})`,
  }),
]).enableRLS();

export const syncedWorkspacePermission = appSchema.table("workspace_permissions", {
  workspaceId: uuid("workspace_id").notNull(),
  principalType: text("principal_type").notNull(),
  principalId: uuid("principal_id").notNull(),
  role: text("role").notNull(),
  grantedByUserId: uuid("granted_by_user_id").notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
}, (table) => [
  primaryKey({
    name: "workspace_permission_pk",
    columns: [table.workspaceId, table.principalType, table.principalId],
  }),
  foreignKey({
    name: "workspace_permission_workspace_fk",
    columns: [table.workspaceId],
    foreignColumns: [syncedWorkspace.workspaceId],
  }).onDelete("cascade"),
  foreignKey({
    name: "workspace_permission_granted_by_user_fk",
    columns: [table.grantedByUserId],
    foreignColumns: [authUser.id],
  }).onDelete("restrict"),
  check("workspace_permission_principal_type_check", sql`${table.principalType} IN ('user', 'organization', 'team')`),
  check("workspace_permission_role_check", sql`${table.role} IN ('admin', 'editor', 'viewer')`),
  index("workspace_permission_principal_workspace_idx")
    .on(table.principalType, table.principalId, table.role, table.workspaceId),
]);

export const syncedMeeting = appSchema.table("meetings", {
  encryptedPayload: text("encrypted_payload"),
  meetingId: uuid("meeting_id").primaryKey(),
  workspaceId: uuid("workspace_id").notNull(),
  projectId: uuid("project_id"),
  name: text("name").notNull(),
  description: text("description").default("").notNull(),
  status: text("status").notNull(),
  duration: doublePrecision("duration"),
  recordingStartedAt: timestamp("recording_started_at"),
  icalUid: text("ical_uid"),
  recurrenceId: text("recurrence_id"),
  calendarEvent: jsonb("calendar_event").$type<CalendarEventSnapshot>(),
  createdAt: timestamp("created_at").notNull(),
  updatedAt: timestamp("updated_at").notNull(),
  revision: integer("revision").default(1).notNull(),
  summaryRevision: integer("summary_revision").default(0).notNull(),
  transcriptRevision: integer("transcript_revision").default(0).notNull(),
  active: boolean("active").default(false).notNull(),
  deletingAt: timestamp("deleting_at"),
}, (table) => [
  index("meetings_calendar_event_idx").on(table.icalUid, table.recurrenceId),
  unique("synced_meeting_workspace_meeting_unique").on(table.workspaceId, table.meetingId),
  foreignKey({
    name: "synced_meeting_workspace_fk",
    columns: [table.workspaceId],
    foreignColumns: [syncedWorkspace.workspaceId],
  }).onDelete("cascade"),
  foreignKey({
    name: "synced_meeting_project_fk",
    columns: [table.workspaceId, table.projectId],
    foreignColumns: [syncedProject.workspaceId, syncedProject.projectId],
  }),
  index("synced_meeting_workspace_created_id_idx").on(table.workspaceId, table.createdAt, table.meetingId),
  pgPolicy("meeting_select", {
    for: "select",
    using: sql`"app"."current_identity_can_read_workspace"(${table.workspaceId}) OR (current_setting('app.maintenance', true) IN ('search', 'storage', 'governance-delete') AND ${table.workspaceId} = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid)`,
  }),
  pgPolicy("meeting_write", {
    for: "all",
    using: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId})`,
    withCheck: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId})`,
  }),
]).enableRLS();

// Domain history survives meeting deletion; Workspace deletion removes it.
export const meetingEvent = appSchema.table("meeting_events", {
  id: uuid("id").primaryKey(),
  workspaceId: uuid("workspace_id").notNull().references(() => syncedWorkspace.workspaceId, { onDelete: "cascade" }),
  ownerUserId: uuid("owner_user_id").notNull().references(() => authUser.id, { onDelete: "cascade" }),
  meetingId: uuid("meeting_id").notNull(),
  kind: text("kind").notNull(),
  occurredAt: timestamp("occurred_at").notNull(),
  receivedAt: timestamp("received_at").notNull(),
  sessionId: uuid("session_id"),
  relatedId: text("related_id"),
  audioSource: text("audio_source"),
  segmentIndex: integer("segment_index"),
  changedFields: text("changed_fields"),
}, (table) => [
  index("meeting_events_meeting_time_idx").on(table.workspaceId, table.meetingId, table.occurredAt, table.id),
  index("meeting_events_session_idx").on(table.workspaceId, table.sessionId),
  check("meeting_events_kind_check", sql`${table.kind} IN ('meeting_created', 'meeting_updated', 'meeting_deleted', 'tag_added', 'tag_removed', 'recording_started', 'recording_ended', 'segment_rotated')`),
  check("meeting_events_source_check", sql`${table.audioSource} IN ('mic', 'system')`),
  pgPolicy("meeting_event_select", { for: "select", using: sql`"app"."current_identity_can_read_workspace"(${table.workspaceId}) OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.workspace_id = ${table.workspaceId} AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid)` }),
  pgPolicy("meeting_event_write", { for: "all", using: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId}) OR current_setting('app.maintenance', true) = 'rotation'`, withCheck: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId}) OR current_setting('app.maintenance', true) = 'rotation'` }),
]).enableRLS();

export const recordingSession = appSchema.view("recording_sessions", {
  workspaceId: uuid("workspace_id").notNull(),
  meetingId: uuid("meeting_id").notNull(),
  sessionId: uuid("session_id").notNull(),
  startedAt: timestamp("started_at"),
  endedAt: timestamp("ended_at"),
}).with({ securityInvoker: true }).as(sql`
  SELECT workspace_id, meeting_id, session_id,
    min(CASE WHEN kind = 'recording_started' THEN occurred_at END) AS started_at,
    max(CASE WHEN kind = 'recording_ended' THEN occurred_at END) AS ended_at
  FROM app.meeting_events
  WHERE session_id IS NOT NULL AND kind IN ('recording_started', 'recording_ended')
  GROUP BY workspace_id, meeting_id, session_id
`);

export const transcript = appSchema.table("transcripts", {
  encryptedPayload: text("encrypted_payload"),
  id: uuid("id").primaryKey(),
  meetingId: uuid("meeting_id").notNull(),
  version: integer("version").notNull(),
  syncRevision: integer("sync_revision").notNull(),
  startedAt: timestamp("started_at"),
  endedAt: timestamp("ended_at"),
  createdAt: timestamp("created_at").notNull(),
  metadata: jsonb("metadata").$type<TranscriptMetadata>(),
}, (table) => [
  unique("transcript_meeting_version_unique").on(table.meetingId, table.version),
  foreignKey({ columns: [table.meetingId], foreignColumns: [syncedMeeting.meetingId] }).onDelete("cascade"),
  check("transcript_version_check", sql`${table.version} >= 1`),
  pgPolicy("transcript_version_select", { for: "select", using: sql`exists (select 1 from "app"."meetings" m where m.meeting_id = ${table.meetingId} and "app"."current_identity_can_read_workspace"(m.workspace_id))` }),
  pgPolicy("transcript_version_write", { for: "all", using: sql`exists (select 1 from "app"."meetings" m where m.meeting_id = ${table.meetingId} and "app"."current_identity_can_write_workspace"(m.workspace_id))`, withCheck: sql`exists (select 1 from "app"."meetings" m where m.meeting_id = ${table.meetingId} and "app"."current_identity_can_write_workspace"(m.workspace_id))` }),
]).enableRLS();

export const syncedTranscriptSegment = appSchema.table("transcript_segments", {
  encryptedPayload: text("encrypted_payload"),
  transcriptId: uuid("transcript_id").notNull(),
  segmentId: uuid("segment_id").notNull(),
  startedAt: timestamp("started_at").notNull(),
  endedAt: timestamp("ended_at"),
  text: text("text").notNull(),
  createdAt: timestamp("created_at"),
  audioSource: text("audio_source"),
  speakerLabel: text("speaker_label"),
  normalizedCharacterCount: integer("normalized_character_count"),
}, (table) => [
  primaryKey({
    name: "synced_transcript_segment_pk",
    columns: [table.transcriptId, table.segmentId],
  }),
  foreignKey({
    name: "transcript_segment_transcript_fk",
    columns: [table.transcriptId],
    foreignColumns: [transcript.id],
  }).onDelete("cascade"),
  index("transcript_segment_created_idx").on(table.transcriptId, table.createdAt),
  index("transcript_segment_start_id_idx")
    .on(table.transcriptId, table.startedAt, table.segmentId),
  check("transcript_segment_normalized_character_count_check", sql`${table.normalizedCharacterCount} IS NULL OR ${table.normalizedCharacterCount} >= 0`),
  pgPolicy("transcript_select", {
    for: "select",
    using: sql`exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = ${table.transcriptId} and "app"."current_identity_can_read_workspace"(m.workspace_id))`,
  }),
  pgPolicy("transcript_write", {
    for: "all",
    using: sql`exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = ${table.transcriptId} and "app"."current_identity_can_write_workspace"(m.workspace_id))`,
    withCheck: sql`exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = ${table.transcriptId} and "app"."current_identity_can_write_workspace"(m.workspace_id))`,
  }),
]).enableRLS();

export const transcriptPatchChunk = appSchema.table("transcript_patch_chunks", {
  encryptedPayload: text("encrypted_payload"),
  workspaceId: uuid("workspace_id").notNull(),
  meetingId: uuid("meeting_id").notNull(),
  patchId: uuid("patch_id").notNull(),
  chunkIndex: integer("chunk_index").notNull(),
  contentHash: text("content_hash").notNull(),
  payload: jsonb("payload").notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
}, (table) => [
  primaryKey({
    name: "transcript_patch_chunk_pk",
    columns: [table.workspaceId, table.meetingId, table.patchId, table.chunkIndex],
  }),
  foreignKey({
    name: "transcript_patch_chunk_meeting_fk",
    columns: [table.workspaceId, table.meetingId],
    foreignColumns: [syncedMeeting.workspaceId, syncedMeeting.meetingId],
  }).onDelete("cascade"),
  pgPolicy("transcript_patch_select", {
    for: "select",
    using: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId})`,
  }),
  pgPolicy("transcript_patch_write", {
    for: "all",
    using: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId})`,
    withCheck: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId})`,
  }),
]).enableRLS();

export const syncedFile = appSchema.table("files", {
  encryptedPayload: text("encrypted_payload"),
  fileId: uuid("file_id").primaryKey(),
  workspaceId: uuid("workspace_id").notNull().references(() => syncedWorkspace.workspaceId, { onDelete: "cascade" }),
  uri: text("uri").notNull(),
  offset: bigint("offset", { mode: "number" }).notNull().default(0),
  size: bigint("size", { mode: "number" }).notNull(),
  contentType: text("content_type").notNull(),
  checksum: text("checksum").notNull(),
  name: text("name").notNull(),
  metadata: jsonb("metadata").$type<FileMetadata>().notNull(),
  active: boolean("active").default(false).notNull(),
  uploadedAt: timestamp("uploaded_at"),
  revision: integer("revision").default(0).notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
}, (table) => [
  unique("files_workspace_file_unique").on(table.workspaceId, table.fileId),
  index("files_workspace_file_idx").on(table.workspaceId, table.fileId),
  check("files_offset_check", sql`${table.offset} = 0`),
  check("files_size_check", sql`${table.size} >= 0`),
  check("files_metadata_ocr_text_length_check", sql`char_length(${table.metadata}->>'ocr_text') <= ${fileMetadataLimits.postgres.ocrText}`),
  check("files_metadata_caption_length_check", sql`char_length(${table.metadata}->>'caption') <= ${fileMetadataLimits.postgres.caption}`),
  pgPolicy("file_select", { for: "select", using: sql`"app"."current_identity_can_read_workspace"(${table.workspaceId}) OR (${governanceWorkspace(table.workspaceId)}) OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.workspace_id = ${table.workspaceId} AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid)` }),
  pgPolicy("file_write", { for: "all", using: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId})`, withCheck: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId})` })
]).enableRLS();


export const syncedRecording = appSchema.table("recordings", {
  sessionId: uuid("session_id").primaryKey(),
  meetingId: uuid("meeting_id").notNull(),
  number: integer("number").notNull(),
  startedAt: timestamp("started_at").notNull(),
  endedAt: timestamp("ended_at").notNull(),
  audio: jsonb("audio").$type<RecordingRecord["audio"]>().notNull(),
  revision: integer("revision").default(0).notNull(),
  createdAt: timestamp("created_at").notNull(),
  updatedAt: timestamp("updated_at").notNull(),
}, (table) => [
  foreignKey({ columns: [table.meetingId], foreignColumns: [syncedMeeting.meetingId] }).onDelete("cascade"),
  unique("recordings_meeting_number_unique").on(table.meetingId, table.number),
  index("recordings_meeting_session_idx").on(table.meetingId, table.sessionId),
  check("recordings_number_check", sql`${table.number} > 0`),
  pgPolicy("recording_select", { for: "select", using: sql`EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = ${table.meetingId} AND ("app"."current_identity_can_read_workspace"("workspace_id") OR (current_setting('app.maintenance', true) IN ('storage', 'governance-delete') AND "workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid)))` }),
  pgPolicy("recording_write", { for: "all", using: sql`EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = ${table.meetingId} AND ("app"."current_identity_can_write_workspace"("workspace_id") OR (current_setting('app.maintenance', true) IN ('storage', 'governance-delete') AND "workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid)))`, withCheck: sql`EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = ${table.meetingId} AND ("app"."current_identity_can_write_workspace"("workspace_id") OR (current_setting('app.maintenance', true) IN ('storage', 'governance-delete') AND "workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid)))` }),
]).enableRLS();

export const meetingAttachment = appSchema.table("meeting_attachments", {
  id: uuid("id").primaryKey(),
  workspaceId: uuid("workspace_id").notNull(),
  meetingId: uuid("meeting_id").notNull(),
  fileId: uuid("file_id").notNull(),
  capturedAt: timestamp("captured_at"),
  sessionId: uuid("session_id"),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  revision: integer("revision").default(1).notNull(),
}, (table) => [
  foreignKey({ columns: [table.workspaceId, table.meetingId], foreignColumns: [syncedMeeting.workspaceId, syncedMeeting.meetingId] }).onDelete("cascade"),
  foreignKey({ columns: [table.workspaceId, table.fileId], foreignColumns: [syncedFile.workspaceId, syncedFile.fileId] }),
  unique("meeting_attachments_meeting_attachment_unique").on(table.meetingId, table.fileId),
  index("meeting_attachments_workspace_meeting_id_idx").on(table.workspaceId, table.meetingId, table.id),
  pgPolicy("meeting_attachment_select", { for: "select", using: sql`"app"."current_identity_can_read_workspace"(${table.workspaceId}) OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.workspace_id = ${table.workspaceId} AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid)` }),
  pgPolicy("meeting_attachment_write", { for: "all", using: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId})`, withCheck: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId})` })
]).enableRLS();

// Read-only image projection. All writes belong to files and meeting_attachments.
export const syncedScreenshot = appSchema.view("meeting_images", {
  screenshotId: uuid("screenshot_id").notNull(),
  fileId: uuid("file_id").notNull(),
  workspaceId: uuid("workspace_id").notNull(),
  meetingId: uuid("meeting_id").notNull(),
  capturedAt: timestamp("captured_at").notNull(),
  contentType: text("content_type").notNull(),
  storageKey: text("storage_key").notNull(),
  contentLength: bigint("content_length", { mode: "number" }).notNull(),
  contentHash: text("content_hash").notNull(),
  active: boolean("active").notNull(),
  ocrText: text("ocr_text"),
  caption: text("caption"),
  revision: integer("revision").notNull(),
}).with({ securityInvoker: true }).as(sql`
  SELECT m.id AS screenshot_id, f.file_id, m.workspace_id, m.meeting_id,
    coalesce(m.captured_at, m.created_at) AS captured_at, f.content_type,
    'files/' || f.file_id || '/original' AS storage_key,
    f.size AS content_length, substr(f.checksum, 9) AS content_hash, f.active,
    f.metadata ->> 'ocr_text' AS ocr_text,
    f.metadata ->> 'caption' AS caption,
    m.revision
  FROM app.meeting_attachments m JOIN app.files f ON f.file_id = m.file_id AND f.workspace_id = m.workspace_id
  WHERE f.metadata ->> 'source' = 'screenshot'
`);

export const searchDocument = searchSchema.table("documents", {
  documentId: uuid("document_id").notNull(),
  workspaceId: uuid("workspace_id").notNull(),
  meetingId: uuid("meeting_id").notNull(),
  kind: text("kind").notNull(),
  searchText: text("search_text").default("").notNull(),
  titleText: text("title_text").default("").notNull(),
  tagsText: text("tags_text").default("").notNull(),
  descriptionText: text("description_text").default("").notNull(),
  summaryText: text("summary_text").default("").notNull(),
  ocrText: varchar("ocr_text", { length: fileMetadataLimits.postgres.ocrText }).default("").notNull(),
  captionText: varchar("caption_text", { length: fileMetadataLimits.postgres.caption }).default("").notNull(),
  titleVector: tsvector("title_vector").generatedAlwaysAs(sql`to_tsvector('simple', title_text)`),
  tagsVector: tsvector("tags_vector").generatedAlwaysAs(sql`to_tsvector('simple', tags_text)`),
  descriptionVector: tsvector("description_vector").generatedAlwaysAs(sql`to_tsvector('simple', description_text)`),
  summaryVector: tsvector("summary_vector").generatedAlwaysAs(sql`to_tsvector('simple', summary_text)`),
  ocrVector: tsvector("ocr_vector").generatedAlwaysAs(sql`to_tsvector('simple', ocr_text)`),
  captionVector: tsvector("caption_vector").generatedAlwaysAs(sql`to_tsvector('simple', caption_text)`),
  searchVector: tsvector("search_vector")
    .generatedAlwaysAs(sql`to_tsvector('simple', search_text)`),
  embeddingContentHash: text("embedding_content_hash"),
  embedding: real("embedding").array(),
  embeddingModel: text("embedding_model"),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
}, (table) => [
  primaryKey({ name: "search_document_pk", columns: [table.workspaceId, table.documentId] }),
  foreignKey({
    name: "search_document_meeting_fk",
    columns: [table.workspaceId, table.meetingId],
    foreignColumns: [syncedMeeting.workspaceId, syncedMeeting.meetingId],
  }).onDelete("cascade"),
  check("search_document_embedding_dimensions_check", sql`${table.embedding} IS NULL OR cardinality(${table.embedding}) BETWEEN 32 AND 1024`),
  check("search_document_kind_check", sql`${table.kind} IN ('meeting', 'screenshot')`),
  index("search_document_workspace_kind_meeting_document_idx")
    .on(table.workspaceId, table.kind, table.meetingId, table.documentId),
  pgPolicy("search_document_select", {
    for: "select",
    using: sql`"app"."current_identity_can_read_workspace"(${table.workspaceId}) OR (current_setting('app.maintenance', true) = 'search' AND ${table.workspaceId} = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid)`,
  }),
  pgPolicy("search_document_write", {
    for: "all",
    using: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId}) OR (current_setting('app.maintenance', true) = 'search' AND ${table.workspaceId} = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid)`,
    withCheck: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId}) OR (current_setting('app.maintenance', true) = 'search' AND ${table.workspaceId} = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid)`,
  }),
]).enableRLS();

export const searchIndexJob = jobsSchema.table("search_index", {
  workspaceId: uuid("workspace_id").notNull(),
  documentId: uuid("document_id").notNull(),
  model: text("model").notNull(),
  dimensions: integer("dimensions").notNull(),
  generation: integer("generation").default(1).notNull(),
  status: text("status").default("pending").notNull(),
  attempts: integer("attempts").default(0).notNull(),
  availableAt: timestamp("available_at").defaultNow().notNull(),
  claimedAt: timestamp("claimed_at"),
  leaseExpiresAt: timestamp("lease_expires_at"),
  lastErrorCode: text("last_error_code"),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
}, (table) => [
  primaryKey({ name: "search_index_job_pk", columns: [table.workspaceId, table.documentId] }),
  foreignKey({
    name: "search_index_job_workspace_fk",
    columns: [table.workspaceId],
    foreignColumns: [syncedWorkspace.workspaceId],
  }).onDelete("cascade"),
  check("search_index_job_status_check", sql`${table.status} IN ('pending', 'processing', 'failed')`),
  check("search_index_job_dimensions_check", sql`${table.dimensions} BETWEEN 32 AND 1024`),
  index("search_index_job_claim_idx").on(table.status, table.availableAt, table.leaseExpiresAt),
]);

export const syncTransactionReceipt = appSchema.table("transaction_receipts", {
  encryptedPayload: text("encrypted_payload"),
  transactionId: uuid("transaction_id").primaryKey(),
  ownerUserId: uuid("owner_user_id").notNull(),
  workspaceId: uuid("workspace_id").notNull(),
  requestHash: text("request_hash").notNull(),
  responseJson: jsonb("response_json"),
  resultsJson: jsonb("results_json").default(sql`'[]'::jsonb`).notNull(),
  cursor: bigint("cursor", { mode: "number" }).notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
}, (table) => [
  foreignKey({
    name: "transaction_receipt_owner_user_fk",
    columns: [table.ownerUserId],
    foreignColumns: [authUser.id],
  }).onDelete("cascade"),
  index("transaction_receipt_owner_created_idx").on(table.ownerUserId, table.createdAt),
  pgPolicy("transaction_receipt_owner", {
    for: "all",
    using: sql`${table.ownerUserId} = nullif(current_setting('app.user_id', true), '')::uuid OR current_setting('app.maintenance', true) = 'retention'`,
    withCheck: sql`${table.ownerUserId} = nullif(current_setting('app.user_id', true), '')::uuid OR current_setting('app.maintenance', true) = 'retention'`,
  }),
]).enableRLS();

export const syncChange = appSchema.table("sync_changes", {
  sequence: bigserial("sequence", { mode: "number" }).primaryKey(),
  workspaceId: uuid("workspace_id").notNull(),
  entity: text("entity").notNull(),
  entityId: uuid("entity_id").notNull(),
  action: text("action").notNull(),
  revision: integer("revision"),
  transactionId: uuid("transaction_id").notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
}, (table) => [
  check("sync_change_entity_check", sql`${table.entity} IN ('workspace', 'project', 'meeting', 'summary', 'transcript', 'file', 'meeting_attachment', 'recording')`),
  check("sync_change_action_check", sql`${table.action} IN ('upsert', 'delete', 'reset')`),
  index("sync_change_workspace_sequence_idx").on(table.workspaceId, table.sequence),
]);

// Survives Workspace deletion and ledger pruning; contains no canonical content.
export const syncWorkspaceState = appSchema.table("sync_workspace_state", {
  workspaceId: uuid("workspace_id").notNull(),
  latestSequence: bigint("latest_sequence", { mode: "number" }).default(0).notNull(),
  prunedThrough: bigint("pruned_through", { mode: "number" }).default(0).notNull(),
}, (table) => [
  primaryKey({ columns: [table.workspaceId] }),
  check("sync_workspace_state_boundary_check", sql`${table.prunedThrough} >= 0 AND ${table.latestSequence} >= ${table.prunedThrough}`),
]);

export const storageDeleteJob = jobsSchema.table("storage_delete", {
  storageKey: text("storage_key").primaryKey(),
  attempts: integer("attempts").default(0).notNull(),
  status: text("status").default("pending").notNull(),
  availableAt: timestamp("available_at").defaultNow().notNull(),
  claimedAt: timestamp("claimed_at"),
  leaseExpiresAt: timestamp("lease_expires_at"),
  lastErrorCode: text("last_error_code"),
  createdAt: timestamp("created_at").defaultNow().notNull(),
}, (table) => [
  check("storage_delete_job_status_check", sql`${table.status} IN ('pending', 'processing', 'failed')`),
  index("storage_delete_job_claim_idx").on(table.status, table.availableAt, table.leaseExpiresAt),
]);

// Operational queue metadata only; canonical image/text access remains owner-scoped.
export const imageAnalysisJob = jobsSchema.table("image_analysis", {
  fileId: uuid("file_id").primaryKey(),
  workspaceId: uuid("workspace_id").notNull(),
  ownerUserId: uuid("owner_user_id").notNull(),
  model: text("model").notNull(),
  status: text("status").default("pending").notNull(),
  attempts: integer("attempts").default(0).notNull(),
  availableAt: timestamp("available_at").defaultNow().notNull(),
  claimedAt: timestamp("claimed_at"),
  leaseExpiresAt: timestamp("lease_expires_at"),
  lastErrorCode: text("last_error_code"),
}, (table) => [
  foreignKey({ name: "jobs_image_analysis_file_id_files_file_id_fkey", columns: [table.fileId], foreignColumns: [syncedFile.fileId] }).onDelete("cascade"),
  foreignKey({ name: "jobs_image_analysis_workspace_id_workspaces_workspace_id_fkey", columns: [table.workspaceId], foreignColumns: [syncedWorkspace.workspaceId] }).onDelete("cascade"),
  foreignKey({ name: "jobs_image_analysis_owner_user_id_user_id_fkey", columns: [table.ownerUserId], foreignColumns: [authUser.id] }).onDelete("cascade"),
  check("image_analysis_job_status_check", sql`${table.status} IN ('pending', 'processing', 'failed')`),
  index("image_analysis_job_claim_idx").on(table.status, table.availableAt, table.leaseExpiresAt),
]);

// Settings and input fingerprints are owner-private; no transcript or provider credentials are queued.
export const summaryJob = jobsSchema.table("summary", {
  encryptedPayload: text("encrypted_payload"),
  id: uuid("id").primaryKey(),
  workspaceId: uuid("workspace_id").notNull(),
  meetingId: uuid("meeting_id").notNull(),
  ownerUserId: uuid("owner_user_id").notNull(),
  method: text("method").$type<"transcript" | "audio">().notNull(),
  settings: jsonb("settings").$type<SummaryJob["settings"]>().notNull(),
  input: jsonb("input").$type<SummaryJob["input"]>(),
  stage: text("stage").$type<SummaryJob["stage"]>(),
  transcriptRevision: integer("transcript_revision"),
  transcriptResult: jsonb("transcript_result").$type<SummaryJob["transcriptResult"]>(),
  outputLanguage: text("output_language").notNull(),
  status: text("status").default("pending").notNull(),
  attempts: integer("attempts").default(0).notNull(),
  createdAt: timestamp("created_at").notNull(),
  availableAt: timestamp("available_at").notNull(),
  claimedAt: timestamp("claimed_at"),
  leaseExpiresAt: timestamp("lease_expires_at"),
  lastErrorCode: text("last_error_code"),
  summaryRevision: integer("summary_revision").notNull(),
  inputVersion: text("input_version").notNull(),
  requestHash: text("request_hash").notNull(),
}, (table) => [
  foreignKey({ name: "jobs_summary_workspace_id_workspaces_workspace_id_fkey", columns: [table.workspaceId], foreignColumns: [syncedWorkspace.workspaceId] }).onDelete("cascade"),
  foreignKey({ name: "jobs_summary_meeting_id_meetings_meeting_id_fkey", columns: [table.meetingId], foreignColumns: [syncedMeeting.meetingId] }).onDelete("cascade"),
  foreignKey({ name: "jobs_summary_owner_user_id_user_id_fkey", columns: [table.ownerUserId], foreignColumns: [authUser.id] }).onDelete("cascade"),
  check("summary_job_status_check", sql`${table.status} IN ('pending', 'processing', 'succeeded', 'failed', 'cancelled')`),
  uniqueIndex("summary_job_active_meeting_idx").on(table.meetingId).where(sql`${table.status} IN ('pending', 'processing')`),
  index("summary_job_owner_created_idx").on(table.ownerUserId, table.createdAt),
  pgPolicy("summary_job_owner", {
    for: "all", using: sql`${table.ownerUserId} = nullif(current_setting('app.user_id', true), '')::uuid`,
    withCheck: sql`${table.ownerUserId} = nullif(current_setting('app.user_id', true), '')::uuid`,
  }),
]).enableRLS();

export const summary = appSchema.table("summaries", {
  encryptedPayload: text("encrypted_payload"),
  id: uuid("id").primaryKey(),
  meetingId: uuid("meeting_id").notNull(),
  version: integer("version").notNull(),
  title: text("title").notNull(),
  document: text("document").notNull(),
  createdAt: timestamp("created_at"),
  savedAt: timestamp("saved_at").notNull(),
  metadata: jsonb("metadata").$type<SummaryMetadata>(),
}, (table) => [
  unique("summary_meeting_version_unique").on(table.meetingId, table.version),
  foreignKey({ columns: [table.meetingId], foreignColumns: [syncedMeeting.meetingId] }).onDelete("cascade"),
  pgPolicy("summary_select", { for: "select", using: sql`EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = ${table.meetingId} AND "app"."current_identity_can_read_workspace"(m.workspace_id))` }),
  pgPolicy("summary_write", { for: "all", using: sql`EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = ${table.meetingId} AND "app"."current_identity_can_write_workspace"(m.workspace_id))`, withCheck: sql`EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = ${table.meetingId} AND "app"."current_identity_can_write_workspace"(m.workspace_id))` }),
]).enableRLS();

// Retained independently of Workspace deletion and ordinary sync-history pruning.
export const workspaceTransfer = appSchema.table("workspace_transfers", {
  sequence: bigserial("sequence", { mode: "number" }).primaryKey(),
  id: uuid("id").notNull().unique(),
  ownerUserId: uuid("owner_user_id").notNull().references(() => authUser.id, { onDelete: "cascade" }),
  idempotencyKey: uuid("idempotency_key").notNull(),
  requestHash: text("request_hash").notNull(),
  sourceWorkspaceId: uuid("source_workspace_id").notNull(),
  destinationWorkspaceId: uuid("destination_workspace_id").notNull(),
  manifest: jsonb("manifest").$type<{ projects: string[]; meetings: string[]; files: string[] }>().notNull(),
}, (table) => [
  unique("workspace_transfer_owner_key_unique").on(table.ownerUserId, table.idempotencyKey),
  index("workspace_transfer_owner_sequence_idx").on(table.ownerUserId, table.sequence),
  pgPolicy("workspace_transfer_reader", {
    for: "select",
    using: sql`"app"."current_identity_can_read_workspace"(${table.sourceWorkspaceId}) OR "app"."current_identity_can_read_workspace"(${table.destinationWorkspaceId})`,
  }),
  pgPolicy("workspace_transfer_owner", {
    for: "all",
    using: sql`${table.ownerUserId} = nullif(current_setting('app.user_id', true), '')::uuid`,
    withCheck: sql`${table.ownerUserId} = nullif(current_setting('app.user_id', true), '')::uuid`,
  }),
]).enableRLS();

export const cryptoSchema = pgSchema("crypto");
export const workspaceKey = cryptoSchema.table("workspace_keys", {
  workspaceId: uuid("workspace_id").primaryKey(),
  wrappedKey: text("wrapped_key").notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
}, (table) => [
  pgPolicy("workspace_key_read", { for: "select", using: sql`"app"."current_identity_can_read_workspace"(${table.workspaceId}) OR (${governanceWorkspace(table.workspaceId)}) OR (current_setting('app.maintenance', true) = 'governance' AND EXISTS (SELECT 1 FROM app.workspaces v WHERE v.workspace_id = ${table.workspaceId} AND v.organization_id = nullif(current_setting('app.maintenance_organization_id', true), '')::uuid)) OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.workspace_id = ${table.workspaceId} AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid)` }),
  pgPolicy("workspace_key_write", { for: "all", using: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId}) OR current_setting('app.maintenance', true) = 'rotation'`, withCheck: sql`"app"."current_identity_can_write_workspace"(${table.workspaceId}) OR current_setting('app.maintenance', true) = 'rotation'` }),
]).enableRLS();
