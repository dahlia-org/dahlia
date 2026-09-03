import { sql } from "drizzle-orm";
import {
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
  pgSchema,
  primaryKey,
  real,
  text,
  timestamp,
  unique,
  uniqueIndex,
  uuid,
} from "drizzle-orm/pg-core";

import { user as authUser } from "./generated/postgres-auth-schema";

export const coreSchema = pgSchema("core");
export const contentSchema = pgSchema("content");
const tsvector = customType<{ data: string }>({ dataType: () => "tsvector" });

export const modelAlias = coreSchema.table("model_alias", {
  alias: text("alias").primaryKey(),
  upstreamModel: text("upstream_model").notNull(),
  displayName: text("display_name"),
  enabled: boolean("enabled").default(true).notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
});

export const artifact = coreSchema.table("artifact", {
  id: uuid("id").primaryKey(),
  ownerWorkspaceId: text("owner_workspace_id").notNull(),
  contentType: text("content_type").notNull(),
  storageKey: text("storage_key"),
  visibility: text("visibility").default("private").notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
}, (table) => [
  check("artifact_visibility_check", sql`${table.visibility} IN ('private', 'public')`),
]);

export const syncedVault = coreSchema.table("vaults", {
  vaultId: uuid("vault_id").primaryKey(),
  name: text("name").notNull(),
  revision: integer("revision").default(1).notNull(),
  deletingAt: timestamp("deleting_at"),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
});

