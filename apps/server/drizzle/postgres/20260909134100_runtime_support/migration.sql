-- Functions precede the generated policies that reference them.
CREATE UNIQUE INDEX "member_user_organization_idx" ON "auth"."member" ("user_id","organization_id");
--> statement-breakpoint
CREATE UNIQUE INDEX "team_member_user_team_idx" ON "auth"."team_member" ("user_id","team_id");
--> statement-breakpoint
CREATE FUNCTION "app"."current_identity_owns_vault"(target_vault_id uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT coalesce(current_setting('app.user_id', true), '') <> '' AND EXISTS (
    SELECT 1 FROM "app"."vault_permissions" permission
    WHERE permission."vault_id" = target_vault_id
      AND permission."principal_type" = 'user'
      AND permission."principal_id" = nullif(current_setting('app.user_id', true), '')::uuid
      AND permission."role" = 'owner'
  )
$$;
--> statement-breakpoint
CREATE FUNCTION "app"."current_identity_can_read_vault"(target_vault_id uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT "app"."current_identity_owns_vault"(target_vault_id) OR (
    current_setting('app.sharing_enabled', true) = 'true' AND EXISTS (
      SELECT 1 FROM "app"."vault_permissions" permission
      WHERE permission."vault_id" = target_vault_id AND permission."role" = 'member' AND (
        (permission."principal_type" = 'user' AND permission."principal_id" = nullif(current_setting('app.user_id', true), '')::uuid)
        OR (permission."principal_type" = 'organization' AND EXISTS (
          SELECT 1 FROM "auth"."member" membership
          WHERE membership."organization_id" = permission."principal_id"
            AND membership."user_id" = nullif(current_setting('app.user_id', true), '')::uuid
        ))
        OR (permission."principal_type" = 'team' AND EXISTS (
          SELECT 1 FROM "auth"."team_member" membership
          WHERE membership."team_id" = permission."principal_id"
            AND membership."user_id" = nullif(current_setting('app.user_id', true), '')::uuid
        ))
      )
    )
  )
$$;
--> statement-breakpoint
ALTER TABLE "app"."account_settings" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."meeting_events" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."meeting_attachments" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."search_documents" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."search_embeddings" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."summaries" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."jobs_summary" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."transaction_receipts" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."files" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."meetings" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."projects" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."recordings" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."transcript_segments" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."vaults" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."transcripts" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."transcript_patch_chunks" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."vault_transfers" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
-- Drizzle does not express DEFERRABLE foreign keys. Keep ordinary writes immediate;
-- the atomic transfer alone defers composite membership checks until commit.
DO $$
DECLARE membership record;
BEGIN
  FOR membership IN
    SELECT conrelid::regclass AS relation, conname
    FROM pg_constraint
    WHERE contype = 'f' AND cardinality(conkey) > 1
      AND connamespace = 'app'::regnamespace
      AND conrelid IN ('app.projects'::regclass, 'app.meetings'::regclass,
        'app.transcript_patch_chunks'::regclass, 'app.recordings'::regclass,
        'app.meeting_attachments'::regclass, 'app.search_documents'::regclass,
        'app.search_embeddings'::regclass)
  LOOP
    EXECUTE format('ALTER TABLE %s ALTER CONSTRAINT %I DEFERRABLE INITIALLY IMMEDIATE', membership.relation, membership.conname);
  END LOOP;
END $$;

--> statement-breakpoint
CREATE POLICY "account_settings_owner" ON "app"."account_settings" AS PERMISSIVE FOR ALL TO public USING ("app"."account_settings"."user_id" = nullif(current_setting('app.user_id', true), '')::uuid) WITH CHECK ("app"."account_settings"."user_id" = nullif(current_setting('app.user_id', true), '')::uuid);--> statement-breakpoint
CREATE POLICY "meeting_attachment_select" ON "app"."meeting_attachments" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."meeting_attachments"."vault_id"));--> statement-breakpoint
CREATE POLICY "meeting_attachment_write" ON "app"."meeting_attachments" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_owns_vault"("app"."meeting_attachments"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."meeting_attachments"."vault_id"));--> statement-breakpoint
CREATE POLICY "meeting_event_select" ON "app"."meeting_events" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."meeting_events"."vault_id"));--> statement-breakpoint
CREATE POLICY "meeting_event_write" ON "app"."meeting_events" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_owns_vault"("app"."meeting_events"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."meeting_events"."vault_id"));--> statement-breakpoint
CREATE POLICY "search_document_select" ON "app"."search_documents" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."search_documents"."vault_id"));--> statement-breakpoint
CREATE POLICY "search_document_write" ON "app"."search_documents" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_owns_vault"("app"."search_documents"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."search_documents"."vault_id"));--> statement-breakpoint
CREATE POLICY "search_embedding_select" ON "app"."search_embeddings" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."search_embeddings"."vault_id"));--> statement-breakpoint
CREATE POLICY "search_embedding_write" ON "app"."search_embeddings" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_owns_vault"("app"."search_embeddings"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."search_embeddings"."vault_id"));--> statement-breakpoint
CREATE POLICY "summary_select" ON "app"."summaries" AS PERMISSIVE FOR SELECT TO public USING (EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = "app"."summaries"."meeting_id" AND "app"."current_identity_can_read_vault"(m.vault_id)));--> statement-breakpoint
CREATE POLICY "summary_write" ON "app"."summaries" AS PERMISSIVE FOR ALL TO public USING (EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = "app"."summaries"."meeting_id" AND "app"."current_identity_owns_vault"(m.vault_id))) WITH CHECK (EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = "app"."summaries"."meeting_id" AND "app"."current_identity_owns_vault"(m.vault_id)));--> statement-breakpoint
CREATE POLICY "summary_job_owner" ON "app"."jobs_summary" AS PERMISSIVE FOR ALL TO public USING ("app"."jobs_summary"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid) WITH CHECK ("app"."jobs_summary"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid);--> statement-breakpoint
CREATE POLICY "transaction_receipt_owner" ON "app"."transaction_receipts" AS PERMISSIVE FOR ALL TO public USING ("app"."transaction_receipts"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid) WITH CHECK ("app"."transaction_receipts"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid);--> statement-breakpoint
CREATE POLICY "file_select" ON "app"."files" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."files"."vault_id"));--> statement-breakpoint
CREATE POLICY "file_write" ON "app"."files" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_owns_vault"("app"."files"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."files"."vault_id"));--> statement-breakpoint
CREATE POLICY "meeting_select" ON "app"."meetings" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."meetings"."vault_id"));--> statement-breakpoint
CREATE POLICY "meeting_write" ON "app"."meetings" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_owns_vault"("app"."meetings"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."meetings"."vault_id"));--> statement-breakpoint
CREATE POLICY "project_select" ON "app"."projects" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."projects"."vault_id"));--> statement-breakpoint
CREATE POLICY "project_insert" ON "app"."projects" AS PERMISSIVE FOR INSERT TO public WITH CHECK ("app"."current_identity_owns_vault"("app"."projects"."vault_id"));--> statement-breakpoint
CREATE POLICY "project_update" ON "app"."projects" AS PERMISSIVE FOR UPDATE TO public USING ("app"."current_identity_owns_vault"("app"."projects"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."projects"."vault_id"));--> statement-breakpoint
CREATE POLICY "project_delete" ON "app"."projects" AS PERMISSIVE FOR DELETE TO public USING ("app"."current_identity_owns_vault"("app"."projects"."vault_id"));--> statement-breakpoint
CREATE POLICY "recording_select" ON "app"."recordings" AS PERMISSIVE FOR SELECT TO public USING (EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = "app"."recordings"."meeting_id" AND "app"."current_identity_can_read_vault"("vault_id")));--> statement-breakpoint
CREATE POLICY "recording_write" ON "app"."recordings" AS PERMISSIVE FOR ALL TO public USING (EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = "app"."recordings"."meeting_id" AND "app"."current_identity_owns_vault"("vault_id"))) WITH CHECK (EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = "app"."recordings"."meeting_id" AND "app"."current_identity_owns_vault"("vault_id")));--> statement-breakpoint
CREATE POLICY "transcript_select" ON "app"."transcript_segments" AS PERMISSIVE FOR SELECT TO public USING (exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_can_read_vault"(m.vault_id)));--> statement-breakpoint
CREATE POLICY "transcript_write" ON "app"."transcript_segments" AS PERMISSIVE FOR ALL TO public USING (exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_owns_vault"(m.vault_id))) WITH CHECK (exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_owns_vault"(m.vault_id)));--> statement-breakpoint
CREATE POLICY "vault_select" ON "app"."vaults" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."vaults"."vault_id"));--> statement-breakpoint
CREATE POLICY "vault_insert" ON "app"."vaults" AS PERMISSIVE FOR INSERT TO public WITH CHECK (coalesce(current_setting('app.user_id', true), '') <> '');--> statement-breakpoint
CREATE POLICY "vault_update" ON "app"."vaults" AS PERMISSIVE FOR UPDATE TO public USING ("app"."current_identity_owns_vault"("app"."vaults"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."vaults"."vault_id"));--> statement-breakpoint
CREATE POLICY "vault_delete" ON "app"."vaults" AS PERMISSIVE FOR DELETE TO public USING ("app"."current_identity_owns_vault"("app"."vaults"."vault_id"));--> statement-breakpoint
CREATE POLICY "transcript_version_select" ON "app"."transcripts" AS PERMISSIVE FOR SELECT TO public USING (exists (select 1 from "app"."meetings" m where m.meeting_id = "app"."transcripts"."meeting_id" and "app"."current_identity_can_read_vault"(m.vault_id)));--> statement-breakpoint
CREATE POLICY "transcript_version_write" ON "app"."transcripts" AS PERMISSIVE FOR ALL TO public USING (exists (select 1 from "app"."meetings" m where m.meeting_id = "app"."transcripts"."meeting_id" and "app"."current_identity_owns_vault"(m.vault_id))) WITH CHECK (exists (select 1 from "app"."meetings" m where m.meeting_id = "app"."transcripts"."meeting_id" and "app"."current_identity_owns_vault"(m.vault_id)));--> statement-breakpoint
CREATE POLICY "transcript_patch_select" ON "app"."transcript_patch_chunks" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_owns_vault"("app"."transcript_patch_chunks"."vault_id"));--> statement-breakpoint
CREATE POLICY "transcript_patch_write" ON "app"."transcript_patch_chunks" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_owns_vault"("app"."transcript_patch_chunks"."vault_id")) WITH CHECK ("app"."current_identity_owns_vault"("app"."transcript_patch_chunks"."vault_id"));--> statement-breakpoint
CREATE POLICY "vault_transfer_reader" ON "app"."vault_transfers" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_vault"("app"."vault_transfers"."source_vault_id") OR "app"."current_identity_can_read_vault"("app"."vault_transfers"."destination_vault_id"));--> statement-breakpoint
CREATE POLICY "vault_transfer_owner" ON "app"."vault_transfers" AS PERMISSIVE FOR ALL TO public USING ("app"."vault_transfers"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid) WITH CHECK ("app"."vault_transfers"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid);
