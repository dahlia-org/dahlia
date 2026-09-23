-- Remove the policy dependency before dropping its redundant projection column.
ALTER POLICY "agent_live_reader" ON "agent"."live_contexts" TO public USING (EXISTS (SELECT 1 FROM app.meetings m WHERE m.meeting_id = "agent"."live_contexts"."meeting_id" AND m.deleted_at IS NULL AND m.deleting_at IS NULL AND app.current_identity_can_read_workspace(m.workspace_id))) WITH CHECK (EXISTS (SELECT 1 FROM app.meetings m WHERE m.meeting_id = "agent"."live_contexts"."meeting_id" AND m.deleted_at IS NULL AND m.deleting_at IS NULL AND app.current_identity_can_read_workspace(m.workspace_id)));
--> statement-breakpoint
ALTER TABLE "agent"."live_contexts" DROP COLUMN "workspace_id";
