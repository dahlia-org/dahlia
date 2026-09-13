CREATE FUNCTION app.current_identity_can_read_vault(target_vault_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
        SELECT EXISTS (SELECT 1 FROM app.vault_permissions p WHERE p.vault_id = target_vault_id AND p.role IN ('admin', 'editor', 'viewer') AND (
          (p.principal_type = 'user' AND p.principal_id = nullif(current_setting('app.user_id', true), '')::uuid)
          OR (p.principal_type = 'organization' AND EXISTS (SELECT 1 FROM auth.member m WHERE m.organization_id = p.principal_id AND m.user_id = nullif(current_setting('app.user_id', true), '')::uuid))
          OR (p.principal_type = 'team' AND EXISTS (SELECT 1 FROM auth.team_member tm JOIN auth.team t ON t.id = tm.team_id JOIN auth.member m ON m.organization_id = t.organization_id AND m.user_id = tm.user_id
            WHERE tm.team_id = p.principal_id AND tm.user_id = nullif(current_setting('app.user_id', true), '')::uuid)))); $$;
--> statement-breakpoint
CREATE FUNCTION app.current_identity_can_write_vault(target_vault_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
        SELECT EXISTS (SELECT 1 FROM app.vault_permissions p WHERE p.vault_id = target_vault_id AND p.role IN ('admin', 'editor') AND (
          (p.principal_type = 'user' AND p.principal_id = nullif(current_setting('app.user_id', true), '')::uuid)
          OR (p.principal_type = 'organization' AND EXISTS (SELECT 1 FROM auth.member m WHERE m.organization_id = p.principal_id AND m.user_id = nullif(current_setting('app.user_id', true), '')::uuid))
          OR (p.principal_type = 'team' AND EXISTS (SELECT 1 FROM auth.team_member tm JOIN auth.team t ON t.id = tm.team_id JOIN auth.member m ON m.organization_id = t.organization_id AND m.user_id = tm.user_id
            WHERE tm.team_id = p.principal_id AND tm.user_id = nullif(current_setting('app.user_id', true), '')::uuid)))); $$;
--> statement-breakpoint
CREATE FUNCTION app.current_identity_can_admin_vault(target_vault_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
        SELECT EXISTS (SELECT 1 FROM app.vault_permissions p WHERE p.vault_id = target_vault_id AND p.role IN ('admin') AND (
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
ALTER TABLE "app"."vaults" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."transcripts" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."transcript_patch_chunks" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."vault_transfers" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
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
ALTER TABLE "crypto"."vault_keys" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
--> statement-breakpoint
CREATE POLICY "account_settings_owner" ON "app"."account_settings" FOR ALL USING ("app"."account_settings"."user_id" = nullif(current_setting('app.user_id', true), '')::uuid) WITH CHECK ("app"."account_settings"."user_id" = nullif(current_setting('app.user_id', true), '')::uuid);
--> statement-breakpoint
CREATE POLICY "meeting_attachment_select" ON "app"."meeting_attachments" FOR SELECT USING ("app"."current_identity_can_read_vault"("app"."meeting_attachments"."vault_id") OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.vault_id = "app"."meeting_attachments"."vault_id" AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "meeting_attachment_write" ON "app"."meeting_attachments" FOR ALL USING ("app"."current_identity_can_write_vault"("app"."meeting_attachments"."vault_id")) WITH CHECK ("app"."current_identity_can_write_vault"("app"."meeting_attachments"."vault_id"));
--> statement-breakpoint
CREATE POLICY "meeting_event_select" ON "app"."meeting_events" FOR SELECT USING ("app"."current_identity_can_read_vault"("app"."meeting_events"."vault_id") OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.vault_id = "app"."meeting_events"."vault_id" AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "meeting_event_write" ON "app"."meeting_events" FOR ALL USING ("app"."current_identity_can_write_vault"("app"."meeting_events"."vault_id") OR current_setting('app.maintenance', true) = 'rotation') WITH CHECK ("app"."current_identity_can_write_vault"("app"."meeting_events"."vault_id") OR current_setting('app.maintenance', true) = 'rotation');
--> statement-breakpoint
CREATE POLICY "search_document_select" ON "search"."documents" FOR SELECT USING ("app"."current_identity_can_read_vault"("search"."documents"."vault_id") OR (current_setting('app.maintenance', true) = 'search' AND "search"."documents"."vault_id" = nullif(current_setting('app.maintenance_vault_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "search_document_write" ON "search"."documents" FOR ALL USING ("app"."current_identity_can_write_vault"("search"."documents"."vault_id") OR (current_setting('app.maintenance', true) = 'search' AND "search"."documents"."vault_id" = nullif(current_setting('app.maintenance_vault_id', true), '')::uuid)) WITH CHECK ("app"."current_identity_can_write_vault"("search"."documents"."vault_id") OR (current_setting('app.maintenance', true) = 'search' AND "search"."documents"."vault_id" = nullif(current_setting('app.maintenance_vault_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "summary_select" ON "app"."summaries" FOR SELECT USING (EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = "app"."summaries"."meeting_id" AND "app"."current_identity_can_read_vault"(m.vault_id)));
--> statement-breakpoint
CREATE POLICY "summary_write" ON "app"."summaries" FOR ALL USING (EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = "app"."summaries"."meeting_id" AND "app"."current_identity_can_write_vault"(m.vault_id))) WITH CHECK (EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = "app"."summaries"."meeting_id" AND "app"."current_identity_can_write_vault"(m.vault_id)));
--> statement-breakpoint
CREATE POLICY "summary_job_owner" ON "jobs"."summary" FOR ALL USING ("jobs"."summary"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid) WITH CHECK ("jobs"."summary"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid);
--> statement-breakpoint
CREATE POLICY "transaction_receipt_owner" ON "app"."transaction_receipts" FOR ALL USING ("app"."transaction_receipts"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid OR current_setting('app.maintenance', true) = 'retention') WITH CHECK ("app"."transaction_receipts"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid OR current_setting('app.maintenance', true) = 'retention');
--> statement-breakpoint
CREATE POLICY "file_select" ON "app"."files" FOR SELECT USING ("app"."current_identity_can_read_vault"("app"."files"."vault_id") OR (current_setting('app.maintenance', true) = 'governance-delete' AND "app"."files"."vault_id" = nullif(current_setting('app.maintenance_vault_id', true), '')::uuid) OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.vault_id = "app"."files"."vault_id" AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "file_write" ON "app"."files" FOR ALL USING ("app"."current_identity_can_write_vault"("app"."files"."vault_id")) WITH CHECK ("app"."current_identity_can_write_vault"("app"."files"."vault_id"));
--> statement-breakpoint
CREATE POLICY "meeting_select" ON "app"."meetings" FOR SELECT USING ("app"."current_identity_can_read_vault"("app"."meetings"."vault_id") OR (current_setting('app.maintenance', true) IN ('search', 'storage', 'governance-delete') AND "app"."meetings"."vault_id" = nullif(current_setting('app.maintenance_vault_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "meeting_write" ON "app"."meetings" FOR ALL USING ("app"."current_identity_can_write_vault"("app"."meetings"."vault_id")) WITH CHECK ("app"."current_identity_can_write_vault"("app"."meetings"."vault_id"));
--> statement-breakpoint
CREATE POLICY "project_select" ON "app"."projects" FOR SELECT USING ("app"."current_identity_can_read_vault"("app"."projects"."vault_id"));
--> statement-breakpoint
CREATE POLICY "project_insert" ON "app"."projects" FOR INSERT WITH CHECK ("app"."current_identity_can_write_vault"("app"."projects"."vault_id"));
--> statement-breakpoint
CREATE POLICY "project_update" ON "app"."projects" FOR UPDATE USING ("app"."current_identity_can_write_vault"("app"."projects"."vault_id")) WITH CHECK ("app"."current_identity_can_write_vault"("app"."projects"."vault_id"));
--> statement-breakpoint
CREATE POLICY "project_delete" ON "app"."projects" FOR DELETE USING ("app"."current_identity_can_write_vault"("app"."projects"."vault_id"));
--> statement-breakpoint
CREATE POLICY "recording_select" ON "app"."recordings" FOR SELECT USING (EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = "app"."recordings"."meeting_id" AND ("app"."current_identity_can_read_vault"("vault_id") OR (current_setting('app.maintenance', true) IN ('storage', 'governance-delete') AND "vault_id" = nullif(current_setting('app.maintenance_vault_id', true), '')::uuid))));
--> statement-breakpoint
CREATE POLICY "recording_write" ON "app"."recordings" FOR ALL USING (EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = "app"."recordings"."meeting_id" AND ("app"."current_identity_can_write_vault"("vault_id") OR (current_setting('app.maintenance', true) IN ('storage', 'governance-delete') AND "vault_id" = nullif(current_setting('app.maintenance_vault_id', true), '')::uuid)))) WITH CHECK (EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = "app"."recordings"."meeting_id" AND ("app"."current_identity_can_write_vault"("vault_id") OR (current_setting('app.maintenance', true) IN ('storage', 'governance-delete') AND "vault_id" = nullif(current_setting('app.maintenance_vault_id', true), '')::uuid))));
--> statement-breakpoint
CREATE POLICY "transcript_select" ON "app"."transcript_segments" FOR SELECT USING (exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_can_read_vault"(m.vault_id)));
--> statement-breakpoint
CREATE POLICY "transcript_write" ON "app"."transcript_segments" FOR ALL USING (exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_can_write_vault"(m.vault_id))) WITH CHECK (exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_can_write_vault"(m.vault_id)));
--> statement-breakpoint
CREATE POLICY "vault_select" ON "app"."vaults" FOR SELECT USING ("app"."current_identity_can_read_vault"("app"."vaults"."vault_id") OR (current_setting('app.maintenance', true) = 'search' AND "app"."vaults"."vault_id" = nullif(current_setting('app.maintenance_vault_id', true), '')::uuid) OR current_setting('app.maintenance', true) = 'authorization' OR (current_setting('app.maintenance', true) = 'governance' AND "app"."vaults"."organization_id" = nullif(current_setting('app.maintenance_organization_id', true), '')::uuid) OR (current_setting('app.maintenance', true) = 'governance-delete' AND "app"."vaults"."vault_id" = nullif(current_setting('app.maintenance_vault_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "vault_insert" ON "app"."vaults" FOR INSERT WITH CHECK (coalesce(current_setting('app.user_id', true), '') <> '');
--> statement-breakpoint
CREATE POLICY "vault_update" ON "app"."vaults" FOR UPDATE USING ("app"."current_identity_can_admin_vault"("app"."vaults"."vault_id")) WITH CHECK ("app"."current_identity_can_admin_vault"("app"."vaults"."vault_id"));
--> statement-breakpoint
CREATE POLICY "vault_delete" ON "app"."vaults" FOR DELETE USING ("app"."current_identity_can_admin_vault"("app"."vaults"."vault_id") OR (current_setting('app.maintenance', true) = 'governance-delete' AND "app"."vaults"."vault_id" = nullif(current_setting('app.maintenance_vault_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "transcript_version_select" ON "app"."transcripts" FOR SELECT USING (exists (select 1 from "app"."meetings" m where m.meeting_id = "app"."transcripts"."meeting_id" and "app"."current_identity_can_read_vault"(m.vault_id)));
--> statement-breakpoint
CREATE POLICY "transcript_version_write" ON "app"."transcripts" FOR ALL USING (exists (select 1 from "app"."meetings" m where m.meeting_id = "app"."transcripts"."meeting_id" and "app"."current_identity_can_write_vault"(m.vault_id))) WITH CHECK (exists (select 1 from "app"."meetings" m where m.meeting_id = "app"."transcripts"."meeting_id" and "app"."current_identity_can_write_vault"(m.vault_id)));
--> statement-breakpoint
CREATE POLICY "transcript_patch_select" ON "app"."transcript_patch_chunks" FOR SELECT USING ("app"."current_identity_can_write_vault"("app"."transcript_patch_chunks"."vault_id"));
--> statement-breakpoint
CREATE POLICY "transcript_patch_write" ON "app"."transcript_patch_chunks" FOR ALL USING ("app"."current_identity_can_write_vault"("app"."transcript_patch_chunks"."vault_id")) WITH CHECK ("app"."current_identity_can_write_vault"("app"."transcript_patch_chunks"."vault_id"));
--> statement-breakpoint
CREATE POLICY "vault_key_read" ON "crypto"."vault_keys" FOR SELECT USING ("app"."current_identity_can_read_vault"("crypto"."vault_keys"."vault_id") OR (current_setting('app.maintenance', true) = 'governance-delete' AND "crypto"."vault_keys"."vault_id" = nullif(current_setting('app.maintenance_vault_id', true), '')::uuid) OR (current_setting('app.maintenance', true) = 'governance' AND EXISTS (SELECT 1 FROM app.vaults v WHERE v.vault_id = "crypto"."vault_keys"."vault_id" AND v.organization_id = nullif(current_setting('app.maintenance_organization_id', true), '')::uuid)) OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.vault_id = "crypto"."vault_keys"."vault_id" AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "vault_key_write" ON "crypto"."vault_keys" FOR ALL USING ("app"."current_identity_can_write_vault"("crypto"."vault_keys"."vault_id") OR current_setting('app.maintenance', true) = 'rotation') WITH CHECK ("app"."current_identity_can_write_vault"("crypto"."vault_keys"."vault_id") OR current_setting('app.maintenance', true) = 'rotation');
--> statement-breakpoint
CREATE POLICY "vault_transfer_reader" ON "app"."vault_transfers" FOR SELECT USING ("app"."current_identity_can_read_vault"("app"."vault_transfers"."source_vault_id") OR "app"."current_identity_can_read_vault"("app"."vault_transfers"."destination_vault_id"));
--> statement-breakpoint
CREATE POLICY "vault_transfer_owner" ON "app"."vault_transfers" FOR ALL USING ("app"."vault_transfers"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid) WITH CHECK ("app"."vault_transfers"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid);
