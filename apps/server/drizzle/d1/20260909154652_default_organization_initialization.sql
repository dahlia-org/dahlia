INSERT INTO "server_initializations" ("name", "initialized_at")
SELECT 'default_organization', "created_at" FROM "organization" WHERE "id" = 'external'
ON CONFLICT DO NOTHING;
