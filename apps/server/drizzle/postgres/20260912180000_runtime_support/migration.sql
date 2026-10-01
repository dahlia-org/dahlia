CREATE FUNCTION app.current_identity_can_read_workspace(target_workspace_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
        SELECT EXISTS (SELECT 1 FROM app.workspace_permissions p JOIN app.workspaces w ON w.workspace_id = p.workspace_id
        WHERE (w.personal_user_id IS NULL OR (w.personal_user_id = nullif(current_setting('app.user_id', true), '')::uuid
          AND EXISTS (SELECT 1 FROM auth.member m WHERE m.organization_id = w.organization_id AND m.user_id = w.personal_user_id)))
        AND p.workspace_id = target_workspace_id AND p.role IN ('admin', 'editor', 'viewer') AND (
          (p.principal_type = 'user' AND p.principal_id = nullif(current_setting('app.user_id', true), '')::uuid)
          OR (p.principal_type = 'organization' AND EXISTS (SELECT 1 FROM auth.member m WHERE m.organization_id = p.principal_id AND m.user_id = nullif(current_setting('app.user_id', true), '')::uuid))
          OR (p.principal_type = 'team' AND EXISTS (SELECT 1 FROM auth.team_member tm JOIN auth.team t ON t.id = tm.team_id JOIN auth.member m ON m.organization_id = t.organization_id AND m.user_id = tm.user_id
            WHERE tm.team_id = p.principal_id AND tm.user_id = nullif(current_setting('app.user_id', true), '')::uuid)))); $$;
--> statement-breakpoint
CREATE FUNCTION app.current_identity_can_write_workspace(target_workspace_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
        SELECT EXISTS (SELECT 1 FROM app.workspace_permissions p JOIN app.workspaces w ON w.workspace_id = p.workspace_id
        WHERE (w.personal_user_id IS NULL OR (w.personal_user_id = nullif(current_setting('app.user_id', true), '')::uuid
          AND EXISTS (SELECT 1 FROM auth.member m WHERE m.organization_id = w.organization_id AND m.user_id = w.personal_user_id)))
        AND p.workspace_id = target_workspace_id AND p.role IN ('admin', 'editor') AND (
          (p.principal_type = 'user' AND p.principal_id = nullif(current_setting('app.user_id', true), '')::uuid)
          OR (p.principal_type = 'organization' AND EXISTS (SELECT 1 FROM auth.member m WHERE m.organization_id = p.principal_id AND m.user_id = nullif(current_setting('app.user_id', true), '')::uuid))
          OR (p.principal_type = 'team' AND EXISTS (SELECT 1 FROM auth.team_member tm JOIN auth.team t ON t.id = tm.team_id JOIN auth.member m ON m.organization_id = t.organization_id AND m.user_id = tm.user_id
            WHERE tm.team_id = p.principal_id AND tm.user_id = nullif(current_setting('app.user_id', true), '')::uuid)))); $$;
--> statement-breakpoint
CREATE FUNCTION app.current_identity_can_admin_workspace(target_workspace_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
        SELECT EXISTS (SELECT 1 FROM app.workspace_permissions p JOIN app.workspaces w ON w.workspace_id = p.workspace_id
        WHERE (w.personal_user_id IS NULL OR (w.personal_user_id = nullif(current_setting('app.user_id', true), '')::uuid
          AND EXISTS (SELECT 1 FROM auth.member m WHERE m.organization_id = w.organization_id AND m.user_id = w.personal_user_id)))
        AND p.workspace_id = target_workspace_id AND p.role IN ('admin') AND (
          (p.principal_type = 'user' AND p.principal_id = nullif(current_setting('app.user_id', true), '')::uuid)
          OR (p.principal_type = 'organization' AND EXISTS (SELECT 1 FROM auth.member m WHERE m.organization_id = p.principal_id AND m.user_id = nullif(current_setting('app.user_id', true), '')::uuid))
          OR (p.principal_type = 'team' AND EXISTS (SELECT 1 FROM auth.team_member tm JOIN auth.team t ON t.id = tm.team_id JOIN auth.member m ON m.organization_id = t.organization_id AND m.user_id = tm.user_id
            WHERE tm.team_id = p.principal_id AND tm.user_id = nullif(current_setting('app.user_id', true), '')::uuid)))); $$;
--> statement-breakpoint
CREATE UNIQUE INDEX "member_user_organization_idx" ON "auth"."member" ("user_id","organization_id");--> statement-breakpoint
CREATE UNIQUE INDEX "team_member_user_team_idx" ON "auth"."team_member" ("user_id","team_id");--> statement-breakpoint
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
        'app.meeting_attachments'::regclass, 'search.documents'::regclass, 'app.documents'::regclass,
        'app.document_updates'::regclass, 'app.document_recoveries'::regclass, 'app.document_presence'::regclass)
  LOOP
    EXECUTE format('ALTER TABLE %s ALTER CONSTRAINT %I DEFERRABLE INITIALLY IMMEDIATE', membership.relation, membership.conname);
  END LOOP;
END $$;--> statement-breakpoint
ALTER TABLE "crypto"."workspace_keys" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."shared_memories" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."personal_memories" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "search"."knowledge_pages" FORCE ROW LEVEL SECURITY;--> statement-breakpoint

ALTER TABLE "app"."documents" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."document_updates" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."document_recoveries" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."document_presence" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
--> statement-breakpoint
-- Atomic dispatch registration from domain state; no content is copied into the queue.
CREATE FUNCTION jobs.dispatch_summary() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM jobs.queue WHERE id = 'summary:' || (OLD.id) AND status <> 'processing';
    RETURN OLD;
  END IF;
  IF NEW.status = 'pending' THEN
    INSERT INTO jobs.queue (id, kind, owner, target, reference, available_at, created_at)
    VALUES ('summary:' || (NEW.id), CASE WHEN NEW.method = 'audio' THEN 'audio-summary' ELSE 'summary' END, NEW.owner_user_id, 'meeting:' || NEW.meeting_id, jsonb_build_object('id', NEW.id, 'ownerUserId', NEW.owner_user_id), NEW.available_at, now())
    ON CONFLICT (id) DO UPDATE SET kind = EXCLUDED.kind, owner = EXCLUDED.owner, target = EXCLUDED.target,
      reference = EXCLUDED.reference, available_at = EXCLUDED.available_at, generation = jobs.queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs.queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
  ELSIF NEW.status IN ('failed','cancelled','succeeded') THEN
    DELETE FROM jobs.queue WHERE id = 'summary:' || (NEW.id) AND status <> 'processing';
  END IF;
  RETURN NEW;
END $$;
--> statement-breakpoint
CREATE TRIGGER dispatch_summary AFTER INSERT OR UPDATE OR DELETE ON jobs.summary
FOR EACH ROW EXECUTE FUNCTION jobs.dispatch_summary();
--> statement-breakpoint
CREATE FUNCTION jobs.dispatch_image() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM jobs.queue WHERE id = 'image:' || (OLD.file_id) AND status <> 'processing';
    RETURN OLD;
  END IF;
  IF NEW.status = 'pending' THEN
    INSERT INTO jobs.queue (id, kind, owner, target, reference, available_at, created_at)
    VALUES ('image:' || (NEW.file_id), 'image', NEW.owner_user_id, 'file:' || NEW.file_id, jsonb_build_object('fileId', NEW.file_id, 'ownerUserId', NEW.owner_user_id, 'model', NEW.model), NEW.available_at, now())
    ON CONFLICT (id) DO UPDATE SET kind = EXCLUDED.kind, owner = EXCLUDED.owner, target = EXCLUDED.target,
      reference = EXCLUDED.reference, available_at = EXCLUDED.available_at, generation = jobs.queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs.queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
  ELSIF NEW.status = 'failed' THEN
    DELETE FROM jobs.queue WHERE id = 'image:' || (NEW.file_id) AND status <> 'processing';
  END IF;
  RETURN NEW;
END $$;
--> statement-breakpoint
CREATE TRIGGER dispatch_image AFTER INSERT OR UPDATE OR DELETE ON jobs.image_analysis
FOR EACH ROW EXECUTE FUNCTION jobs.dispatch_image();
--> statement-breakpoint
CREATE FUNCTION jobs.dispatch_search() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM jobs.queue WHERE id = 'search:' || (OLD.workspace_id || ':' || OLD.document_id) AND status <> 'processing';
    RETURN OLD;
  END IF;
  IF NEW.status = 'pending' THEN
    INSERT INTO jobs.queue (id, kind, owner, target, reference, available_at, created_at)
    VALUES ('search:' || (NEW.workspace_id || ':' || NEW.document_id), 'search', NEW.workspace_id, 'document:' || NEW.workspace_id || ':' || NEW.document_id, jsonb_build_object('workspaceId', NEW.workspace_id, 'documentId', NEW.document_id, 'generation', NEW.generation), NEW.available_at, now())
    ON CONFLICT (id) DO UPDATE SET kind = EXCLUDED.kind, owner = EXCLUDED.owner, target = EXCLUDED.target,
      reference = EXCLUDED.reference, available_at = EXCLUDED.available_at, generation = jobs.queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs.queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
  ELSIF NEW.status = 'failed' THEN
    DELETE FROM jobs.queue WHERE id = 'search:' || (NEW.workspace_id || ':' || NEW.document_id) AND status <> 'processing';
  END IF;
  RETURN NEW;
END $$;
--> statement-breakpoint
CREATE TRIGGER dispatch_search AFTER INSERT OR UPDATE OR DELETE ON jobs.search_index
FOR EACH ROW EXECUTE FUNCTION jobs.dispatch_search();
--> statement-breakpoint
CREATE FUNCTION jobs.dispatch_storage_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM jobs.queue WHERE id = 'storage-delete:' || (OLD.storage_key) AND status <> 'processing';
    RETURN OLD;
  END IF;
  IF NEW.status IN ('pending','failed') THEN
    INSERT INTO jobs.queue (id, kind, owner, target, reference, available_at, created_at)
    VALUES ('storage-delete:' || (NEW.storage_key), 'storage-delete', '', 'storage:' || NEW.storage_key, jsonb_build_object('storageKey', NEW.storage_key), NEW.available_at, now())
    ON CONFLICT (id) DO UPDATE SET kind = EXCLUDED.kind, owner = EXCLUDED.owner, target = EXCLUDED.target,
      reference = EXCLUDED.reference, available_at = EXCLUDED.available_at, generation = jobs.queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs.queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
  END IF;
  RETURN NEW;
END $$;
--> statement-breakpoint
CREATE TRIGGER dispatch_storage_delete AFTER INSERT OR UPDATE OR DELETE ON jobs.storage_delete
FOR EACH ROW EXECUTE FUNCTION jobs.dispatch_storage_delete();
--> statement-breakpoint
CREATE FUNCTION jobs.dispatch_workspace_memory() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM jobs.queue WHERE id = 'workspace-memory:' || (OLD.workspace_id) AND status <> 'processing';
    RETURN OLD;
  END IF;
  IF (NEW.enabled OR NEW.purge) THEN
    INSERT INTO jobs.queue (id, kind, owner, target, reference, available_at, created_at)
    VALUES ('workspace-memory:' || (NEW.workspace_id), 'workspace-memory', NEW.requested_by, 'memory:' || NEW.workspace_id, jsonb_build_object('scopeId', NEW.workspace_id), NEW.available_at, now())
    ON CONFLICT (id) DO UPDATE SET kind = EXCLUDED.kind, owner = EXCLUDED.owner, target = EXCLUDED.target,
      reference = EXCLUDED.reference, available_at = EXCLUDED.available_at, generation = jobs.queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs.queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
  ELSIF NOT NEW.enabled AND NOT NEW.purge THEN
    DELETE FROM jobs.queue WHERE id = 'workspace-memory:' || (NEW.workspace_id) AND status <> 'processing';
  END IF;
  RETURN NEW;
END $$;
--> statement-breakpoint
CREATE TRIGGER dispatch_workspace_memory AFTER INSERT OR UPDATE OF available_at, generation, enabled, purge OR DELETE ON jobs.workspace_memory_state
FOR EACH ROW EXECUTE FUNCTION jobs.dispatch_workspace_memory();
--> statement-breakpoint
CREATE FUNCTION jobs.dispatch_personal_memory() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM jobs.queue WHERE id = 'personal-memory:' || (OLD.user_id) AND status <> 'processing';
    RETURN OLD;
  END IF;
  IF (NEW.enabled OR NEW.purge) THEN
    INSERT INTO jobs.queue (id, kind, owner, target, reference, available_at, created_at)
    VALUES ('personal-memory:' || (NEW.user_id), 'personal-memory', NEW.requested_by, 'personal-memory:' || NEW.user_id, jsonb_build_object('scopeId', NEW.user_id), NEW.available_at, now())
    ON CONFLICT (id) DO UPDATE SET kind = EXCLUDED.kind, owner = EXCLUDED.owner, target = EXCLUDED.target,
      reference = EXCLUDED.reference, available_at = EXCLUDED.available_at, generation = jobs.queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs.queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
  ELSIF NOT NEW.enabled AND NOT NEW.purge THEN
    DELETE FROM jobs.queue WHERE id = 'personal-memory:' || (NEW.user_id) AND status <> 'processing';
  END IF;
  RETURN NEW;
END $$;
--> statement-breakpoint
CREATE TRIGGER dispatch_personal_memory AFTER INSERT OR UPDATE OF available_at, generation, enabled, purge OR DELETE ON jobs.personal_memory_state
FOR EACH ROW EXECUTE FUNCTION jobs.dispatch_personal_memory();
--> statement-breakpoint
CREATE POLICY "document_read" ON "app"."documents" FOR SELECT USING ("app"."current_identity_can_read_workspace"("app"."documents"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "document_insert" ON "app"."documents" FOR INSERT WITH CHECK ("app"."current_identity_can_write_workspace"("app"."documents"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "document_update" ON "app"."documents" FOR UPDATE USING ("app"."current_identity_can_write_workspace"("app"."documents"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."documents"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "document_delete" ON "app"."documents" FOR DELETE USING ("app"."current_identity_can_write_workspace"("app"."documents"."workspace_id") OR (current_setting('app.maintenance', true) = 'governance-delete' AND "app"."documents"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR (current_setting('app.maintenance', true) = 'meeting-retention' AND "app"."documents"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "document_presence_read" ON "app"."document_presence" FOR SELECT USING ("app"."current_identity_can_read_workspace"("app"."document_presence"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "document_presence_insert" ON "app"."document_presence" FOR INSERT WITH CHECK ("app"."current_identity_can_write_workspace"("app"."document_presence"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "document_presence_update" ON "app"."document_presence" FOR UPDATE USING ("app"."current_identity_can_write_workspace"("app"."document_presence"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."document_presence"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "document_presence_delete" ON "app"."document_presence" FOR DELETE USING ("app"."current_identity_can_write_workspace"("app"."document_presence"."workspace_id") OR (current_setting('app.maintenance', true) = 'governance-delete' AND "app"."document_presence"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR (current_setting('app.maintenance', true) = 'meeting-retention' AND "app"."document_presence"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "document_recovery_read" ON "app"."document_recoveries" FOR SELECT USING ("app"."current_identity_can_read_workspace"("app"."document_recoveries"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "document_recovery_insert" ON "app"."document_recoveries" FOR INSERT WITH CHECK ("app"."current_identity_can_write_workspace"("app"."document_recoveries"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "document_recovery_update" ON "app"."document_recoveries" FOR UPDATE USING ("app"."current_identity_can_write_workspace"("app"."document_recoveries"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."document_recoveries"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "document_recovery_delete" ON "app"."document_recoveries" FOR DELETE USING ("app"."current_identity_can_write_workspace"("app"."document_recoveries"."workspace_id") OR (current_setting('app.maintenance', true) = 'governance-delete' AND "app"."document_recoveries"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR (current_setting('app.maintenance', true) = 'meeting-retention' AND "app"."document_recoveries"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "document_update_read" ON "app"."document_updates" FOR SELECT USING ("app"."current_identity_can_read_workspace"("app"."document_updates"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "document_update_insert" ON "app"."document_updates" FOR INSERT WITH CHECK ("app"."current_identity_can_write_workspace"("app"."document_updates"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "document_update_update" ON "app"."document_updates" FOR UPDATE USING ("app"."current_identity_can_write_workspace"("app"."document_updates"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."document_updates"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "document_update_delete" ON "app"."document_updates" FOR DELETE USING ("app"."current_identity_can_write_workspace"("app"."document_updates"."workspace_id") OR (current_setting('app.maintenance', true) = 'governance-delete' AND "app"."document_updates"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR (current_setting('app.maintenance', true) = 'meeting-retention' AND "app"."document_updates"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "knowledge_page_read" ON "search"."knowledge_pages" FOR SELECT USING ("app"."current_identity_can_read_workspace"("search"."knowledge_pages"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "knowledge_page_write" ON "search"."knowledge_pages" FOR ALL USING ("app"."current_identity_can_admin_workspace"("search"."knowledge_pages"."workspace_id")) WITH CHECK ("app"."current_identity_can_admin_workspace"("search"."knowledge_pages"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "meeting_attachment_select" ON "app"."meeting_attachments" FOR SELECT USING ((current_setting('app.maintenance', true) = 'meeting-retention' AND "app"."meeting_attachments"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR "app"."current_identity_can_read_workspace"("app"."meeting_attachments"."workspace_id") OR (current_setting('app.maintenance', true) = 'search' AND "app"."meeting_attachments"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.workspace_id = "app"."meeting_attachments"."workspace_id" AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "meeting_attachment_write" ON "app"."meeting_attachments" FOR ALL USING ("app"."current_identity_can_write_workspace"("app"."meeting_attachments"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."meeting_attachments"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "meeting_event_retention_update" ON "app"."meeting_events" FOR UPDATE USING (current_setting('app.maintenance', true) = 'meeting-retention' AND "app"."meeting_events"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) WITH CHECK (current_setting('app.maintenance', true) = 'meeting-retention' AND "app"."meeting_events"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid);
--> statement-breakpoint
CREATE POLICY "meeting_event_select" ON "app"."meeting_events" FOR SELECT USING ((current_setting('app.maintenance', true) = 'meeting-retention' AND "app"."meeting_events"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR "app"."current_identity_can_read_workspace"("app"."meeting_events"."workspace_id") OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.workspace_id = "app"."meeting_events"."workspace_id" AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "meeting_event_write" ON "app"."meeting_events" FOR ALL USING ("app"."current_identity_can_write_workspace"("app"."meeting_events"."workspace_id") OR current_setting('app.maintenance', true) = 'rotation') WITH CHECK ("app"."current_identity_can_write_workspace"("app"."meeting_events"."workspace_id") OR current_setting('app.maintenance', true) = 'rotation');
--> statement-breakpoint
CREATE POLICY "personal_memory_owner" ON "app"."personal_memories" FOR ALL USING ("app"."personal_memories"."user_id" = nullif(current_setting('app.user_id', true), '')::uuid) WITH CHECK ("app"."personal_memories"."user_id" = nullif(current_setting('app.user_id', true), '')::uuid);
--> statement-breakpoint
CREATE POLICY "search_document_select" ON "search"."documents" FOR SELECT USING ("app"."current_identity_can_read_workspace"("search"."documents"."workspace_id") OR (current_setting('app.maintenance', true) = 'search' AND "search"."documents"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "search_document_write" ON "search"."documents" FOR ALL USING ("app"."current_identity_can_write_workspace"("search"."documents"."workspace_id") OR (current_setting('app.maintenance', true) = 'search' AND "search"."documents"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid)) WITH CHECK ("app"."current_identity_can_write_workspace"("search"."documents"."workspace_id") OR (current_setting('app.maintenance', true) = 'search' AND "search"."documents"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "shared_memory_read" ON "app"."shared_memories" FOR SELECT USING ("app"."current_identity_can_read_workspace"("app"."shared_memories"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "shared_memory_write" ON "app"."shared_memories" FOR ALL USING ("app"."current_identity_can_write_workspace"("app"."shared_memories"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."shared_memories"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "summary_select" ON "app"."summaries" FOR SELECT USING (EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = "app"."summaries"."meeting_id" AND "app"."current_identity_can_read_workspace"(m.workspace_id)));
--> statement-breakpoint
CREATE POLICY "summary_write" ON "app"."summaries" FOR ALL USING (EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = "app"."summaries"."meeting_id" AND "app"."current_identity_can_write_workspace"(m.workspace_id))) WITH CHECK (EXISTS (SELECT 1 FROM "app"."meetings" m WHERE m.meeting_id = "app"."summaries"."meeting_id" AND "app"."current_identity_can_write_workspace"(m.workspace_id)));
--> statement-breakpoint
CREATE POLICY "summary_job_retention_select" ON "jobs"."summary" FOR SELECT USING (current_setting('app.maintenance', true) = 'meeting-retention' AND "jobs"."summary"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid);
--> statement-breakpoint
CREATE POLICY "summary_job_dispatch_select" ON "jobs"."summary" FOR SELECT USING (current_setting('app.maintenance', true) = 'summary-dispatch' AND "jobs"."summary"."status" IN ('pending', 'processing'));
--> statement-breakpoint
CREATE POLICY "summary_job_retention_update" ON "jobs"."summary" FOR UPDATE USING (current_setting('app.maintenance', true) = 'meeting-retention' AND "jobs"."summary"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) WITH CHECK (current_setting('app.maintenance', true) = 'meeting-retention' AND "jobs"."summary"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid);
--> statement-breakpoint
CREATE POLICY "summary_job_owner" ON "jobs"."summary" FOR ALL USING ("jobs"."summary"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid) WITH CHECK ("jobs"."summary"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid);
--> statement-breakpoint
CREATE POLICY "transaction_receipt_owner" ON "app"."transaction_receipts" FOR ALL USING ("app"."transaction_receipts"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid OR current_setting('app.maintenance', true) = 'retention') WITH CHECK ("app"."transaction_receipts"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid OR current_setting('app.maintenance', true) = 'retention');
--> statement-breakpoint
CREATE POLICY "file_select" ON "app"."files" FOR SELECT USING ((current_setting('app.maintenance', true) = 'meeting-retention' AND "app"."files"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR "app"."current_identity_can_read_workspace"("app"."files"."workspace_id") OR (current_setting('app.maintenance', true) = 'governance-delete' AND "app"."files"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.workspace_id = "app"."files"."workspace_id" AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "file_retention_delete" ON "app"."files" FOR DELETE USING (current_setting('app.maintenance', true) = 'meeting-retention' AND "app"."files"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid);
--> statement-breakpoint
CREATE POLICY "file_write" ON "app"."files" FOR ALL USING ("app"."current_identity_can_write_workspace"("app"."files"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."files"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "meeting_select" ON "app"."meetings" FOR SELECT USING ((current_setting('app.maintenance', true) = 'meeting-retention' AND "app"."meetings"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR "app"."current_identity_can_read_workspace"("app"."meetings"."workspace_id") OR (current_setting('app.maintenance', true) IN ('search', 'storage', 'governance-delete') AND "app"."meetings"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "meeting_retention_delete" ON "app"."meetings" FOR DELETE USING ((current_setting('app.maintenance', true) = 'meeting-retention' AND "app"."meetings"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) AND "app"."meetings"."deleted_at" IS NOT NULL);
--> statement-breakpoint
CREATE POLICY "meeting_write" ON "app"."meetings" FOR ALL USING ("app"."current_identity_can_write_workspace"("app"."meetings"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."meetings"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "project_select" ON "app"."projects" FOR SELECT USING ("app"."current_identity_can_read_workspace"("app"."projects"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "project_insert" ON "app"."projects" FOR INSERT WITH CHECK ("app"."current_identity_can_write_workspace"("app"."projects"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "project_update" ON "app"."projects" FOR UPDATE USING ("app"."current_identity_can_write_workspace"("app"."projects"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."projects"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "project_delete" ON "app"."projects" FOR DELETE USING ("app"."current_identity_can_write_workspace"("app"."projects"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "recording_select" ON "app"."recordings" FOR SELECT USING (EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = "app"."recordings"."meeting_id" AND ("app"."current_identity_can_read_workspace"("workspace_id") OR (current_setting('app.maintenance', true) IN ('storage', 'governance-delete', 'meeting-retention') AND "workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid))));
--> statement-breakpoint
CREATE POLICY "recording_write" ON "app"."recordings" FOR ALL USING (EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = "app"."recordings"."meeting_id" AND ("app"."current_identity_can_write_workspace"("workspace_id") OR (current_setting('app.maintenance', true) IN ('storage', 'governance-delete') AND "workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid)))) WITH CHECK (EXISTS (SELECT 1 FROM "app"."meetings" WHERE "meeting_id" = "app"."recordings"."meeting_id" AND ("app"."current_identity_can_write_workspace"("workspace_id") OR (current_setting('app.maintenance', true) IN ('storage', 'governance-delete') AND "workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid))));
--> statement-breakpoint
CREATE POLICY "transcript_select" ON "app"."transcript_segments" FOR SELECT USING (exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_can_read_workspace"(m.workspace_id)));
--> statement-breakpoint
CREATE POLICY "transcript_write" ON "app"."transcript_segments" FOR ALL USING (exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_can_write_workspace"(m.workspace_id))) WITH CHECK (exists (select 1 from "app"."transcripts" t join "app"."meetings" m on m.meeting_id = t.meeting_id where t.id = "app"."transcript_segments"."transcript_id" and "app"."current_identity_can_write_workspace"(m.workspace_id)));
--> statement-breakpoint
CREATE POLICY "workspace_select" ON "app"."workspaces" FOR SELECT USING ((current_setting('app.maintenance', true) = 'meeting-retention' AND "app"."workspaces"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR (
  ("app"."workspaces"."personal_user_id" IS NULL OR ("app"."workspaces"."personal_user_id" = nullif(current_setting('app.user_id', true), '')::uuid
    AND EXISTS (SELECT 1 FROM auth.member m WHERE m.organization_id = "app"."workspaces"."organization_id" AND m.user_id = "app"."workspaces"."personal_user_id")))
  AND EXISTS (SELECT 1 FROM app.workspace_permissions p WHERE p.workspace_id = "app"."workspaces"."workspace_id" AND p.role IN ('admin', 'editor', 'viewer') AND (
    (p.principal_type = 'user' AND p.principal_id = nullif(current_setting('app.user_id', true), '')::uuid)
    OR (p.principal_type = 'organization' AND EXISTS (SELECT 1 FROM auth.member m WHERE m.organization_id = p.principal_id AND m.user_id = nullif(current_setting('app.user_id', true), '')::uuid))
    OR (p.principal_type = 'team' AND EXISTS (SELECT 1 FROM auth.team_member tm JOIN auth.team t ON t.id = tm.team_id JOIN auth.member m ON m.organization_id = t.organization_id AND m.user_id = tm.user_id
      WHERE tm.team_id = p.principal_id AND tm.user_id = nullif(current_setting('app.user_id', true), '')::uuid))))) OR (current_setting('app.maintenance', true) = 'search' AND "app"."workspaces"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR current_setting('app.maintenance', true) = 'authorization' OR (current_setting('app.maintenance', true) = 'governance' AND "app"."workspaces"."organization_id" = nullif(current_setting('app.maintenance_organization_id', true), '')::uuid) OR (current_setting('app.maintenance', true) = 'governance-delete' AND "app"."workspaces"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "workspace_insert" ON "app"."workspaces" FOR INSERT WITH CHECK (coalesce(current_setting('app.user_id', true), '') <> '' OR current_setting('app.maintenance', true) = 'authorization');
--> statement-breakpoint
CREATE POLICY "workspace_update" ON "app"."workspaces" FOR UPDATE USING ("app"."current_identity_can_admin_workspace"("app"."workspaces"."workspace_id")) WITH CHECK ("app"."current_identity_can_admin_workspace"("app"."workspaces"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "workspace_delete" ON "app"."workspaces" FOR DELETE USING ("app"."current_identity_can_admin_workspace"("app"."workspaces"."workspace_id") OR (current_setting('app.maintenance', true) = 'governance-delete' AND "app"."workspaces"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "transcript_version_select" ON "app"."transcripts" FOR SELECT USING (exists (select 1 from "app"."meetings" m where m.meeting_id = "app"."transcripts"."meeting_id" and "app"."current_identity_can_read_workspace"(m.workspace_id)));
--> statement-breakpoint
CREATE POLICY "transcript_version_write" ON "app"."transcripts" FOR ALL USING (exists (select 1 from "app"."meetings" m where m.meeting_id = "app"."transcripts"."meeting_id" and "app"."current_identity_can_write_workspace"(m.workspace_id))) WITH CHECK (exists (select 1 from "app"."meetings" m where m.meeting_id = "app"."transcripts"."meeting_id" and "app"."current_identity_can_write_workspace"(m.workspace_id)));
--> statement-breakpoint
CREATE POLICY "transcript_patch_select" ON "app"."transcript_patch_chunks" FOR SELECT USING ("app"."current_identity_can_write_workspace"("app"."transcript_patch_chunks"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "transcript_patch_write" ON "app"."transcript_patch_chunks" FOR ALL USING ("app"."current_identity_can_write_workspace"("app"."transcript_patch_chunks"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."transcript_patch_chunks"."workspace_id"));
--> statement-breakpoint
CREATE POLICY "workspace_key_read" ON "crypto"."workspace_keys" FOR SELECT USING ("app"."current_identity_can_read_workspace"("crypto"."workspace_keys"."workspace_id") OR (current_setting('app.maintenance', true) = 'governance-delete' AND "crypto"."workspace_keys"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid) OR (current_setting('app.maintenance', true) = 'governance' AND EXISTS (SELECT 1 FROM app.workspaces v WHERE v.workspace_id = "crypto"."workspace_keys"."workspace_id" AND v.organization_id = nullif(current_setting('app.maintenance_organization_id', true), '')::uuid)) OR current_setting('app.maintenance', true) IN ('retention', 'rotation') OR EXISTS (SELECT 1 FROM "app"."transaction_receipts" r WHERE r.workspace_id = "crypto"."workspace_keys"."workspace_id" AND r.owner_user_id = nullif(current_setting('app.user_id', true), '')::uuid));
--> statement-breakpoint
CREATE POLICY "workspace_key_write" ON "crypto"."workspace_keys" FOR ALL USING ("app"."current_identity_can_write_workspace"("crypto"."workspace_keys"."workspace_id") OR current_setting('app.maintenance', true) = 'rotation') WITH CHECK ("app"."current_identity_can_write_workspace"("crypto"."workspace_keys"."workspace_id") OR current_setting('app.maintenance', true) = 'rotation');
--> statement-breakpoint
CREATE POLICY "workspace_transfer_reader" ON "app"."workspace_transfers" FOR SELECT USING ("app"."current_identity_can_read_workspace"("app"."workspace_transfers"."source_workspace_id") OR "app"."current_identity_can_read_workspace"("app"."workspace_transfers"."destination_workspace_id"));
--> statement-breakpoint
CREATE POLICY "workspace_transfer_owner" ON "app"."workspace_transfers" FOR ALL USING ("app"."workspace_transfers"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid) WITH CHECK ("app"."workspace_transfers"."owner_user_id" = nullif(current_setting('app.user_id', true), '')::uuid);
