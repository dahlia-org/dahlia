CREATE TABLE "app"."live_transcripts" (
	"meeting_id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"session_id" uuid NOT NULL,
	"started_at" timestamp NOT NULL,
	"sequence" bigint NOT NULL,
	"status" text NOT NULL,
	"updated_at" timestamp NOT NULL,
	"previews" jsonb NOT NULL
);
--> statement-breakpoint
ALTER TABLE "app"."live_transcripts" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE INDEX "live_transcripts_vault_idx" ON "app"."live_transcripts" ("vault_id","updated_at");--> statement-breakpoint
ALTER TABLE "app"."live_transcripts" ADD CONSTRAINT "live_transcripts_ROtYaQYUGyl1_fkey" FOREIGN KEY ("vault_id","meeting_id") REFERENCES "app"."meetings"("vault_id","meeting_id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "live_transcripts_select" ON "app"."live_transcripts" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."live_transcripts"."vault_id"));--> statement-breakpoint
CREATE POLICY "live_transcripts_insert" ON "app"."live_transcripts" AS PERMISSIVE FOR INSERT TO public WITH CHECK ("app"."current_identity_owns_vault"("app"."live_transcripts"."vault_id"));--> statement-breakpoint
CREATE POLICY "live_transcripts_update" ON "app"."live_transcripts" AS PERMISSIVE FOR UPDATE TO public USING ("app"."current_identity_owns_vault"("app"."live_transcripts"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."live_transcripts"."vault_id"));--> statement-breakpoint
CREATE POLICY "live_transcripts_delete" ON "app"."live_transcripts" AS PERMISSIVE FOR DELETE TO public USING ("app"."current_identity_owns_vault"("app"."live_transcripts"."vault_id"));