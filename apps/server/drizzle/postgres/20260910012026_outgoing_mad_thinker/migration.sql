ALTER TABLE "app"."account_settings" ADD COLUMN "processing" jsonb DEFAULT '{"location":"local","remote":{"workflow":"transcribeThenSummarize"}}' NOT NULL;--> statement-breakpoint
ALTER TABLE "app"."account_settings" ALTER COLUMN "summary" SET DEFAULT '{"style":"detailed"}';--> statement-breakpoint
ALTER TABLE "app"."account_settings" NO FORCE ROW LEVEL SECURITY;--> statement-breakpoint
UPDATE "app"."account_settings" SET
  "processing" = jsonb_build_object(
    'location', "summary"->>'mode',
    'remote', jsonb_strip_nulls(jsonb_build_object(
      'workflow', CASE WHEN "summary"#>>'{remote,transcriptionModel}' IS NULL THEN 'combined' ELSE 'transcribeThenSummarize' END,
      'summaryModel', "summary"#>>'{remote,model}',
      'reasoningEffort', "summary"#>>'{remote,reasoningEffort}',
      'transcriptionModel', "summary"#>>'{remote,transcriptionModel}'
    ))
  ),
  "summary" = jsonb_build_object('style', CASE "summary"#>>'{remote,detail}'
    WHEN 'low' THEN 'concise' WHEN 'medium' THEN 'standard' WHEN 'high' THEN 'detailed'
    WHEN 'xhigh' THEN 'eventSummary' WHEN 'max' THEN 'eventTimeline'
    WHEN 'concise' THEN 'concise' WHEN 'standard' THEN 'standard' WHEN 'eventSession' THEN 'eventSummary'
    ELSE 'detailed' END),
  "revision" = "revision" + 1
WHERE "summary" ? 'mode';--> statement-breakpoint
ALTER TABLE "app"."account_settings" FORCE ROW LEVEL SECURITY;
