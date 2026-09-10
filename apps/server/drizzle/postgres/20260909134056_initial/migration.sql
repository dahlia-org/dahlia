CREATE SCHEMA "app";
--> statement-breakpoint
CREATE TABLE "app"."account_settings" (
	"user_id" uuid PRIMARY KEY,
	"summary" jsonb DEFAULT '{"style":"detailed"}' NOT NULL,
	"processing" jsonb DEFAULT '{"location":"local","remote":{"workflow":"transcribeThenSummarize"}}' NOT NULL,
	"revision" integer DEFAULT 1 NOT NULL,
	"output_language" text NOT NULL,
	"analysis_languages" jsonb NOT NULL
);
--> statement-breakpoint
ALTER TABLE "app"."account_settings" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."jobs_image_analysis" (
	"file_id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"owner_user_id" uuid NOT NULL,
	"model" text NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"available_at" timestamp DEFAULT now() NOT NULL,
	"claimed_at" timestamp,
	"lease_expires_at" timestamp,
	"last_error_code" text,
	CONSTRAINT "image_analysis_job_status_check" CHECK ("status" IN ('pending', 'processing', 'failed'))
);
--> statement-breakpoint
CREATE TABLE "app"."meeting_attachments" (
	"id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"meeting_id" uuid NOT NULL,
	"file_id" uuid NOT NULL,
	"captured_at" timestamp,
	"session_id" uuid,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"revision" integer DEFAULT 1 NOT NULL,
	CONSTRAINT "meeting_attachments_meeting_attachment_unique" UNIQUE("meeting_id","file_id")
);
--> statement-breakpoint
ALTER TABLE "app"."meeting_attachments" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."meeting_events" (
	"id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"owner_user_id" uuid NOT NULL,
	"meeting_id" uuid NOT NULL,
	"kind" text NOT NULL,
	"occurred_at" timestamp NOT NULL,
	"received_at" timestamp NOT NULL,
	"session_id" uuid,
	"related_id" text,
	"audio_source" text,
	"segment_index" integer,
	"changed_fields" text,
	CONSTRAINT "meeting_events_kind_check" CHECK ("kind" IN ('meeting_created', 'meeting_updated', 'meeting_deleted', 'tag_added', 'tag_removed', 'recording_started', 'recording_ended', 'segment_rotated')),
	CONSTRAINT "meeting_events_source_check" CHECK ("audio_source" IN ('mic', 'system'))
);
--> statement-breakpoint
ALTER TABLE "app"."meeting_events" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."search_documents" (
	"document_id" uuid,
	"vault_id" uuid,
	"meeting_id" uuid NOT NULL,
	"kind" text NOT NULL,
	"search_text" text DEFAULT '' NOT NULL,
	"title_text" text DEFAULT '' NOT NULL,
	"tags_text" text DEFAULT '' NOT NULL,
	"description_text" text DEFAULT '' NOT NULL,
	"summary_text" text DEFAULT '' NOT NULL,
	"ocr_text" text DEFAULT '' NOT NULL,
	"caption_text" text DEFAULT '' NOT NULL,
	"title_vector" tsvector GENERATED ALWAYS AS (to_tsvector('simple', title_text)) STORED,
	"tags_vector" tsvector GENERATED ALWAYS AS (to_tsvector('simple', tags_text)) STORED,
	"description_vector" tsvector GENERATED ALWAYS AS (to_tsvector('simple', description_text)) STORED,
	"summary_vector" tsvector GENERATED ALWAYS AS (to_tsvector('simple', summary_text)) STORED,
	"ocr_vector" tsvector GENERATED ALWAYS AS (to_tsvector('simple', ocr_text)) STORED,
	"caption_vector" tsvector GENERATED ALWAYS AS (to_tsvector('simple', caption_text)) STORED,
	"search_vector" tsvector GENERATED ALWAYS AS (to_tsvector('simple', search_text)) STORED,
	"embedding_text" text,
	"embedding_content_hash" text,
	"updated_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "search_document_pk" PRIMARY KEY("vault_id","document_id"),
	CONSTRAINT "search_document_kind_check" CHECK ("kind" IN ('meeting', 'screenshot'))
);
--> statement-breakpoint
ALTER TABLE "app"."search_documents" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."search_embeddings" (
	"vault_id" uuid,
	"document_id" uuid,
	"model" text NOT NULL,
	"dimensions" integer NOT NULL,
	"content_hash" text NOT NULL,
	"embedding" real[] NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "search_embedding_pk" PRIMARY KEY("vault_id","document_id"),
	CONSTRAINT "search_embedding_dimensions_check" CHECK ("dimensions" BETWEEN 32 AND 1024)
);
--> statement-breakpoint
ALTER TABLE "app"."search_embeddings" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."jobs_search_index" (
	"vault_id" uuid,
	"document_id" uuid,
	"owner_user_id" uuid NOT NULL,
	"model" text NOT NULL,
	"dimensions" integer NOT NULL,
	"generation" integer DEFAULT 1 NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"available_at" timestamp DEFAULT now() NOT NULL,
	"claimed_at" timestamp,
	"lease_expires_at" timestamp,
	"last_error_code" text,
	"updated_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "search_index_job_pk" PRIMARY KEY("vault_id","document_id"),
	CONSTRAINT "search_index_job_status_check" CHECK ("status" IN ('pending', 'processing', 'failed')),
	CONSTRAINT "search_index_job_dimensions_check" CHECK ("dimensions" BETWEEN 32 AND 1024)
);
--> statement-breakpoint
CREATE TABLE "app"."server_initializations" (
	"name" text PRIMARY KEY,
	"initialized_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE "app"."server_settings" (
	"id" integer PRIMARY KEY,
	"search_weights" jsonb DEFAULT '{"title":5,"tags":3,"description":2,"summary":1,"ocr":1,"caption":2}' NOT NULL,
	CONSTRAINT "server_settings_singleton" CHECK ("id" = 1)
);
--> statement-breakpoint
CREATE TABLE "app"."jobs_storage_delete" (
	"storage_key" text PRIMARY KEY,
	"attempts" integer DEFAULT 0 NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"available_at" timestamp DEFAULT now() NOT NULL,
	"claimed_at" timestamp,
	"lease_expires_at" timestamp,
	"last_error_code" text,
	"created_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "storage_delete_job_status_check" CHECK ("status" IN ('pending', 'processing', 'failed'))
);
--> statement-breakpoint
CREATE TABLE "app"."summaries" (
	"id" uuid PRIMARY KEY,
	"meeting_id" uuid NOT NULL,
	"version" integer NOT NULL,
	"title" text NOT NULL,
	"document" text NOT NULL,
	"created_at" timestamp,
	"saved_at" timestamp NOT NULL,
	"metadata" jsonb,
	CONSTRAINT "summary_meeting_version_unique" UNIQUE("meeting_id","version")
);
--> statement-breakpoint
ALTER TABLE "app"."summaries" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."jobs_summary" (
	"id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"meeting_id" uuid NOT NULL,
	"owner_user_id" uuid NOT NULL,
	"method" text NOT NULL,
	"settings" jsonb NOT NULL,
	"input" jsonb,
	"stage" text,
	"transcript_revision" integer,
	"transcript_result" jsonb,
	"output_language" text NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp NOT NULL,
	"available_at" timestamp NOT NULL,
	"claimed_at" timestamp,
	"lease_expires_at" timestamp,
	"last_error_code" text,
	"summary_revision" integer NOT NULL,
	"input_version" text NOT NULL,
	"request_hash" text NOT NULL,
	CONSTRAINT "summary_job_status_check" CHECK ("status" IN ('pending', 'processing', 'succeeded', 'failed', 'cancelled'))
);
--> statement-breakpoint
ALTER TABLE "app"."jobs_summary" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."sync_changes" (
	"sequence" bigserial PRIMARY KEY,
	"owner_user_id" uuid NOT NULL,
	"vault_id" uuid NOT NULL,
	"entity" text NOT NULL,
	"entity_id" uuid NOT NULL,
	"action" text NOT NULL,
	"revision" integer,
	"transaction_id" uuid NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "sync_change_entity_check" CHECK ("entity" IN ('vault', 'project', 'meeting', 'summary', 'transcript', 'file', 'meeting_attachment', 'recording')),
	CONSTRAINT "sync_change_action_check" CHECK ("action" IN ('upsert', 'delete', 'reset'))
);
--> statement-breakpoint
CREATE TABLE "app"."transaction_receipts" (
	"transaction_id" uuid PRIMARY KEY,
	"owner_user_id" uuid NOT NULL,
	"vault_id" uuid NOT NULL,
	"request_hash" text NOT NULL,
	"response_json" jsonb,
	"results_json" jsonb DEFAULT '[]' NOT NULL,
	"cursor" bigint NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "app"."transaction_receipts" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."sync_vault_state" (
	"owner_user_id" uuid,
	"vault_id" uuid,
	"latest_sequence" bigint DEFAULT 0 NOT NULL,
	"pruned_through" bigint DEFAULT 0 NOT NULL,
	CONSTRAINT "sync_vault_state_pkey" PRIMARY KEY("owner_user_id","vault_id"),
	CONSTRAINT "sync_vault_state_boundary_check" CHECK ("pruned_through" >= 0 AND "latest_sequence" >= "pruned_through")
);
--> statement-breakpoint
CREATE TABLE "app"."files" (
	"file_id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"uri" text NOT NULL,
	"offset" bigint DEFAULT 0 NOT NULL,
	"size" bigint NOT NULL,
	"content_type" text NOT NULL,
	"checksum" text NOT NULL,
	"name" text NOT NULL,
	"metadata" jsonb NOT NULL,
	"active" boolean DEFAULT false NOT NULL,
	"uploaded_at" timestamp,
	"revision" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "files_vault_file_unique" UNIQUE("vault_id","file_id"),
	CONSTRAINT "files_offset_check" CHECK ("offset" = 0),
	CONSTRAINT "files_size_check" CHECK ("size" >= 0)
);
--> statement-breakpoint
ALTER TABLE "app"."files" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."meetings" (
	"meeting_id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"project_id" uuid,
	"name" text NOT NULL,
	"description" text DEFAULT '' NOT NULL,
	"status" text NOT NULL,
	"duration" double precision,
	"recording_started_at" timestamp,
	"created_at" timestamp NOT NULL,
	"updated_at" timestamp NOT NULL,
	"revision" integer DEFAULT 1 NOT NULL,
	"summary_revision" integer DEFAULT 0 NOT NULL,
	"transcript_revision" integer DEFAULT 0 NOT NULL,
	"active" boolean DEFAULT false NOT NULL,
	"deleting_at" timestamp,
	CONSTRAINT "synced_meeting_vault_meeting_unique" UNIQUE("vault_id","meeting_id")
);
--> statement-breakpoint
ALTER TABLE "app"."meetings" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."projects" (
	"project_id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"parent_project_id" uuid,
	"name" text NOT NULL,
	"icon" text,
	"color" text,
	"description" text DEFAULT '' NOT NULL,
	"project_type" text,
	"revision" integer NOT NULL,
	"created_at" timestamp NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "project_vault_project_unique" UNIQUE("vault_id","project_id"),
	CONSTRAINT "project_type_check" CHECK ((
    ("parent_project_id" IS NULL AND "project_type" IN ('customer', 'internal', 'personal', 'undefined'))
    OR ("parent_project_id" IS NOT NULL AND "project_type" IS NULL)
  )),
	CONSTRAINT "project_revision_check" CHECK ("revision" >= 1),
	CONSTRAINT "project_parent_check" CHECK ("parent_project_id" IS NULL OR "parent_project_id" <> "project_id")
);
--> statement-breakpoint
ALTER TABLE "app"."projects" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."recordings" (
	"session_id" uuid PRIMARY KEY,
	"meeting_id" uuid NOT NULL,
	"number" integer NOT NULL,
	"started_at" timestamp NOT NULL,
	"ended_at" timestamp NOT NULL,
	"audio" jsonb NOT NULL,
	"revision" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp NOT NULL,
	"updated_at" timestamp NOT NULL,
	CONSTRAINT "recordings_meeting_number_unique" UNIQUE("meeting_id","number"),
	CONSTRAINT "recordings_number_check" CHECK ("number" > 0)
);
--> statement-breakpoint
ALTER TABLE "app"."recordings" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."transcript_segments" (
	"transcript_id" uuid,
	"segment_id" uuid,
	"started_at" timestamp NOT NULL,
	"ended_at" timestamp,
	"text" text NOT NULL,
	"created_at" timestamp,
	"audio_source" text,
	"speaker_label" text,
	CONSTRAINT "synced_transcript_segment_pk" PRIMARY KEY("transcript_id","segment_id")
);
--> statement-breakpoint
ALTER TABLE "app"."transcript_segments" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."vaults" (
	"vault_id" uuid PRIMARY KEY,
	"name" text NOT NULL,
	"icon" text,
	"color" text,
	"revision" integer DEFAULT 1 NOT NULL,
	"deleting_at" timestamp,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "app"."vaults" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."vault_permissions" (
	"vault_id" uuid,
	"principal_type" text,
	"principal_id" uuid,
	"role" text NOT NULL,
	"granted_by_user_id" uuid NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "vault_permission_pk" PRIMARY KEY("vault_id","principal_type","principal_id"),
	CONSTRAINT "vault_permission_principal_type_check" CHECK ("principal_type" IN ('user', 'organization', 'team')),
	CONSTRAINT "vault_permission_role_check" CHECK ("role" IN ('owner', 'member')),
	CONSTRAINT "vault_permission_owner_user_check" CHECK ("role" <> 'owner' OR "principal_type" = 'user')
);
--> statement-breakpoint
CREATE TABLE "app"."transcripts" (
	"id" uuid PRIMARY KEY,
	"meeting_id" uuid NOT NULL,
	"version" integer NOT NULL,
	"sync_revision" integer NOT NULL,
	"started_at" timestamp,
	"ended_at" timestamp,
	"created_at" timestamp NOT NULL,
	"metadata" jsonb,
	CONSTRAINT "transcript_meeting_version_unique" UNIQUE("meeting_id","version"),
	CONSTRAINT "transcript_version_check" CHECK ("version" >= 1)
);
--> statement-breakpoint
ALTER TABLE "app"."transcripts" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."transcript_patch_chunks" (
	"vault_id" uuid,
	"meeting_id" uuid,
	"patch_id" uuid,
	"chunk_index" integer,
	"content_hash" text NOT NULL,
	"payload" jsonb NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "transcript_patch_chunk_pk" PRIMARY KEY("vault_id","meeting_id","patch_id","chunk_index")
);
--> statement-breakpoint
ALTER TABLE "app"."transcript_patch_chunks" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."vault_transfers" (
	"sequence" bigserial PRIMARY KEY,
	"id" uuid NOT NULL UNIQUE,
	"owner_user_id" uuid NOT NULL,
	"idempotency_key" uuid NOT NULL,
	"request_hash" text NOT NULL,
	"source_vault_id" uuid NOT NULL,
	"destination_vault_id" uuid NOT NULL,
	"manifest" jsonb NOT NULL,
	CONSTRAINT "vault_transfer_owner_key_unique" UNIQUE("owner_user_id","idempotency_key")
);
--> statement-breakpoint
ALTER TABLE "app"."vault_transfers" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE INDEX "image_analysis_job_claim_idx" ON "app"."jobs_image_analysis" ("status","available_at","lease_expires_at");--> statement-breakpoint
CREATE INDEX "meeting_attachments_vault_meeting_id_idx" ON "app"."meeting_attachments" ("vault_id","meeting_id","id");--> statement-breakpoint
CREATE INDEX "meeting_events_meeting_time_idx" ON "app"."meeting_events" ("vault_id","meeting_id","occurred_at","id");--> statement-breakpoint
CREATE INDEX "meeting_events_session_idx" ON "app"."meeting_events" ("vault_id","session_id");--> statement-breakpoint
CREATE INDEX "search_document_vault_kind_meeting_document_idx" ON "app"."search_documents" ("vault_id","kind","meeting_id","document_id");--> statement-breakpoint
CREATE INDEX "search_index_job_claim_idx" ON "app"."jobs_search_index" ("status","available_at","lease_expires_at");--> statement-breakpoint
CREATE INDEX "storage_delete_job_claim_idx" ON "app"."jobs_storage_delete" ("status","available_at","lease_expires_at");--> statement-breakpoint
CREATE UNIQUE INDEX "summary_job_active_meeting_idx" ON "app"."jobs_summary" ("meeting_id") WHERE "status" IN ('pending', 'processing');--> statement-breakpoint
CREATE INDEX "summary_job_owner_created_idx" ON "app"."jobs_summary" ("owner_user_id","created_at");--> statement-breakpoint
CREATE INDEX "sync_change_owner_vault_sequence_idx" ON "app"."sync_changes" ("owner_user_id","vault_id","sequence");--> statement-breakpoint
CREATE INDEX "sync_change_owner_sequence_idx" ON "app"."sync_changes" ("owner_user_id","sequence");--> statement-breakpoint
CREATE INDEX "transaction_receipt_owner_created_idx" ON "app"."transaction_receipts" ("owner_user_id","created_at");--> statement-breakpoint
CREATE INDEX "files_vault_file_idx" ON "app"."files" ("vault_id","file_id");--> statement-breakpoint
CREATE INDEX "synced_meeting_vault_created_id_idx" ON "app"."meetings" ("vault_id","created_at","meeting_id");--> statement-breakpoint
CREATE INDEX "project_vault_parent_name_idx" ON "app"."projects" ("vault_id","parent_project_id","name");--> statement-breakpoint
CREATE INDEX "recordings_meeting_session_idx" ON "app"."recordings" ("meeting_id","session_id");--> statement-breakpoint
CREATE INDEX "transcript_segment_created_idx" ON "app"."transcript_segments" ("transcript_id","created_at");--> statement-breakpoint
CREATE INDEX "transcript_segment_start_id_idx" ON "app"."transcript_segments" ("transcript_id","started_at","segment_id");--> statement-breakpoint
CREATE UNIQUE INDEX "vault_permission_single_owner_idx" ON "app"."vault_permissions" ("vault_id") WHERE "role" = 'owner';--> statement-breakpoint
CREATE INDEX "vault_permission_principal_vault_idx" ON "app"."vault_permissions" ("principal_type","principal_id","role","vault_id");--> statement-breakpoint
CREATE INDEX "vault_transfer_owner_sequence_idx" ON "app"."vault_transfers" ("owner_user_id","sequence");--> statement-breakpoint
ALTER TABLE "app"."account_settings" ADD CONSTRAINT "account_settings_user_id_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."jobs_image_analysis" ADD CONSTRAINT "jobs_image_analysis_file_id_files_file_id_fkey" FOREIGN KEY ("file_id") REFERENCES "app"."files"("file_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."jobs_image_analysis" ADD CONSTRAINT "jobs_image_analysis_vault_id_vaults_vault_id_fkey" FOREIGN KEY ("vault_id") REFERENCES "app"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."jobs_image_analysis" ADD CONSTRAINT "jobs_image_analysis_owner_user_id_user_id_fkey" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."meeting_attachments" ADD CONSTRAINT "meeting_attachments_fnlH8jMHLYfd_fkey" FOREIGN KEY ("vault_id","meeting_id") REFERENCES "app"."meetings"("vault_id","meeting_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."meeting_attachments" ADD CONSTRAINT "meeting_attachments_sV1ehoid9FNK_fkey" FOREIGN KEY ("vault_id","file_id") REFERENCES "app"."files"("vault_id","file_id");--> statement-breakpoint
ALTER TABLE "app"."meeting_events" ADD CONSTRAINT "meeting_events_vault_id_vaults_vault_id_fkey" FOREIGN KEY ("vault_id") REFERENCES "app"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."meeting_events" ADD CONSTRAINT "meeting_events_owner_user_id_user_id_fkey" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."search_documents" ADD CONSTRAINT "search_document_meeting_fk" FOREIGN KEY ("vault_id","meeting_id") REFERENCES "app"."meetings"("vault_id","meeting_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."search_embeddings" ADD CONSTRAINT "search_embedding_document_fk" FOREIGN KEY ("vault_id","document_id") REFERENCES "app"."search_documents"("vault_id","document_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."jobs_search_index" ADD CONSTRAINT "search_index_job_vault_fk" FOREIGN KEY ("vault_id") REFERENCES "app"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."jobs_search_index" ADD CONSTRAINT "search_index_job_owner_user_fk" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."summaries" ADD CONSTRAINT "summaries_meeting_id_meetings_meeting_id_fkey" FOREIGN KEY ("meeting_id") REFERENCES "app"."meetings"("meeting_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."jobs_summary" ADD CONSTRAINT "jobs_summary_vault_id_vaults_vault_id_fkey" FOREIGN KEY ("vault_id") REFERENCES "app"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."jobs_summary" ADD CONSTRAINT "jobs_summary_meeting_id_meetings_meeting_id_fkey" FOREIGN KEY ("meeting_id") REFERENCES "app"."meetings"("meeting_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."jobs_summary" ADD CONSTRAINT "jobs_summary_owner_user_id_user_id_fkey" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."transaction_receipts" ADD CONSTRAINT "transaction_receipt_owner_user_fk" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."sync_vault_state" ADD CONSTRAINT "sync_vault_state_owner_user_id_user_id_fkey" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."files" ADD CONSTRAINT "files_vault_id_vaults_vault_id_fkey" FOREIGN KEY ("vault_id") REFERENCES "app"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."meetings" ADD CONSTRAINT "synced_meeting_vault_fk" FOREIGN KEY ("vault_id") REFERENCES "app"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."meetings" ADD CONSTRAINT "synced_meeting_project_fk" FOREIGN KEY ("vault_id","project_id") REFERENCES "app"."projects"("vault_id","project_id");--> statement-breakpoint
ALTER TABLE "app"."projects" ADD CONSTRAINT "project_vault_fk" FOREIGN KEY ("vault_id") REFERENCES "app"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."projects" ADD CONSTRAINT "project_parent_fk" FOREIGN KEY ("vault_id","parent_project_id") REFERENCES "app"."projects"("vault_id","project_id") ON DELETE RESTRICT;--> statement-breakpoint
ALTER TABLE "app"."recordings" ADD CONSTRAINT "recordings_meeting_id_meetings_meeting_id_fkey" FOREIGN KEY ("meeting_id") REFERENCES "app"."meetings"("meeting_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."transcript_segments" ADD CONSTRAINT "transcript_segment_transcript_fk" FOREIGN KEY ("transcript_id") REFERENCES "app"."transcripts"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."vault_permissions" ADD CONSTRAINT "vault_permission_vault_fk" FOREIGN KEY ("vault_id") REFERENCES "app"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."vault_permissions" ADD CONSTRAINT "vault_permission_granted_by_user_fk" FOREIGN KEY ("granted_by_user_id") REFERENCES "auth"."user"("id") ON DELETE RESTRICT;--> statement-breakpoint
ALTER TABLE "app"."transcripts" ADD CONSTRAINT "transcripts_meeting_id_meetings_meeting_id_fkey" FOREIGN KEY ("meeting_id") REFERENCES "app"."meetings"("meeting_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."transcript_patch_chunks" ADD CONSTRAINT "transcript_patch_chunk_meeting_fk" FOREIGN KEY ("vault_id","meeting_id") REFERENCES "app"."meetings"("vault_id","meeting_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."vault_transfers" ADD CONSTRAINT "vault_transfers_owner_user_id_user_id_fkey" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;--> statement-breakpoint
CREATE VIEW "app"."recording_sessions" WITH (security_invoker = true) AS (
  SELECT vault_id, meeting_id, session_id,
    min(CASE WHEN kind = 'recording_started' THEN occurred_at END) AS started_at,
    max(CASE WHEN kind = 'recording_ended' THEN occurred_at END) AS ended_at
  FROM app.meeting_events
  WHERE session_id IS NOT NULL AND kind IN ('recording_started', 'recording_ended')
  GROUP BY vault_id, meeting_id, session_id
);--> statement-breakpoint
CREATE VIEW "app"."meeting_images" WITH (security_invoker = true) AS (
  SELECT m.id AS screenshot_id, f.file_id, m.vault_id, m.meeting_id,
    coalesce(m.captured_at, m.created_at) AS captured_at, f.content_type,
    'files/' || f.file_id || '/original' AS storage_key,
    f.size AS content_length, substr(f.checksum, 9) AS content_hash, f.active,
    f.metadata ->> 'ocr_text' AS ocr_text,
    f.metadata ->> 'caption' AS caption,
    m.revision
  FROM app.meeting_attachments m JOIN app.files f ON f.file_id = m.file_id AND f.vault_id = m.vault_id
  WHERE f.metadata ->> 'source' = 'screenshot'
);