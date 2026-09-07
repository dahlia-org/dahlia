CREATE TABLE "app"."recordings" (
	"session_id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"meeting_id" uuid NOT NULL,
	"number" integer NOT NULL,
	"started_at" timestamp NOT NULL,
	"ended_at" timestamp NOT NULL,
	"audio" jsonb NOT NULL,
	"revision" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp NOT NULL,
	"updated_at" timestamp NOT NULL,
	CONSTRAINT "recordings_meeting_number_unique" UNIQUE("meeting_id","number"),
	CONSTRAINT "recordings_number_check" CHECK ("number" > 0)
);
--> statement-breakpoint
ALTER TABLE "app"."recordings" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE INDEX "recordings_vault_session_idx" ON "app"."recordings" ("vault_id","session_id");--> statement-breakpoint
ALTER TABLE "app"."recordings" ADD CONSTRAINT "recordings_F4PH1EVMFEtd_fkey" FOREIGN KEY ("vault_id","meeting_id") REFERENCES "app"."meetings"("vault_id","meeting_id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "recording_select" ON "app"."recordings" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."recordings"."vault_id"));--> statement-breakpoint
CREATE POLICY "recording_write" ON "app"."recordings" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_owns_vault"("app"."recordings"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."recordings"."vault_id"));