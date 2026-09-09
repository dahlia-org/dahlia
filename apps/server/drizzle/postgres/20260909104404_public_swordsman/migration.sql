ALTER TABLE "app"."jobs_summary" ADD COLUMN "input" jsonb;--> statement-breakpoint
ALTER TABLE "app"."jobs_summary" ADD COLUMN "stage" text;--> statement-breakpoint
ALTER TABLE "app"."jobs_summary" ADD COLUMN "transcript_revision" integer;--> statement-breakpoint
ALTER TABLE "app"."jobs_summary" ADD COLUMN "transcript_result" jsonb;--> statement-breakpoint
ALTER TABLE "app"."account_settings" ALTER COLUMN "summary" SET DEFAULT '{"method":"transcript","detail":"high","methodSettings":{"transcript":{"model":"gpt-5.4","reasoningEffort":"medium"},"audio":{"model":"gemini-3-8-flash","reasoningEffort":"medium"}}}';--> statement-breakpoint
ALTER TABLE "app"."jobs_summary" DROP CONSTRAINT "summary_job_status_check", ADD CONSTRAINT "summary_job_status_check" CHECK ("status" IN ('pending', 'processing', 'succeeded', 'failed', 'cancelled'));