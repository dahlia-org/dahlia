CREATE TABLE "app"."summaries" (
	"id" uuid PRIMARY KEY,
	"meeting_id" uuid NOT NULL,
	"version" integer NOT NULL,
	"title" text NOT NULL,
	"document" text NOT NULL,
	"created_at" timestamp,
	"saved_at" timestamp NOT NULL,
	"metadata" jsonb,
	CONSTRAINT "summary_meeting_version_unique" UNIQUE("meeting_id","version")
);
--> statement-breakpoint
ALTER TABLE "app"."summaries" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
DROP POLICY "summary_version_select" ON "app"."summary_versions";--> statement-breakpoint
DROP POLICY "summary_version_write" ON "app"."summary_versions";--> statement-breakpoint
DROP TABLE "app"."summary_versions";--> statement-breakpoint
ALTER TABLE "app"."meetings" DROP COLUMN "summary_title";--> statement-breakpoint
ALTER TABLE "app"."meetings" DROP COLUMN "summary_document";--> statement-breakpoint
ALTER TABLE "app"."meetings" DROP COLUMN "summary_created_at";--> statement-breakpoint
ALTER TABLE "app"."summaries" ADD CONSTRAINT "summaries_meeting_id_meetings_meeting_id_fkey" FOREIGN KEY ("meeting_id") REFERENCES "app"."meetings"("meeting_id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "summary_select" ON "app"."summaries" AS PERMISSIVE FOR SELECT TO public USING (EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = "app"."summaries"."meeting_id" AND "app"."current_identity_can_read_vault"(m.vault_id)));--> statement-breakpoint
CREATE POLICY "summary_write" ON "app"."summaries" AS PERMISSIVE FOR ALL TO public USING (EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = "app"."summaries"."meeting_id" AND "app"."current_identity_owns_vault"(m.vault_id))) WITH CHECK (EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = "app"."summaries"."meeting_id" AND "app"."current_identity_owns_vault"(m.vault_id)));