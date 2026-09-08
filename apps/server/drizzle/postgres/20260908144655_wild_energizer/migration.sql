CREATE TABLE "app"."transcripts" (
	"id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"meeting_id" uuid NOT NULL,
	"version" integer NOT NULL,
	"sync_revision" integer NOT NULL,
	"status" text NOT NULL,
	"started_at" timestamp,
	"completed_at" timestamp,
	"saved_at" timestamp NOT NULL,
	"metadata" jsonb,
	CONSTRAINT "transcript_meeting_version_unique" UNIQUE("vault_id","meeting_id","version"),
	CONSTRAINT "transcript_version_check" CHECK ("version" >= 1),
	CONSTRAINT "transcript_status_check" CHECK ("status" IN ('live', 'completed', 'interrupted'))
);
--> statement-breakpoint
ALTER TABLE "app"."transcripts" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."transcript_segments" DROP CONSTRAINT "synced_transcript_segment_meeting_fk";--> statement-breakpoint
DROP INDEX "app"."synced_transcript_vault_meeting_start_id_idx";--> statement-breakpoint
ALTER TABLE "app"."transcript_segments" ADD COLUMN "transcript_id" uuid;--> statement-breakpoint
-- Rebind policies before dropping their old columns (Drizzle does not order this dependency).
ALTER POLICY "transcript_select" ON "app"."transcript_segments" TO public USING (exists (select 1 from "app"."transcripts" t where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_can_read_vault"(t.vault_id)));--> statement-breakpoint
ALTER POLICY "transcript_write" ON "app"."transcript_segments" TO public USING (exists (select 1 from "app"."transcripts" t where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_owns_vault"(t.vault_id))) WITH CHECK (exists (select 1 from "app"."transcripts" t where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_owns_vault"(t.vault_id)));
--> statement-breakpoint
ALTER TABLE "app"."transcript_segments" DROP COLUMN "vault_id";--> statement-breakpoint
ALTER TABLE "app"."transcript_segments" DROP COLUMN "meeting_id";--> statement-breakpoint
ALTER TABLE "app"."transcript_segments" ADD CONSTRAINT "synced_transcript_segment_pk" PRIMARY KEY("transcript_id","segment_id");--> statement-breakpoint
CREATE INDEX "transcript_segment_start_id_idx" ON "app"."transcript_segments" ("transcript_id","start_time","segment_id");--> statement-breakpoint
ALTER TABLE "app"."transcript_segments" ADD CONSTRAINT "transcript_segment_transcript_fk" FOREIGN KEY ("transcript_id") REFERENCES "app"."transcripts"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."transcripts" ADD CONSTRAINT "transcripts_78eXstqTF1O8_fkey" FOREIGN KEY ("vault_id","meeting_id") REFERENCES "app"."meetings"("vault_id","meeting_id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "transcript_version_select" ON "app"."transcripts" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."transcripts"."vault_id"));--> statement-breakpoint
CREATE POLICY "transcript_version_write" ON "app"."transcripts" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_owns_vault"("app"."transcripts"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."transcripts"."vault_id"));--> statement-breakpoint
