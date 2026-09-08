CREATE TABLE "app"."summary_versions" (
	"vault_id" uuid NOT NULL,
	"meeting_id" uuid,
	"revision" integer,
	"title" text NOT NULL,
	"document" text NOT NULL,
	"created_at" timestamp,
	"saved_at" timestamp NOT NULL,
	"metadata" jsonb,
	CONSTRAINT "summary_versions_pkey" PRIMARY KEY("meeting_id","revision")
);
--> statement-breakpoint
ALTER TABLE "app"."summary_versions" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."summary_versions" ADD CONSTRAINT "summary_versions_sZl8VO5eRGWR_fkey" FOREIGN KEY ("vault_id","meeting_id") REFERENCES "app"."meetings"("vault_id","meeting_id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "summary_version_select" ON "app"."summary_versions" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."summary_versions"."vault_id"));--> statement-breakpoint
CREATE POLICY "summary_version_write" ON "app"."summary_versions" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_owns_vault"("app"."summary_versions"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."summary_versions"."vault_id"));