export const syncedProject = coreSchema.table("projects", {
  projectId: uuid("project_id").primaryKey(),
  vaultId: uuid("vault_id").notNull(),
  parentProjectId: uuid("parent_project_id"),
  name: text("name").notNull(),
  description: text("description").default("").notNull(),
  projectType: text("project_type"),
  revision: integer("revision").notNull(),
  createdAt: timestamp("created_at").notNull(),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
}, (table) => [
  unique("project_vault_project_unique").on(table.vaultId, table.projectId),
  foreignKey({
    name: "project_vault_fk",
    columns: [table.vaultId],
    foreignColumns: [syncedVault.vaultId],
  }).onDelete("cascade"),
  foreignKey({
    name: "project_parent_fk",
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

export const syncedVaultPermission = coreSchema.table("vault_permissions", {
  vaultId: uuid("vault_id").notNull(),
  principalType: text("principal_type").notNull(),
  principalId: text("principal_id").notNull(),
  role: text("role").notNull(),
  grantedByUserId: text("granted_by_user_id").notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
}, (table) => [
  primaryKey({
    name: "vault_permission_pk",
    columns: [table.vaultId, table.principalType, table.principalId],
  }),
  foreignKey({
    name: "vault_permission_vault_fk",
    columns: [table.vaultId],
    foreignColumns: [syncedVault.vaultId],
  }).onDelete("cascade"),
  foreignKey({
    name: "vault_permission_granted_by_user_fk",
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

export const syncedMeeting = contentSchema.table("meetings", {
  meetingId: uuid("meeting_id").primaryKey(),
  vaultId: uuid("vault_id").notNull(),
  projectId: uuid("project_id"),
  name: text("name").notNull(),
  description: text("description").default("").notNull(),
  status: text("status").notNull(),
  duration: doublePrecision("duration"),
  recordingStartedAt: timestamp("recording_started_at"),
  createdAt: timestamp("created_at").notNull(),
  updatedAt: timestamp("updated_at").notNull(),
  summaryTitle: text("summary_title"),
  summaryDocument: text("summary_document"),
  summaryCreatedAt: timestamp("summary_created_at"),
  revision: integer("revision").default(1).notNull(),
  summaryRevision: integer("summary_revision").default(0).notNull(),
  transcriptRevision: integer("transcript_revision").default(0).notNull(),
  active: boolean("active").default(false).notNull(),
  deletingAt: timestamp("deleting_at"),
}, (table) => [
  unique("synced_meeting_vault_meeting_unique").on(table.vaultId, table.meetingId),
  foreignKey({
    name: "synced_meeting_vault_fk",
    columns: [table.vaultId],
    foreignColumns: [syncedVault.vaultId],
  }).onDelete("cascade"),
  foreignKey({
    name: "synced_meeting_project_fk",
    columns: [table.vaultId, table.projectId],
    foreignColumns: [syncedProject.vaultId, syncedProject.projectId],
  }),
  index("synced_meeting_vault_created_id_idx").on(table.vaultId, table.createdAt, table.meetingId),
]);

export const syncedTranscriptSegment = contentSchema.table("transcript_segments", {
  vaultId: uuid("vault_id").notNull(),
  meetingId: uuid("meeting_id").notNull(),
  segmentId: uuid("segment_id").notNull(),
  startTime: timestamp("start_time").notNull(),
  endTime: timestamp("end_time"),
  text: text("text").notNull(),
  isConfirmed: boolean("is_confirmed").notNull(),
  audioSource: text("audio_source"),
  speakerLabel: text("speaker_label"),
}, (table) => [
  primaryKey({
    name: "synced_transcript_segment_pk",
    columns: [table.vaultId, table.meetingId, table.segmentId],
  }),
  foreignKey({
    name: "synced_transcript_segment_meeting_fk",
    columns: [table.vaultId, table.meetingId],
    foreignColumns: [syncedMeeting.vaultId, syncedMeeting.meetingId],
  }).onDelete("cascade"),
  index("synced_transcript_vault_meeting_start_id_idx")
    .on(table.vaultId, table.meetingId, table.startTime, table.segmentId),
]);

export const transcriptPatchChunk = contentSchema.table("transcript_patch_chunks", {
  vaultId: uuid("vault_id").notNull(),
  meetingId: uuid("meeting_id").notNull(),
  patchId: uuid("patch_id").notNull(),
  chunkIndex: integer("chunk_index").notNull(),
  contentHash: text("content_hash").notNull(),
  payload: jsonb("payload").notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
}, (table) => [
  primaryKey({
    name: "transcript_patch_chunk_pk",
    columns: [table.vaultId, table.meetingId, table.patchId, table.chunkIndex],
  }),
  foreignKey({
    name: "transcript_patch_chunk_meeting_fk",
    columns: [table.vaultId, table.meetingId],
    foreignColumns: [syncedMeeting.vaultId, syncedMeeting.meetingId],
  }).onDelete("cascade"),
]);

export const syncedScreenshot = contentSchema.table("screenshots", {
  screenshotId: uuid("screenshot_id").primaryKey(),
  vaultId: uuid("vault_id").notNull(),
  meetingId: uuid("meeting_id").notNull(),
  capturedAt: timestamp("captured_at").notNull(),
  contentType: text("content_type").notNull(),
  storageKey: text("storage_key").notNull(),
  contentLength: integer("content_length").notNull(),
  contentHash: text("content_hash").notNull(),
  active: boolean("active").default(true).notNull(),
  ocrText: text("ocr_text"),
  caption: text("caption"),
  revision: integer("revision").default(1).notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
}, (table) => [
  foreignKey({
    name: "synced_screenshot_meeting_fk",
    columns: [table.vaultId, table.meetingId],
    foreignColumns: [syncedMeeting.vaultId, syncedMeeting.meetingId],
  }).onDelete("cascade"),
  index("synced_screenshot_vault_meeting_captured_id_idx")
    .on(table.vaultId, table.meetingId, table.capturedAt, table.screenshotId),
]);

export const searchDocument = contentSchema.table("search_documents", {
  documentId: uuid("document_id").notNull(),
  vaultId: uuid("vault_id").notNull(),
  meetingId: uuid("meeting_id").notNull(),
  kind: text("kind").notNull(),
  searchText: text("search_text").default("").notNull(),
  searchVector: tsvector("search_vector")
    .generatedAlwaysAs(sql`to_tsvector('simple', search_text)`),
  embeddingText: text("embedding_text"),
  embeddingContentHash: text("embedding_content_hash"),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
}, (table) => [
  primaryKey({ name: "search_document_pk", columns: [table.vaultId, table.documentId] }),
  foreignKey({
    name: "search_document_meeting_fk",
    columns: [table.vaultId, table.meetingId],
    foreignColumns: [syncedMeeting.vaultId, syncedMeeting.meetingId],
  }).onDelete("cascade"),
  check("search_document_kind_check", sql`${table.kind} IN ('meeting', 'screenshot')`),
  index("search_document_vault_kind_meeting_document_idx")
    .on(table.vaultId, table.kind, table.meetingId, table.documentId),
]);

export const searchEmbedding = contentSchema.table("search_embeddings", {
  vaultId: uuid("vault_id").notNull(),
  documentId: uuid("document_id").notNull(),
  model: text("model").notNull(),
  dimensions: integer("dimensions").notNull(),
  contentHash: text("content_hash").notNull(),
  embedding: real("embedding").array().notNull(),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
}, (table) => [
  primaryKey({ name: "search_embedding_pk", columns: [table.vaultId, table.documentId] }),
  foreignKey({
    name: "search_embedding_document_fk",
    columns: [table.vaultId, table.documentId],
    foreignColumns: [searchDocument.vaultId, searchDocument.documentId],
  }).onDelete("cascade"),
  check("search_embedding_dimensions_check", sql`${table.dimensions} BETWEEN 32 AND 1024`),
]);

export const searchIndexJob = coreSchema.table("search_index_jobs", {
  vaultId: uuid("vault_id").notNull(),
  documentId: uuid("document_id").notNull(),
  ownerUserId: text("owner_user_id").notNull(),
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
  primaryKey({ name: "search_index_job_pk", columns: [table.vaultId, table.documentId] }),
  foreignKey({
    name: "search_index_job_vault_fk",
    columns: [table.vaultId],
    foreignColumns: [syncedVault.vaultId],
  }).onDelete("cascade"),
  foreignKey({
    name: "search_index_job_owner_user_fk",
    columns: [table.ownerUserId],
    foreignColumns: [authUser.id],
  }).onDelete("cascade"),
  check("search_index_job_status_check", sql`${table.status} IN ('pending', 'processing', 'failed')`),
  check("search_index_job_dimensions_check", sql`${table.dimensions} BETWEEN 32 AND 1024`),
  index("search_index_job_claim_idx").on(table.status, table.availableAt, table.leaseExpiresAt),
]);

export const syncTransactionReceipt = coreSchema.table("transaction_receipts", {
  transactionId: uuid("transaction_id").primaryKey(),
  ownerUserId: text("owner_user_id").notNull(),
  vaultId: uuid("vault_id").notNull(),
  requestHash: text("request_hash").notNull(),
  responseJson: jsonb("response_json").notNull(),
  cursor: bigint("cursor", { mode: "number" }).notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
}, (table) => [
  foreignKey({
    name: "transaction_receipt_owner_user_fk",
    columns: [table.ownerUserId],
    foreignColumns: [authUser.id],
  }).onDelete("cascade"),
  index("transaction_receipt_owner_created_idx").on(table.ownerUserId, table.createdAt),
]);

export const syncChange = coreSchema.table("sync_changes", {
  sequence: bigserial("sequence", { mode: "number" }).primaryKey(),
  ownerUserId: text("owner_user_id").notNull(),
  vaultId: uuid("vault_id").notNull(),
  entity: text("entity").notNull(),
  entityId: uuid("entity_id").notNull(),
  action: text("action").notNull(),
  revision: integer("revision"),
  transactionId: uuid("transaction_id").notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
}, (table) => [
  check("sync_change_entity_check", sql`${table.entity} IN ('vault', 'project', 'meeting', 'summary', 'transcript', 'screenshot')`),
  check("sync_change_action_check", sql`${table.action} IN ('upsert', 'delete', 'reset')`),
  index("sync_change_owner_vault_sequence_idx").on(table.ownerUserId, table.vaultId, table.sequence),
  index("sync_change_owner_sequence_idx").on(table.ownerUserId, table.sequence),
]);

export const storageDeleteJob = coreSchema.table("storage_delete_jobs", {
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
