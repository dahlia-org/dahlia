CREATE SCHEMA "content";
--> statement-breakpoint
CREATE SCHEMA "core";
--> statement-breakpoint
CREATE TABLE "core"."artifact" (
	"id" uuid PRIMARY KEY,
	"owner_workspace_id" text NOT NULL,
	"content_type" text NOT NULL,
	"storage_key" text,
	"visibility" text DEFAULT 'private' NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "artifact_visibility_check" CHECK ("visibility" IN ('private', 'public'))
);
--> statement-breakpoint
CREATE TABLE "core"."model_alias" (
	"alias" text PRIMARY KEY,
	"upstream_model" text NOT NULL,
	"display_name" text,
	"enabled" boolean DEFAULT true NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "content"."search_documents" (
	"document_id" uuid,
	"vault_id" uuid,
	"meeting_id" uuid NOT NULL,
	"kind" text NOT NULL,
	"search_text" text DEFAULT '' NOT NULL,
	"search_vector" tsvector GENERATED ALWAYS AS (to_tsvector('simple', search_text)) STORED,
	"embedding_text" text,
	"embedding_content_hash" text,
	"updated_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "search_document_pk" PRIMARY KEY("vault_id","document_id"),
	CONSTRAINT "search_document_kind_check" CHECK ("kind" IN ('meeting', 'screenshot'))
);
--> statement-breakpoint
CREATE TABLE "content"."search_embeddings" (
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
CREATE TABLE "core"."search_index_jobs" (
	"vault_id" uuid,
	"document_id" uuid,
	"owner_user_id" text NOT NULL,
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
CREATE TABLE "core"."storage_delete_jobs" (
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
CREATE TABLE "core"."sync_changes" (
	"sequence" bigserial PRIMARY KEY,
	"owner_user_id" text NOT NULL,
	"vault_id" uuid NOT NULL,
	"entity" text NOT NULL,
	"entity_id" uuid NOT NULL,
	"action" text NOT NULL,
	"revision" integer,
	"transaction_id" uuid NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "sync_change_entity_check" CHECK ("entity" IN ('vault', 'project', 'meeting', 'summary', 'transcript', 'screenshot')),
	CONSTRAINT "sync_change_action_check" CHECK ("action" IN ('upsert', 'delete', 'reset'))
);
--> statement-breakpoint
CREATE TABLE "core"."transaction_receipts" (
	"transaction_id" uuid PRIMARY KEY,
	"owner_user_id" text NOT NULL,
	"vault_id" uuid NOT NULL,
	"request_hash" text NOT NULL,
	"response_json" jsonb NOT NULL,
	"cursor" bigint NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "content"."meetings" (
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
	"summary_title" text,
	"summary_document" text,
	"summary_created_at" timestamp,
	"revision" integer DEFAULT 1 NOT NULL,
	"summary_revision" integer DEFAULT 0 NOT NULL,
	"transcript_revision" integer DEFAULT 0 NOT NULL,
	"active" boolean DEFAULT false NOT NULL,
	"deleting_at" timestamp,
	CONSTRAINT "synced_meeting_vault_meeting_unique" UNIQUE("vault_id","meeting_id")
);
--> statement-breakpoint
CREATE TABLE "core"."projects" (
	"project_id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"parent_project_id" uuid,
	"name" text NOT NULL,
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
CREATE TABLE "content"."screenshots" (
	"screenshot_id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"meeting_id" uuid NOT NULL,
	"captured_at" timestamp NOT NULL,
	"content_type" text NOT NULL,
	"storage_key" text NOT NULL,
	"content_length" integer NOT NULL,
	"content_hash" text NOT NULL,
	"active" boolean DEFAULT true NOT NULL,
	"ocr_text" text,
	"caption" text,
	"revision" integer DEFAULT 1 NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "content"."transcript_segments" (
	"vault_id" uuid,
	"meeting_id" uuid,
	"segment_id" uuid,
	"start_time" timestamp NOT NULL,
	"end_time" timestamp,
	"text" text NOT NULL,
	"is_confirmed" boolean NOT NULL,
	"audio_source" text,
	"speaker_label" text,
	CONSTRAINT "synced_transcript_segment_pk" PRIMARY KEY("vault_id","meeting_id","segment_id")
);
--> statement-breakpoint
CREATE TABLE "core"."vaults" (
	"vault_id" uuid PRIMARY KEY,
	"name" text NOT NULL,
	"revision" integer DEFAULT 1 NOT NULL,
	"deleting_at" timestamp,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "core"."vault_permissions" (
	"vault_id" uuid,
	"principal_type" text,
	"principal_id" text,
	"role" text NOT NULL,
	"granted_by_user_id" text NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "vault_permission_pk" PRIMARY KEY("vault_id","principal_type","principal_id"),
	CONSTRAINT "vault_permission_principal_type_check" CHECK ("principal_type" IN ('user', 'organization', 'team')),
	CONSTRAINT "vault_permission_role_check" CHECK ("role" IN ('owner', 'member')),
	CONSTRAINT "vault_permission_owner_user_check" CHECK ("role" <> 'owner' OR "principal_type" = 'user')
);
--> statement-breakpoint
CREATE TABLE "content"."transcript_patch_chunks" (
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
CREATE INDEX "search_document_vault_kind_meeting_document_idx" ON "content"."search_documents" ("vault_id","kind","meeting_id","document_id");--> statement-breakpoint
CREATE INDEX "search_index_job_claim_idx" ON "core"."search_index_jobs" ("status","available_at","lease_expires_at");--> statement-breakpoint
CREATE INDEX "storage_delete_job_claim_idx" ON "core"."storage_delete_jobs" ("status","available_at","lease_expires_at");--> statement-breakpoint
CREATE INDEX "sync_change_owner_vault_sequence_idx" ON "core"."sync_changes" ("owner_user_id","vault_id","sequence");--> statement-breakpoint
CREATE INDEX "sync_change_owner_sequence_idx" ON "core"."sync_changes" ("owner_user_id","sequence");--> statement-breakpoint
CREATE INDEX "transaction_receipt_owner_created_idx" ON "core"."transaction_receipts" ("owner_user_id","created_at");--> statement-breakpoint
CREATE INDEX "synced_meeting_vault_created_id_idx" ON "content"."meetings" ("vault_id","created_at","meeting_id");--> statement-breakpoint
CREATE INDEX "project_vault_parent_name_idx" ON "core"."projects" ("vault_id","parent_project_id","name");--> statement-breakpoint
CREATE INDEX "synced_screenshot_vault_meeting_captured_id_idx" ON "content"."screenshots" ("vault_id","meeting_id","captured_at","screenshot_id");--> statement-breakpoint
CREATE INDEX "synced_transcript_vault_meeting_start_id_idx" ON "content"."transcript_segments" ("vault_id","meeting_id","start_time","segment_id");--> statement-breakpoint
CREATE UNIQUE INDEX "vault_permission_single_owner_idx" ON "core"."vault_permissions" ("vault_id") WHERE "role" = 'owner';--> statement-breakpoint
CREATE INDEX "vault_permission_principal_vault_idx" ON "core"."vault_permissions" ("principal_type","principal_id","role","vault_id");--> statement-breakpoint
ALTER TABLE "content"."search_documents" ADD CONSTRAINT "search_document_meeting_fk" FOREIGN KEY ("vault_id","meeting_id") REFERENCES "content"."meetings"("vault_id","meeting_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "content"."search_embeddings" ADD CONSTRAINT "search_embedding_document_fk" FOREIGN KEY ("vault_id","document_id") REFERENCES "content"."search_documents"("vault_id","document_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "core"."search_index_jobs" ADD CONSTRAINT "search_index_job_vault_fk" FOREIGN KEY ("vault_id") REFERENCES "core"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "core"."search_index_jobs" ADD CONSTRAINT "search_index_job_owner_user_fk" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "core"."transaction_receipts" ADD CONSTRAINT "transaction_receipt_owner_user_fk" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "content"."meetings" ADD CONSTRAINT "synced_meeting_vault_fk" FOREIGN KEY ("vault_id") REFERENCES "core"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "content"."meetings" ADD CONSTRAINT "synced_meeting_project_fk" FOREIGN KEY ("vault_id","project_id") REFERENCES "core"."projects"("vault_id","project_id");--> statement-breakpoint
ALTER TABLE "core"."projects" ADD CONSTRAINT "project_vault_fk" FOREIGN KEY ("vault_id") REFERENCES "core"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "core"."projects" ADD CONSTRAINT "project_parent_fk" FOREIGN KEY ("vault_id","parent_project_id") REFERENCES "core"."projects"("vault_id","project_id") ON DELETE RESTRICT;--> statement-breakpoint
ALTER TABLE "content"."screenshots" ADD CONSTRAINT "synced_screenshot_meeting_fk" FOREIGN KEY ("vault_id","meeting_id") REFERENCES "content"."meetings"("vault_id","meeting_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "content"."transcript_segments" ADD CONSTRAINT "synced_transcript_segment_meeting_fk" FOREIGN KEY ("vault_id","meeting_id") REFERENCES "content"."meetings"("vault_id","meeting_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "core"."vault_permissions" ADD CONSTRAINT "vault_permission_vault_fk" FOREIGN KEY ("vault_id") REFERENCES "core"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "core"."vault_permissions" ADD CONSTRAINT "vault_permission_granted_by_user_fk" FOREIGN KEY ("granted_by_user_id") REFERENCES "auth"."user"("id") ON DELETE RESTRICT;--> statement-breakpoint
ALTER TABLE "content"."transcript_patch_chunks" ADD CONSTRAINT "transcript_patch_chunk_meeting_fk" FOREIGN KEY ("vault_id","meeting_id") REFERENCES "content"."meetings"("vault_id","meeting_id") ON DELETE CASCADE;
--> statement-breakpoint
CREATE UNIQUE INDEX "project_sibling_name_unique" ON "core"."projects" ("vault_id", "parent_project_id", lower("name")) NULLS NOT DISTINCT;
--> statement-breakpoint
CREATE INDEX "member_user_organization_idx" ON "auth"."member" ("user_id","organization_id");
--> statement-breakpoint
CREATE INDEX "team_member_user_team_idx" ON "auth"."team_member" ("user_id","team_id");
--> statement-breakpoint
CREATE FUNCTION "core"."current_identity_owns_vault"(target_vault_id uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT coalesce(current_setting('app.user_id', true), '') <> '' AND EXISTS (
    SELECT 1 FROM "core"."vault_permissions" permission
    WHERE permission."vault_id" = target_vault_id
      AND permission."principal_type" = 'user'
      AND permission."principal_id" = current_setting('app.user_id', true)
      AND permission."role" = 'owner'
  )
$$;
--> statement-breakpoint
CREATE FUNCTION "core"."current_identity_can_read_vault"(target_vault_id uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT "core"."current_identity_owns_vault"(target_vault_id) OR (
    current_setting('app.sharing_enabled', true) = 'true' AND EXISTS (
      SELECT 1 FROM "core"."vault_permissions" permission
      WHERE permission."vault_id" = target_vault_id AND permission."role" = 'member' AND (
        (permission."principal_type" = 'user' AND permission."principal_id" = current_setting('app.user_id', true))
        OR (permission."principal_type" = 'organization' AND EXISTS (
          SELECT 1 FROM "auth"."member" membership
          WHERE membership."organization_id" = permission."principal_id"
            AND membership."user_id" = current_setting('app.user_id', true)
        ))
        OR (permission."principal_type" = 'team' AND EXISTS (
          SELECT 1 FROM "auth"."team_member" membership
          WHERE membership."team_id" = permission."principal_id"
            AND membership."user_id" = current_setting('app.user_id', true)
        ))
      )
    )
  )
$$;
--> statement-breakpoint
ALTER TABLE "core"."vaults" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "core"."vaults" FORCE ROW LEVEL SECURITY;
CREATE POLICY "vault_select" ON "core"."vaults" FOR SELECT USING ("core"."current_identity_can_read_vault"("vault_id"));
CREATE POLICY "vault_insert" ON "core"."vaults" FOR INSERT WITH CHECK (coalesce(current_setting('app.user_id', true), '') <> '');
CREATE POLICY "vault_update" ON "core"."vaults" FOR UPDATE USING ("core"."current_identity_owns_vault"("vault_id")) WITH CHECK ("core"."current_identity_owns_vault"("vault_id"));
CREATE POLICY "vault_delete" ON "core"."vaults" FOR DELETE USING ("core"."current_identity_owns_vault"("vault_id"));
--> statement-breakpoint
ALTER TABLE "core"."projects" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "core"."projects" FORCE ROW LEVEL SECURITY;
CREATE POLICY "project_select" ON "core"."projects" FOR SELECT USING ("core"."current_identity_can_read_vault"("vault_id"));
CREATE POLICY "project_insert" ON "core"."projects" FOR INSERT WITH CHECK ("core"."current_identity_owns_vault"("vault_id"));
CREATE POLICY "project_update" ON "core"."projects" FOR UPDATE USING ("core"."current_identity_owns_vault"("vault_id")) WITH CHECK ("core"."current_identity_owns_vault"("vault_id"));
CREATE POLICY "project_delete" ON "core"."projects" FOR DELETE USING ("core"."current_identity_owns_vault"("vault_id"));
--> statement-breakpoint
ALTER TABLE "content"."meetings" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "content"."meetings" FORCE ROW LEVEL SECURITY;
ALTER TABLE "content"."transcript_segments" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "content"."transcript_segments" FORCE ROW LEVEL SECURITY;
ALTER TABLE "content"."transcript_patch_chunks" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "content"."transcript_patch_chunks" FORCE ROW LEVEL SECURITY;
ALTER TABLE "content"."screenshots" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "content"."screenshots" FORCE ROW LEVEL SECURITY;
ALTER TABLE "content"."search_documents" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "content"."search_documents" FORCE ROW LEVEL SECURITY;
ALTER TABLE "content"."search_embeddings" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "content"."search_embeddings" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
CREATE POLICY "meeting_select" ON "content"."meetings" FOR SELECT USING ("core"."current_identity_can_read_vault"("vault_id"));
CREATE POLICY "meeting_write" ON "content"."meetings" FOR ALL USING ("core"."current_identity_owns_vault"("vault_id")) WITH CHECK ("core"."current_identity_owns_vault"("vault_id"));
CREATE POLICY "transcript_select" ON "content"."transcript_segments" FOR SELECT USING ("core"."current_identity_can_read_vault"("vault_id"));
CREATE POLICY "transcript_write" ON "content"."transcript_segments" FOR ALL USING ("core"."current_identity_owns_vault"("vault_id")) WITH CHECK ("core"."current_identity_owns_vault"("vault_id"));
CREATE POLICY "transcript_patch_select" ON "content"."transcript_patch_chunks" FOR SELECT USING ("core"."current_identity_owns_vault"("vault_id"));
CREATE POLICY "transcript_patch_write" ON "content"."transcript_patch_chunks" FOR ALL USING ("core"."current_identity_owns_vault"("vault_id")) WITH CHECK ("core"."current_identity_owns_vault"("vault_id"));
CREATE POLICY "screenshot_select" ON "content"."screenshots" FOR SELECT USING ("core"."current_identity_can_read_vault"("vault_id"));
CREATE POLICY "screenshot_write" ON "content"."screenshots" FOR ALL USING ("core"."current_identity_owns_vault"("vault_id")) WITH CHECK ("core"."current_identity_owns_vault"("vault_id"));
CREATE POLICY "search_document_select" ON "content"."search_documents" FOR SELECT USING ("core"."current_identity_can_read_vault"("vault_id"));
CREATE POLICY "search_document_write" ON "content"."search_documents" FOR ALL USING ("core"."current_identity_owns_vault"("vault_id")) WITH CHECK ("core"."current_identity_owns_vault"("vault_id"));
CREATE POLICY "search_embedding_select" ON "content"."search_embeddings" FOR SELECT USING ("core"."current_identity_can_read_vault"("vault_id"));
CREATE POLICY "search_embedding_write" ON "content"."search_embeddings" FOR ALL USING ("core"."current_identity_owns_vault"("vault_id")) WITH CHECK ("core"."current_identity_owns_vault"("vault_id"));
