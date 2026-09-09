INSERT INTO "app"."server_initializations" ("name", "initialized_at")
SELECT 'default_organization', "created_at" FROM "auth"."organization" WHERE "id" = 'external'
ON CONFLICT DO NOTHING;
