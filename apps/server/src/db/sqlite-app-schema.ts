import { sql } from "drizzle-orm";
import { blob, check, foreignKey, index, integer, primaryKey, real, sqliteTable, text, unique, uniqueIndex } from "drizzle-orm/sqlite-core";

import { user as authUser } from "./generated/sqlite-auth-schema";

const sqliteTimestamp = (name: string) => integer(name, { mode: "timestamp_ms" });

export const artifact = sqliteTable("artifact", {
  id: text("id").primaryKey(),
  ownerWorkspaceId: text("owner_workspace_id").notNull(),
  contentType: text("content_type").notNull(),
  storageKey: text("storage_key"),
  visibility: text("visibility").default("private").notNull(),
  createdAt: sqliteTimestamp("created_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
  updatedAt: sqliteTimestamp("updated_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
}, (table) => [
  check("artifact_visibility_check", sql`${table.visibility} IN ('private', 'public')`),
]);

export const syncedVault = sqliteTable("vaults", {
  vaultId: text("vault_id").primaryKey(),
  name: text("name").notNull(),
  revision: integer("revision").default(1).notNull(),
  deletingAt: sqliteTimestamp("deleting_at"),
  createdAt: sqliteTimestamp("created_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
  updatedAt: sqliteTimestamp("updated_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
});

export const syncedProject = sqliteTable("projects", {
  projectId: text("project_id").primaryKey(),
  vaultId: text("vault_id").notNull(),
  parentProjectId: text("parent_project_id"),
  name: text("name").notNull(),
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
  meetingId: text("meeting_id").primaryKey(),
  vaultId: text("vault_id").notNull(),
  projectId: text("project_id"),
  name: text("name").notNull(),
  description: text("description").default("").notNull(),
  status: text("status").notNull(),
  duration: real("duration"),
  recordingStartedAt: sqliteTimestamp("recording_started_at"),
  createdAt: sqliteTimestamp("created_at").notNull(),
  updatedAt: sqliteTimestamp("updated_at").notNull(),
  summaryTitle: text("summary_title"),
  summaryDocument: text("summary_document"),
  summaryCreatedAt: sqliteTimestamp("summary_created_at"),
  revision: integer("revision").default(1).notNull(),
  summaryRevision: integer("summary_revision").default(0).notNull(),
  transcriptRevision: integer("transcript_revision").default(0).notNull(),
  active: integer("active", { mode: "boolean" }).default(false).notNull(),
  deletingAt: sqliteTimestamp("deleting_at"),
}, (table) => [
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

export const syncedTranscriptSegment = sqliteTable("transcript_segments", {
  vaultId: text("vault_id").notNull(),
  meetingId: text("meeting_id").notNull(),
  segmentId: text("segment_id").notNull(),
  startTime: sqliteTimestamp("start_time").notNull(),
  endTime: sqliteTimestamp("end_time"),
  text: text("text").notNull(),
  isConfirmed: integer("is_confirmed", { mode: "boolean" }).notNull(),
  audioSource: text("audio_source"),
  speakerLabel: text("speaker_label"),
}, (table) => [
  primaryKey({
    columns: [table.vaultId, table.meetingId, table.segmentId],
  }),
  foreignKey({
    columns: [table.vaultId, table.meetingId],
    foreignColumns: [syncedMeeting.vaultId, syncedMeeting.meetingId],
  }).onDelete("cascade"),
  index("synced_transcript_vault_meeting_start_id_idx")
    .on(table.vaultId, table.meetingId, table.startTime, table.segmentId),
]);

export const transcriptPatchChunk = sqliteTable("transcript_patch_chunks", {
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

export const syncedScreenshot = sqliteTable("screenshots", {
  screenshotId: text("screenshot_id").primaryKey(),
  vaultId: text("vault_id").notNull(),
  meetingId: text("meeting_id").notNull(),
  capturedAt: sqliteTimestamp("captured_at").notNull(),
  contentType: text("content_type").notNull(),
  storageKey: text("storage_key").notNull(),
  contentLength: integer("content_length").notNull(),
  contentHash: text("content_hash").notNull(),
  active: integer("active", { mode: "boolean" }).default(true).notNull(),
  ocrText: text("ocr_text"),
  caption: text("caption"),
  revision: integer("revision").default(1).notNull(),
  createdAt: sqliteTimestamp("created_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
  updatedAt: sqliteTimestamp("updated_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
}, (table) => [
  foreignKey({
    columns: [table.vaultId, table.meetingId],
    foreignColumns: [syncedMeeting.vaultId, syncedMeeting.meetingId],
  }).onDelete("cascade"),
  index("synced_screenshot_vault_meeting_captured_id_idx")
    .on(table.vaultId, table.meetingId, table.capturedAt, table.screenshotId),
]);

export const searchDocument = sqliteTable("search_documents", {
  documentId: text("document_id").notNull(),
  vaultId: text("vault_id").notNull(),
  meetingId: text("meeting_id").notNull(),
  kind: text("kind").notNull(),
  searchText: text("search_text").default("").notNull(),
  embeddingText: text("embedding_text"),
  embeddingContentHash: text("embedding_content_hash"),
  updatedAt: sqliteTimestamp("updated_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
}, (table) => [
  primaryKey({ columns: [table.vaultId, table.documentId] }),
  foreignKey({
    columns: [table.vaultId, table.meetingId],
    foreignColumns: [syncedMeeting.vaultId, syncedMeeting.meetingId],
  }).onDelete("cascade"),
  check("search_document_kind_check", sql`${table.kind} IN ('meeting', 'screenshot')`),
  index("search_document_vault_kind_meeting_document_idx")
    .on(table.vaultId, table.kind, table.meetingId, table.documentId),
]);

export const searchEmbedding = sqliteTable("search_embeddings", {
  vaultId: text("vault_id").notNull(),
  documentId: text("document_id").notNull(),
  model: text("model").notNull(),
  dimensions: integer("dimensions").notNull(),
  contentHash: text("content_hash").notNull(),
  embedding: blob("embedding", { mode: "buffer" }).notNull(),
  updatedAt: sqliteTimestamp("updated_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
}, (table) => [
  primaryKey({ columns: [table.vaultId, table.documentId] }),
  foreignKey({
    columns: [table.vaultId, table.documentId],
    foreignColumns: [searchDocument.vaultId, searchDocument.documentId],
  }).onDelete("cascade"),
  check("search_embedding_dimensions_check", sql`${table.dimensions} BETWEEN 32 AND 1024`),
]);

export const searchIndexJob = sqliteTable("search_index_jobs", {
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
  check("sync_change_entity_check", sql`${table.entity} IN ('vault', 'project', 'meeting', 'summary', 'transcript', 'screenshot')`),
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

export const storageDeleteJob = sqliteTable("storage_delete_jobs", {
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
