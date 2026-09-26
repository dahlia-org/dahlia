CREATE TABLE "app"."screenshot_assessments" (
	"file_id" uuid PRIMARY KEY,
	"workspace_id" uuid NOT NULL,
	"model" text NOT NULL,
	"informative" boolean NOT NULL,
	"reason" text,
	"created_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "app"."screenshot_assessments" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE INDEX "screenshot_assessments_workspace_idx" ON "app"."screenshot_assessments" ("workspace_id");--> statement-breakpoint
ALTER TABLE "app"."screenshot_assessments" ADD CONSTRAINT "screenshot_assessments_file_id_files_file_id_fkey" FOREIGN KEY ("file_id") REFERENCES "app"."files"("file_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."screenshot_assessments" ADD CONSTRAINT "screenshot_assessments_x4FhpYJysXuR_fkey" FOREIGN KEY ("workspace_id") REFERENCES "app"."workspaces"("workspace_id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "screenshot_assessment_read" ON "app"."screenshot_assessments" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_workspace"("app"."screenshot_assessments"."workspace_id"));--> statement-breakpoint
CREATE POLICY "screenshot_assessment_write" ON "app"."screenshot_assessments" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_can_write_workspace"("app"."screenshot_assessments"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."screenshot_assessments"."workspace_id"));