CREATE TABLE "app"."meeting_files" (
	"id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"meeting_id" uuid NOT NULL,
	"file_id" uuid NOT NULL,
	"captured_at" timestamp,
	"session_id" uuid,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"revision" integer DEFAULT 1 NOT NULL,
	CONSTRAINT "meeting_files_meeting_file_unique" UNIQUE("meeting_id","file_id")
);
--> statement-breakpoint
ALTER TABLE "app"."meeting_files" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
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
DROP POLICY "screenshot_select" ON "app"."screenshots";--> statement-breakpoint
DROP POLICY "screenshot_write" ON "app"."screenshots";--> statement-breakpoint
DROP TABLE "app"."screenshots";--> statement-breakpoint
CREATE INDEX "meeting_files_vault_meeting_id_idx" ON "app"."meeting_files" ("vault_id","meeting_id","id");--> statement-breakpoint
CREATE INDEX "files_vault_file_idx" ON "app"."files" ("vault_id","file_id");--> statement-breakpoint
ALTER TABLE "app"."meeting_files" ADD CONSTRAINT "meeting_files_7HfrsfdhAdbg_fkey" FOREIGN KEY ("vault_id","meeting_id") REFERENCES "app"."meetings"("vault_id","meeting_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."meeting_files" ADD CONSTRAINT "meeting_files_vault_id_file_id_files_vault_id_file_id_fkey" FOREIGN KEY ("vault_id","file_id") REFERENCES "app"."files"("vault_id","file_id");--> statement-breakpoint
ALTER TABLE "app"."files" ADD CONSTRAINT "files_vault_id_vaults_vault_id_fkey" FOREIGN KEY ("vault_id") REFERENCES "app"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."sync_changes" DROP CONSTRAINT "sync_change_entity_check", ADD CONSTRAINT "sync_change_entity_check" CHECK ("entity" IN ('vault', 'project', 'meeting', 'summary', 'transcript', 'file', 'meeting_file'));--> statement-breakpoint
CREATE VIEW "app"."meeting_images" WITH (security_invoker = true) AS (
  SELECT m.id AS screenshot_id, f.file_id, m.vault_id, m.meeting_id,
    coalesce(m.captured_at, m.created_at) AS captured_at, f.content_type,
    'files/' || f.file_id || '/original' AS storage_key,
    f.size AS content_length, substr(f.checksum, 9) AS content_hash, f.active,
    f.metadata ->> 'ocr_text' AS ocr_text,
    f.metadata ->> 'caption' AS caption,
    m.revision
  FROM app.meeting_files m JOIN app.files f ON f.file_id = m.file_id AND f.vault_id = m.vault_id
  WHERE f.metadata ->> 'source' = 'screenshot'
);--> statement-breakpoint
CREATE POLICY "meeting_file_select" ON "app"."meeting_files" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."meeting_files"."vault_id"));--> statement-breakpoint
CREATE POLICY "meeting_file_write" ON "app"."meeting_files" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_owns_vault"("app"."meeting_files"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."meeting_files"."vault_id"));--> statement-breakpoint
CREATE POLICY "file_select" ON "app"."files" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."files"."vault_id"));--> statement-breakpoint
CREATE POLICY "file_write" ON "app"."files" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_owns_vault"("app"."files"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."files"."vault_id"));