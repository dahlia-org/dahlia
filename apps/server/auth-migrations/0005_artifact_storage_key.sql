ALTER TABLE "artifact" ADD "storageKey" text;

UPDATE "artifact" SET "storageKey" = 'artifacts/' || "id";
