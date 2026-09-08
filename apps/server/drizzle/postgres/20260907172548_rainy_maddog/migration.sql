CREATE TABLE "app"."summary_jobs" (
	"id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"meeting_id" uuid NOT NULL,
	"owner_user_id" text NOT NULL,
	"method" text NOT NULL,
	"settings" jsonb NOT NULL,
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
	CONSTRAINT "summary_job_status_check" CHECK ("status" IN ('pending', 'processing', 'succeeded', 'failed'))
);
--> statement-breakpoint
ALTER TABLE "app"."summary_jobs" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."account_settings" ADD COLUMN "summary_method" text DEFAULT 'transcript' NOT NULL;--> statement-breakpoint
ALTER TABLE "app"."account_settings" ADD COLUMN "transcript_summary" jsonb DEFAULT '{"model":"gpt-5.4","reasoningEffort":"medium","detail":"detailed"}' NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX "summary_job_active_meeting_idx" ON "app"."summary_jobs" ("meeting_id") WHERE "status" IN ('pending', 'processing');--> statement-breakpoint
CREATE INDEX "summary_job_owner_created_idx" ON "app"."summary_jobs" ("owner_user_id","created_at");--> statement-breakpoint
ALTER TABLE "app"."summary_jobs" ADD CONSTRAINT "summary_jobs_vault_id_vaults_vault_id_fkey" FOREIGN KEY ("vault_id") REFERENCES "app"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."summary_jobs" ADD CONSTRAINT "summary_jobs_meeting_id_meetings_meeting_id_fkey" FOREIGN KEY ("meeting_id") REFERENCES "app"."meetings"("meeting_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."summary_jobs" ADD CONSTRAINT "summary_jobs_owner_user_id_user_id_fkey" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "summary_job_owner" ON "app"."summary_jobs" AS PERMISSIVE FOR ALL TO public USING ("app"."summary_jobs"."owner_user_id" = nullif(current_setting('app.user_id', true), '')) WITH CHECK ("app"."summary_jobs"."owner_user_id" = nullif(current_setting('app.user_id', true), ''));