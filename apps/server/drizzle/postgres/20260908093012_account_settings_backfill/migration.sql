ALTER TABLE "app"."account_settings" NO FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
UPDATE "app"."account_settings" SET "summary" = jsonb_build_object(
  'method', summary_method,
  'detail', CASE WHEN summary_method = 'audio' THEN audio_summary->>'detail' ELSE transcript_summary->>'detail' END,
  'methodSettings', jsonb_build_object('transcript', transcript_summary - 'detail', 'audio', audio_summary - 'detail')
);
--> statement-breakpoint
ALTER TABLE "app"."account_settings" FORCE ROW LEVEL SECURITY;
