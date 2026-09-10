ALTER TABLE "app"."account_settings" ALTER COLUMN "summary" SET DEFAULT '{"mode":"local","remote":{"detail":"high","model":"gemini-3-8-flash","reasoningEffort":"medium","transcriptionModel":"gemini-3-8-flash"}}';--> statement-breakpoint
ALTER TABLE "app"."account_settings" NO FORCE ROW LEVEL SECURITY;--> statement-breakpoint
UPDATE "app"."account_settings"
SET "summary" = jsonb_build_object(
  'mode', CASE WHEN "summary"->>'method' = 'transcript' THEN 'local' ELSE 'remote' END,
  'remote', jsonb_strip_nulls(jsonb_build_object(
    'detail', CASE "summary"->>'detail'
      WHEN 'concise' THEN 'low' WHEN 'standard' THEN 'medium'
      WHEN 'detailed' THEN 'high' WHEN 'eventSession' THEN 'xhigh'
      ELSE coalesce("summary"->>'detail', 'high') END,
    'model', CASE "summary"->>'method'
      WHEN 'cloudTranscription' THEN coalesce("summary"#>>'{methodSettings,transcript,model}', 'gemini-3-8-flash')
      WHEN 'audio' THEN coalesce("summary"#>>'{methodSettings,audio,model}', 'gemini-3-8-flash')
      ELSE 'gemini-3-8-flash' END,
    'reasoningEffort', CASE "summary"->>'method'
      WHEN 'cloudTranscription' THEN coalesce("summary"#>>'{methodSettings,transcript,reasoningEffort}', 'medium')
      WHEN 'audio' THEN coalesce("summary"#>>'{methodSettings,audio,reasoningEffort}', 'medium')
      ELSE 'medium' END,
    'transcriptionModel', CASE WHEN "summary"->>'method' = 'cloudTranscription'
      THEN coalesce("summary"#>>'{methodSettings,audio,model}', 'gemini-3-8-flash')
      WHEN "summary"->>'method' = 'transcript' THEN 'gemini-3-8-flash' END
  ))
)
WHERE "summary" ? 'method';--> statement-breakpoint
ALTER TABLE "app"."account_settings" FORCE ROW LEVEL SECURITY;
