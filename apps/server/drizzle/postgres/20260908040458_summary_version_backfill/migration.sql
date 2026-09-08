ALTER TABLE "app"."meetings" NO FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
INSERT INTO "app"."summary_versions" ("vault_id", "meeting_id", "revision", "title", "document", "created_at", "saved_at")
SELECT "vault_id", "meeting_id", "summary_revision", COALESCE("summary_title", ''), "summary_document", "summary_created_at", CURRENT_TIMESTAMP
FROM "app"."meetings" WHERE "summary_document" IS NOT NULL;
--> statement-breakpoint
ALTER TABLE "app"."meetings" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."summary_versions" FORCE ROW LEVEL SECURITY;
