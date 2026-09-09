ALTER TABLE "app"."image_analysis_jobs" RENAME TO "jobs_image_analysis";--> statement-breakpoint
ALTER TABLE "app"."search_index_jobs" RENAME TO "jobs_search_index";--> statement-breakpoint
ALTER TABLE "app"."storage_delete_jobs" RENAME TO "jobs_storage_delete";--> statement-breakpoint
ALTER TABLE "app"."summary_jobs" RENAME TO "jobs_summary";--> statement-breakpoint
ALTER TABLE "app"."recordings" DROP CONSTRAINT "recordings_F4PH1EVMFEtd_fkey";--> statement-breakpoint
ALTER TABLE "app"."account_settings" RENAME COLUMN "change_version" TO "revision";--> statement-breakpoint
DROP INDEX "app"."recordings_vault_session_idx";--> statement-breakpoint
ALTER TABLE "app"."projects" ADD COLUMN "icon" text;--> statement-breakpoint
ALTER TABLE "app"."projects" ADD COLUMN "color" text;--> statement-breakpoint
ALTER TABLE "app"."vaults" ADD COLUMN "icon" text;--> statement-breakpoint
ALTER TABLE "app"."vaults" ADD COLUMN "color" text;--> statement-breakpoint
ALTER POLICY "recording_select" ON "app"."recordings" TO public USING (EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = "app"."recordings"."meeting_id" AND "app"."current_identity_can_read_vault"("vault_id")));--> statement-breakpoint
ALTER POLICY "recording_write" ON "app"."recordings" TO public USING (EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = "app"."recordings"."meeting_id" AND "app"."current_identity_owns_vault"("vault_id"))) WITH CHECK (EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = "app"."recordings"."meeting_id" AND "app"."current_identity_owns_vault"("vault_id")));--> statement-breakpoint
ALTER TABLE "app"."recordings" DROP COLUMN "vault_id";--> statement-breakpoint
CREATE INDEX "recordings_meeting_session_idx" ON "app"."recordings" ("meeting_id","session_id");--> statement-breakpoint
ALTER TABLE "app"."recordings" ADD CONSTRAINT "recordings_meeting_id_meetings_meeting_id_fkey" FOREIGN KEY ("meeting_id") REFERENCES "app"."meetings"("meeting_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER POLICY "summary_job_owner" ON "app"."jobs_summary" TO public USING ("app"."jobs_summary"."owner_user_id" = nullif(current_setting('app.user_id', true), '')) WITH CHECK ("app"."jobs_summary"."owner_user_id" = nullif(current_setting('app.user_id', true), ''));