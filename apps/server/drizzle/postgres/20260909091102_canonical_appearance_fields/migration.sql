ALTER TABLE "app"."projects" NO FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."vaults" NO FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
UPDATE "app"."projects" SET "icon" = COALESCE("icon", "appearance"->>'icon'), "color" = COALESCE("color", "appearance"->>'color') WHERE "appearance" IS NOT NULL;
--> statement-breakpoint
UPDATE "app"."vaults" SET "icon" = COALESCE("icon", "appearance"->>'icon'), "color" = COALESCE("color", "appearance"->>'color') WHERE "appearance" IS NOT NULL;
--> statement-breakpoint
ALTER TABLE "app"."projects" DROP COLUMN "appearance";--> statement-breakpoint
ALTER TABLE "app"."vaults" DROP COLUMN "appearance";
--> statement-breakpoint
ALTER TABLE "app"."projects" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."vaults" FORCE ROW LEVEL SECURITY;
