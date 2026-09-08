-- Validate the replacement foreign key against every existing meeting under the migration owner.
ALTER TABLE "app"."meetings" NO FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."transcripts" NO FORCE ROW LEVEL SECURITY;--> statement-breakpoint
-- Rebind policies and drop the old unique constraint before their vault_id column (Drizzle does not order these dependencies).
ALTER POLICY "transcript_select" ON "app"."transcript_segments" TO public USING (exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_can_read_vault"(m.vault_id)));--> statement-breakpoint
ALTER POLICY "transcript_write" ON "app"."transcript_segments" TO public USING (exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_owns_vault"(m.vault_id))) WITH CHECK (exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_owns_vault"(m.vault_id)));--> statement-breakpoint
ALTER POLICY "transcript_version_select" ON "app"."transcripts" TO public USING (exists (select 1 from "app"."meetings" m where m.meeting_id = "app"."transcripts"."meeting_id" and "app"."current_identity_can_read_vault"(m.vault_id)));--> statement-breakpoint
ALTER POLICY "transcript_version_write" ON "app"."transcripts" TO public USING (exists (select 1 from "app"."meetings" m where m.meeting_id = "app"."transcripts"."meeting_id" and "app"."current_identity_owns_vault"(m.vault_id))) WITH CHECK (exists (select 1 from "app"."meetings" m where m.meeting_id = "app"."transcripts"."meeting_id" and "app"."current_identity_owns_vault"(m.vault_id)));--> statement-breakpoint
ALTER TABLE "app"."transcripts" DROP CONSTRAINT "transcript_meeting_version_unique";--> statement-breakpoint
ALTER TABLE "app"."transcripts" DROP CONSTRAINT "transcripts_78eXstqTF1O8_fkey";--> statement-breakpoint
ALTER TABLE "app"."transcript_segments" RENAME COLUMN "start_time" TO "started_at";--> statement-breakpoint
ALTER TABLE "app"."transcript_segments" RENAME COLUMN "end_time" TO "ended_at";--> statement-breakpoint
ALTER TABLE "app"."transcripts" RENAME COLUMN "completed_at" TO "ended_at";--> statement-breakpoint
ALTER TABLE "app"."transcripts" RENAME COLUMN "saved_at" TO "created_at";--> statement-breakpoint
ALTER TABLE "app"."transcripts" DROP CONSTRAINT "transcript_status_check";--> statement-breakpoint
ALTER TABLE "app"."transcript_segments" ADD COLUMN "created_at" timestamp;--> statement-breakpoint
ALTER TABLE "app"."transcript_segments" DROP COLUMN "is_confirmed";--> statement-breakpoint
ALTER TABLE "app"."transcripts" DROP COLUMN "vault_id";--> statement-breakpoint
ALTER TABLE "app"."transcripts" DROP COLUMN "status";--> statement-breakpoint
ALTER TABLE "app"."transcripts" ADD CONSTRAINT "transcript_meeting_version_unique" UNIQUE("meeting_id","version");--> statement-breakpoint
CREATE INDEX "transcript_segment_created_idx" ON "app"."transcript_segments" ("transcript_id","created_at");--> statement-breakpoint
ALTER TABLE "app"."transcripts" ADD CONSTRAINT "transcripts_meeting_id_meetings_meeting_id_fkey" FOREIGN KEY ("meeting_id") REFERENCES "app"."meetings"("meeting_id") ON DELETE CASCADE;
--> statement-breakpoint
ALTER TABLE "app"."meetings" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."transcripts" FORCE ROW LEVEL SECURITY;
