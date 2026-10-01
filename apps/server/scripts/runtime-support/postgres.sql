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
