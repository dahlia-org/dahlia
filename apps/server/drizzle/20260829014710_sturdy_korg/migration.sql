ALTER TABLE "dahlia"."artifact" ADD COLUMN "storage_key" text;

UPDATE "dahlia"."artifact" SET "storage_key" = 'artifacts/' || "id";
