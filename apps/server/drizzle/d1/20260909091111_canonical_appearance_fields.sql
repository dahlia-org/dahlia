UPDATE "projects" SET "icon" = COALESCE("icon", json_extract("appearance", '$.icon')), "color" = COALESCE("color", json_extract("appearance", '$.color')) WHERE "appearance" IS NOT NULL;
--> statement-breakpoint
UPDATE "vaults" SET "icon" = COALESCE("icon", json_extract("appearance", '$.icon')), "color" = COALESCE("color", json_extract("appearance", '$.color')) WHERE "appearance" IS NOT NULL;
--> statement-breakpoint
ALTER TABLE `projects` DROP COLUMN `appearance`;--> statement-breakpoint
ALTER TABLE `vaults` DROP COLUMN `appearance`;