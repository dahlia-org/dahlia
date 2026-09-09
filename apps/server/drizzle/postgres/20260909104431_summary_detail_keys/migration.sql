ALTER TABLE "app"."account_settings" NO FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
UPDATE "app"."account_settings"
SET summary = jsonb_set(summary, '{detail}', to_jsonb(CASE summary->>'detail'
    WHEN 'concise' THEN 'low' WHEN 'standard' THEN 'medium'
    WHEN 'detailed' THEN 'high' WHEN 'eventSession' THEN 'xhigh' END)), revision = revision + 1
WHERE summary->>'detail' IN ('concise', 'standard', 'detailed', 'eventSession');
--> statement-breakpoint
ALTER TABLE "app"."account_settings" FORCE ROW LEVEL SECURITY;
