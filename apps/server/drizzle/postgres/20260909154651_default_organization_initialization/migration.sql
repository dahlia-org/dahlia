INSERT INTO "app"."server_initializations" ("name", "initialized_at")
SELECT 'default_organization', "created_at" FROM "auth"."organization" WHERE "id" = '01990ab0-0000-7000-8000-000000000001'
ON CONFLICT DO NOTHING;
