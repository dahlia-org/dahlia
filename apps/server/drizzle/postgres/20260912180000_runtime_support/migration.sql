CREATE FUNCTION app.current_identity_can_read_workspace(target_workspace_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
        SELECT EXISTS (SELECT 1 FROM app.workspace_permissions p WHERE p.workspace_id = target_workspace_id AND p.role IN ('admin', 'editor', 'viewer') AND (
          (p.principal_type = 'user' AND p.principal_id = nullif(current_setting('app.user_id', true), '')::uuid)
          OR (p.principal_type = 'organization' AND EXISTS (SELECT 1 FROM auth.member m WHERE m.organization_id = p.principal_id AND m.user_id = nullif(current_setting('app.user_id', true), '')::uuid))
          OR (p.principal_type = 'team' AND EXISTS (SELECT 1 FROM auth.team_member tm JOIN auth.team t ON t.id = tm.team_id JOIN auth.member m ON m.organization_id = t.organization_id AND m.user_id = tm.user_id
            WHERE tm.team_id = p.principal_id AND tm.user_id = nullif(current_setting('app.user_id', true), '')::uuid)))); $$;
--> statement-breakpoint
CREATE FUNCTION app.current_identity_can_write_workspace(target_workspace_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
        SELECT EXISTS (SELECT 1 FROM app.workspace_permissions p WHERE p.workspace_id = target_workspace_id AND p.role IN ('admin', 'editor') AND (
          (p.principal_type = 'user' AND p.principal_id = nullif(current_setting('app.user_id', true), '')::uuid)
          OR (p.principal_type = 'organization' AND EXISTS (SELECT 1 FROM auth.member m WHERE m.organization_id = p.principal_id AND m.user_id = nullif(current_setting('app.user_id', true), '')::uuid))
          OR (p.principal_type = 'team' AND EXISTS (SELECT 1 FROM auth.team_member tm JOIN auth.team t ON t.id = tm.team_id JOIN auth.member m ON m.organization_id = t.organization_id AND m.user_id = tm.user_id
            WHERE tm.team_id = p.principal_id AND tm.user_id = nullif(current_setting('app.user_id', true), '')::uuid)))); $$;
--> statement-breakpoint
CREATE FUNCTION app.current_identity_can_admin_workspace(target_workspace_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
        SELECT EXISTS (SELECT 1 FROM app.workspace_permissions p WHERE p.workspace_id = target_workspace_id AND p.role IN ('admin') AND (
          (p.principal_type = 'user' AND p.principal_id = nullif(current_setting('app.user_id', true), '')::uuid)
          OR (p.principal_type = 'organization' AND EXISTS (SELECT 1 FROM auth.member m WHERE m.organization_id = p.principal_id AND m.user_id = nullif(current_setting('app.user_id', true), '')::uuid))
          OR (p.principal_type = 'team' AND EXISTS (SELECT 1 FROM auth.team_member tm JOIN auth.team t ON t.id = tm.team_id JOIN auth.member m ON m.organization_id = t.organization_id AND m.user_id = tm.user_id
            WHERE tm.team_id = p.principal_id AND tm.user_id = nullif(current_setting('app.user_id', true), '')::uuid)))); $$;
--> statement-breakpoint
CREATE UNIQUE INDEX "member_user_organization_idx" ON "auth"."member" ("user_id","organization_id");--> statement-breakpoint
CREATE UNIQUE INDEX "team_member_user_team_idx" ON "auth"."team_member" ("user_id","team_id");--> statement-breakpoint
ALTER TABLE "app"."account_settings" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."meeting_events" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."meeting_attachments" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "search"."documents" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."summaries" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "jobs"."summary" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."transaction_receipts" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."files" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."meetings" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."projects" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."recordings" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."transcript_segments" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."workspaces" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."transcripts" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."transcript_patch_chunks" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."workspace_transfers" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
-- Drizzle does not express DEFERRABLE foreign keys. Keep ordinary writes immediate;
-- the atomic transfer alone defers composite membership checks until commit.
DO $$
DECLARE membership record;
BEGIN
  FOR membership IN
    SELECT conrelid::regclass AS relation, conname
    FROM pg_constraint
    WHERE contype = 'f' AND cardinality(conkey) > 1
      AND connamespace IN ('app'::regnamespace, 'search'::regnamespace)
      AND conrelid IN ('app.projects'::regclass, 'app.meetings'::regclass,
        'app.transcript_patch_chunks'::regclass, 'app.recordings'::regclass,
        'app.meeting_attachments'::regclass, 'search.documents'::regclass)
  LOOP
    EXECUTE format('ALTER TABLE %s ALTER CONSTRAINT %I DEFERRABLE INITIALLY IMMEDIATE', membership.relation, membership.conname);
  END LOOP;
END $$;--> statement-breakpoint
ALTER TABLE "crypto"."workspace_keys" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
--> statement-breakpoint
CREATE POLICY "account_settings_owner" ON "app"."account_settings" AS PERMISSIVE FOR ALL TO public USING ("app"."account_settings"."user_id" = nullif(current_setting('app.user_id', true), '')::uuid) WITH CHECK ("app"."account_settings"."user_id" = nullif(current_setting('app.user_id', true), '')::uuid);
--> statement-breakpoint
CREATE POLICY "meeting_attachment_select" ON "app"."meeting_attachments" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_workspace"("app"."meeting_attachments"."workspace_id") OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.workspace_id = "app"."meeting_attachments"."workspace_id" AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "meeting_attachment_write" ON "app"."meeting_attachments" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_can_write_workspace"("app"."meeting_attachments"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."meeting_attachments"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "meeting_event_select" ON "app"."meeting_events" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_workspace"("app"."meeting_events"."workspace_id") OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.workspace_id = "app"."meeting_events"."workspace_id" AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "meeting_event_write" ON "app"."meeting_events" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_can_write_workspace"("app"."meeting_events"."workspace_id") OR current_setting('app.maintenance', true) = 'rotation') WITH CHECK ("app"."current_identity_can_write_workspace"("app"."meeting_events"."workspace_id") OR current_setting('app.maintenance', true) = 'rotation');
--> statement-breakpoint
CREATE POLICY "search_document_select" ON "search"."documents" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_workspace"("search"."documents"."workspace_id") OR (current_setting('app.maintenance', true) = 'search' AND "search"."documents"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "search_document_write" ON "search"."documents" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_can_write_workspace"("search"."documents"."workspace_id") OR (current_setting('app.maintenance', true) = 'search' AND "search"."documents"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid)) WITH CHECK ("app"."current_identity_can_write_workspace"("search"."documents"."workspace_id") OR (current_setting('app.maintenance', true) = 'search' AND "search"."documents"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "summary_select" ON "app"."summaries" AS PERMISSIVE FOR SELECT TO public USING (EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = "app"."summaries"."meeting_id" AND "app"."current_identity_can_read_workspace"(m.workspace_id)));
--> statement-breakpoint
CREATE POLICY "summary_write" ON "app"."summaries" AS PERMISSIVE FOR ALL TO public USING (EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = "app"."summaries"."meeting_id" AND "app"."current_identity_can_write_workspace"(m.workspace_id))) WITH CHECK (EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = "app"."summaries"."meeting_id" AND "app"."current_identity_can_write_workspace"(m.workspace_id)));
--> statement-breakpoint
CREATE POLICY "summary_job_owner" ON "jobs"."summary" AS PERMISSIVE FOR ALL TO public USING ("jobs"."summary"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid) WITH CHECK ("jobs"."summary"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid);
--> statement-breakpoint
CREATE POLICY "transaction_receipt_owner" ON "app"."transaction_receipts" AS PERMISSIVE FOR ALL TO public USING ("app"."transaction_receipts"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid OR current_setting('app.maintenance', true) = 'retention') WITH CHECK ("app"."transaction_receipts"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid OR current_setting('app.maintenance', true) = 'retention');
--> statement-breakpoint
CREATE POLICY "file_select" ON "app"."files" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_workspace"("app"."files"."workspace_id") OR (current_setting('app.maintenance', true) = 'governance-delete' AND "app"."files"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.workspace_id = "app"."files"."workspace_id" AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "file_write" ON "app"."files" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_can_write_workspace"("app"."files"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."files"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "meeting_select" ON "app"."meetings" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_workspace"("app"."meetings"."workspace_id") OR (current_setting('app.maintenance', true) IN ('search', 'storage', 'governance-delete') AND "app"."meetings"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "meeting_write" ON "app"."meetings" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_can_write_workspace"("app"."meetings"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."meetings"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "project_select" ON "app"."projects" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_workspace"("app"."projects"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "project_insert" ON "app"."projects" AS PERMISSIVE FOR INSERT TO public WITH CHECK ("app"."current_identity_can_write_workspace"("app"."projects"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "project_update" ON "app"."projects" AS PERMISSIVE FOR UPDATE TO public USING ("app"."current_identity_can_write_workspace"("app"."projects"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."projects"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "project_delete" ON "app"."projects" AS PERMISSIVE FOR DELETE TO public USING ("app"."current_identity_can_write_workspace"("app"."projects"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "recording_select" ON "app"."recordings" AS PERMISSIVE FOR SELECT TO public USING (EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = "app"."recordings"."meeting_id" AND ("app"."current_identity_can_read_workspace"("workspace_id") OR (current_setting('app.maintenance', true) IN ('storage', 'governance-delete') AND "workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid))));
--> statement-breakpoint
CREATE POLICY "recording_write" ON "app"."recordings" AS PERMISSIVE FOR ALL TO public USING (EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = "app"."recordings"."meeting_id" AND ("app"."current_identity_can_write_workspace"("workspace_id") OR (current_setting('app.maintenance', true) IN ('storage', 'governance-delete') AND "workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid)))) WITH CHECK (EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = "app"."recordings"."meeting_id" AND ("app"."current_identity_can_write_workspace"("workspace_id") OR (current_setting('app.maintenance', true) IN ('storage', 'governance-delete') AND "workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid))));
--> statement-breakpoint
CREATE POLICY "transcript_select" ON "app"."transcript_segments" AS PERMISSIVE FOR SELECT TO public USING (exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_can_read_workspace"(m.workspace_id)));
--> statement-breakpoint
CREATE POLICY "transcript_write" ON "app"."transcript_segments" AS PERMISSIVE FOR ALL TO public USING (exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_can_write_workspace"(m.workspace_id))) WITH CHECK (exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_can_write_workspace"(m.workspace_id)));
--> statement-breakpoint
CREATE POLICY "workspace_select" ON "app"."workspaces" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_workspace"("app"."workspaces"."workspace_id") OR (current_setting('app.maintenance', true) = 'search' AND "app"."workspaces"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR current_setting('app.maintenance', true) = 'authorization' OR (current_setting('app.maintenance', true) = 'governance' AND "app"."workspaces"."organization_id" = nullif(current_setting('app.maintenance_organization_id', true), '')::uuid) OR (current_setting('app.maintenance', true) = 'governance-delete' AND "app"."workspaces"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "workspace_insert" ON "app"."workspaces" AS PERMISSIVE FOR INSERT TO public WITH CHECK (coalesce(current_setting('app.user_id', true), '') <> '');
--> statement-breakpoint
CREATE POLICY "workspace_update" ON "app"."workspaces" AS PERMISSIVE FOR UPDATE TO public USING ("app"."current_identity_can_admin_workspace"("app"."workspaces"."workspace_id")) WITH CHECK ("app"."current_identity_can_admin_workspace"("app"."workspaces"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "workspace_delete" ON "app"."workspaces" AS PERMISSIVE FOR DELETE TO public USING ("app"."current_identity_can_admin_workspace"("app"."workspaces"."workspace_id") OR (current_setting('app.maintenance', true) = 'governance-delete' AND "app"."workspaces"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "transcript_version_select" ON "app"."transcripts" AS PERMISSIVE FOR SELECT TO public USING (exists (select 1 from "app"."meetings" m where m.meeting_id = "app"."transcripts"."meeting_id" and "app"."current_identity_can_read_workspace"(m.workspace_id)));
--> statement-breakpoint
CREATE POLICY "transcript_version_write" ON "app"."transcripts" AS PERMISSIVE FOR ALL TO public USING (exists (select 1 from "app"."meetings" m where m.meeting_id = "app"."transcripts"."meeting_id" and "app"."current_identity_can_write_workspace"(m.workspace_id))) WITH CHECK (exists (select 1 from "app"."meetings" m where m.meeting_id = "app"."transcripts"."meeting_id" and "app"."current_identity_can_write_workspace"(m.workspace_id)));
--> statement-breakpoint
CREATE POLICY "transcript_patch_select" ON "app"."transcript_patch_chunks" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_write_workspace"("app"."transcript_patch_chunks"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "transcript_patch_write" ON "app"."transcript_patch_chunks" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_can_write_workspace"("app"."transcript_patch_chunks"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."transcript_patch_chunks"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "workspace_key_read" ON "crypto"."workspace_keys" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_workspace"("crypto"."workspace_keys"."workspace_id") OR (current_setting('app.maintenance', true) = 'governance-delete' AND "crypto"."workspace_keys"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR (current_setting('app.maintenance', true) = 'governance' AND EXISTS (SELECT 1 FROM app.workspaces v WHERE v.workspace_id = "crypto"."workspace_keys"."workspace_id" AND v.organization_id = nullif(current_setting('app.maintenance_organization_id', true), '')::uuid)) OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.workspace_id = "crypto"."workspace_keys"."workspace_id" AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "workspace_key_write" ON "crypto"."workspace_keys" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_can_write_workspace"("crypto"."workspace_keys"."workspace_id") OR current_setting('app.maintenance', true) = 'rotation') WITH CHECK ("app"."current_identity_can_write_workspace"("crypto"."workspace_keys"."workspace_id") OR current_setting('app.maintenance', true) = 'rotation');
--> statement-breakpoint
CREATE POLICY "workspace_transfer_reader" ON "app"."workspace_transfers" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_workspace"("app"."workspace_transfers"."source_workspace_id") OR "app"."current_identity_can_read_workspace"("app"."workspace_transfers"."destination_workspace_id"));
--> statement-breakpoint
CREATE POLICY "workspace_transfer_owner" ON "app"."workspace_transfers" AS PERMISSIVE FOR ALL TO public USING ("app"."workspace_transfers"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid) WITH CHECK ("app"."workspace_transfers"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid);
