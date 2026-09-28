CREATE TABLE "search"."knowledge_pages" (
	"workspace_id" uuid,
	"id" text,
	"project_id" uuid,
	"generation" integer DEFAULT 0 NOT NULL,
	"snapshot" jsonb,
	"status" text DEFAULT 'generating' NOT NULL,
	"request_version" integer DEFAULT 0 NOT NULL,
	"completed_version" integer DEFAULT 0 NOT NULL,
	"operation" jsonb,
	CONSTRAINT "knowledge_pages_pkey" PRIMARY KEY("workspace_id","id")
);
--> statement-breakpoint
ALTER TABLE "search"."knowledge_pages" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "search"."knowledge_pages" ADD CONSTRAINT "knowledge_pages_workspace_id_workspaces_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "app"."workspaces"("workspace_id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "knowledge_page_read" ON "search"."knowledge_pages" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_workspace"("search"."knowledge_pages"."workspace_id"));--> statement-breakpoint
CREATE POLICY "knowledge_page_write" ON "search"."knowledge_pages" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_can_admin_workspace"("search"."knowledge_pages"."workspace_id")) WITH CHECK ("app"."current_identity_can_admin_workspace"("search"."knowledge_pages"."workspace_id"));