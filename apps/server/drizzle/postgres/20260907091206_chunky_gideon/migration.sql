CREATE TABLE "app"."account_settings" (
	"user_id" text PRIMARY KEY,
	"output_language" text NOT NULL,
	"analysis_languages" jsonb NOT NULL
);
--> statement-breakpoint
ALTER TABLE "app"."account_settings" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "app"."image_analysis_jobs" (
	"file_id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"owner_user_id" text NOT NULL,
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
CREATE INDEX "image_analysis_job_claim_idx" ON "app"."image_analysis_jobs" ("status","available_at","lease_expires_at");--> statement-breakpoint
ALTER TABLE "app"."account_settings" ADD CONSTRAINT "account_settings_user_id_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."image_analysis_jobs" ADD CONSTRAINT "image_analysis_jobs_file_id_files_file_id_fkey" FOREIGN KEY ("file_id") REFERENCES "app"."files"("file_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."image_analysis_jobs" ADD CONSTRAINT "image_analysis_jobs_vault_id_vaults_vault_id_fkey" FOREIGN KEY ("vault_id") REFERENCES "app"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."image_analysis_jobs" ADD CONSTRAINT "image_analysis_jobs_owner_user_id_user_id_fkey" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "account_settings_owner" ON "app"."account_settings" AS PERMISSIVE FOR ALL TO public USING ("app"."account_settings"."user_id" = nullif(current_setting('app.user_id', true), '')) WITH CHECK ("app"."account_settings"."user_id" = nullif(current_setting('app.user_id', true), ''));