INSERT INTO "summary_versions" ("vault_id", "meeting_id", "revision", "title", "document", "created_at", "saved_at")
SELECT "vault_id", "meeting_id", "summary_revision", COALESCE("summary_title", ''), "summary_document", "summary_created_at", CAST(strftime('%s', 'now') AS INTEGER) * 1000
FROM "meetings" WHERE "summary_document" IS NOT NULL;
