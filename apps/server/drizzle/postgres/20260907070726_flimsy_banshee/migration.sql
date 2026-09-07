CREATE TABLE "app"."meeting_events" (
	"id" uuid PRIMARY KEY,
	"vault_id" uuid NOT NULL,
	"owner_user_id" text NOT NULL,
	"meeting_id" uuid NOT NULL,
	"kind" text NOT NULL,
	"occurred_at" timestamp NOT NULL,
	"received_at" timestamp NOT NULL,
	"session_id" uuid,
	"related_id" text,
	"audio_source" text,
	"segment_index" integer,
	"changed_fields" text,
	CONSTRAINT "meeting_events_kind_check" CHECK ("kind" IN ('meeting_created', 'meeting_updated', 'meeting_deleted', 'tag_added', 'tag_removed', 'recording_started', 'recording_ended', 'segment_rotated')),
	CONSTRAINT "meeting_events_source_check" CHECK ("audio_source" IN ('mic', 'system'))
);
--> statement-breakpoint
ALTER TABLE "app"."meeting_events" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE INDEX "meeting_events_meeting_time_idx" ON "app"."meeting_events" ("vault_id","meeting_id","occurred_at","id");--> statement-breakpoint
CREATE INDEX "meeting_events_session_idx" ON "app"."meeting_events" ("vault_id","session_id");--> statement-breakpoint
ALTER TABLE "app"."meeting_events" ADD CONSTRAINT "meeting_events_vault_id_vaults_vault_id_fkey" FOREIGN KEY ("vault_id") REFERENCES "app"."vaults"("vault_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "app"."meeting_events" ADD CONSTRAINT "meeting_events_owner_user_id_user_id_fkey" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;--> statement-breakpoint
CREATE VIEW "app"."recording_sessions" WITH (security_invoker = true) AS (
  SELECT vault_id, meeting_id, session_id,
    min(CASE WHEN kind = 'recording_started' THEN occurred_at END) AS started_at,
    max(CASE WHEN kind = 'recording_ended' THEN occurred_at END) AS ended_at
  FROM app.meeting_events
  WHERE session_id IS NOT NULL AND kind IN ('recording_started', 'recording_ended')
  GROUP BY vault_id, meeting_id, session_id
);--> statement-breakpoint
CREATE POLICY "meeting_event_select" ON "app"."meeting_events" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."meeting_events"."vault_id"));--> statement-breakpoint
CREATE POLICY "meeting_event_write" ON "app"."meeting_events" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_owns_vault"("app"."meeting_events"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."meeting_events"."vault_id"));