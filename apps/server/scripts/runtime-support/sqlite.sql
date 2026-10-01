CREATE UNIQUE INDEX `member_user_organization_idx` ON `member` (`user_id`,`organization_id`);
--> statement-breakpoint
CREATE UNIQUE INDEX `team_member_user_team_idx` ON `team_member` (`user_id`,`team_id`);
--> statement-breakpoint
CREATE VIRTUAL TABLE `search_documents_fts` USING fts5(
  `title_text`, `tags_text`, `description_text`, `summary_text`, `ocr_text`, `caption_text`,
  content=`search_documents`, content_rowid=`rowid`, tokenize='unicode61'
);
--> statement-breakpoint
CREATE TRIGGER `search_documents_fts_insert` AFTER INSERT ON `search_documents` BEGIN
  INSERT INTO `search_documents_fts` (`rowid`, `title_text`, `tags_text`, `description_text`, `summary_text`, `ocr_text`, `caption_text`)
  VALUES (new.`rowid`, new.`title_text`, new.`tags_text`, new.`description_text`, new.`summary_text`, new.`ocr_text`, new.`caption_text`);
END;
--> statement-breakpoint
CREATE TRIGGER `search_documents_fts_delete` AFTER DELETE ON `search_documents` BEGIN
  INSERT INTO `search_documents_fts` (`search_documents_fts`, `rowid`, `title_text`, `tags_text`, `description_text`, `summary_text`, `ocr_text`, `caption_text`)
  VALUES ('delete', old.`rowid`, old.`title_text`, old.`tags_text`, old.`description_text`, old.`summary_text`, old.`ocr_text`, old.`caption_text`);
END;
--> statement-breakpoint
CREATE TRIGGER `search_documents_fts_update` AFTER UPDATE OF `title_text`, `tags_text`, `description_text`, `summary_text`, `ocr_text`, `caption_text` ON `search_documents` BEGIN
  INSERT INTO `search_documents_fts` (`search_documents_fts`, `rowid`, `title_text`, `tags_text`, `description_text`, `summary_text`, `ocr_text`, `caption_text`)
  VALUES ('delete', old.`rowid`, old.`title_text`, old.`tags_text`, old.`description_text`, old.`summary_text`, old.`ocr_text`, old.`caption_text`);
  INSERT INTO `search_documents_fts` (`rowid`, `title_text`, `tags_text`, `description_text`, `summary_text`, `ocr_text`, `caption_text`)
  VALUES (new.`rowid`, new.`title_text`, new.`tags_text`, new.`description_text`, new.`summary_text`, new.`ocr_text`, new.`caption_text`);
END;
--> statement-breakpoint
-- Atomic dispatch registration from domain state; no content is copied into the queue.
CREATE TRIGGER dispatch_summary_insert AFTER INSERT ON jobs_summary BEGIN
INSERT INTO jobs_queue (id, kind, owner, target, reference, available_at, created_at)
    SELECT 'summary:' || (NEW.id), CASE WHEN NEW.method = 'audio' THEN 'audio-summary' ELSE 'summary' END, NEW.owner_user_id, 'meeting:' || NEW.meeting_id, json_object('id', NEW.id, 'ownerUserId', NEW.owner_user_id), NEW.available_at, CAST(unixepoch('subsec') * 1000 AS INTEGER)
    WHERE NEW.status = 'pending'
    ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, owner = excluded.owner, target = excluded.target,
      reference = excluded.reference, available_at = excluded.available_at, generation = jobs_queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs_queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
    DELETE FROM jobs_queue WHERE id = 'summary:' || (NEW.id) AND status <> 'processing' AND (NEW.status IN ('failed','cancelled','succeeded'));
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_summary_update AFTER UPDATE ON jobs_summary BEGIN
INSERT INTO jobs_queue (id, kind, owner, target, reference, available_at, created_at)
    SELECT 'summary:' || (NEW.id), CASE WHEN NEW.method = 'audio' THEN 'audio-summary' ELSE 'summary' END, NEW.owner_user_id, 'meeting:' || NEW.meeting_id, json_object('id', NEW.id, 'ownerUserId', NEW.owner_user_id), NEW.available_at, CAST(unixepoch('subsec') * 1000 AS INTEGER)
    WHERE NEW.status = 'pending'
    ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, owner = excluded.owner, target = excluded.target,
      reference = excluded.reference, available_at = excluded.available_at, generation = jobs_queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs_queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
    DELETE FROM jobs_queue WHERE id = 'summary:' || (NEW.id) AND status <> 'processing' AND (NEW.status IN ('failed','cancelled','succeeded'));
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_summary_delete AFTER DELETE ON jobs_summary BEGIN
DELETE FROM jobs_queue WHERE id = 'summary:' || (OLD.id) AND status <> 'processing';
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_image_insert AFTER INSERT ON jobs_image_analysis BEGIN
INSERT INTO jobs_queue (id, kind, owner, target, reference, available_at, created_at)
    SELECT 'image:' || (NEW.file_id), 'image', NEW.owner_user_id, 'file:' || NEW.file_id, json_object('fileId', NEW.file_id, 'ownerUserId', NEW.owner_user_id, 'model', NEW.model), NEW.available_at, CAST(unixepoch('subsec') * 1000 AS INTEGER)
    WHERE NEW.status = 'pending'
    ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, owner = excluded.owner, target = excluded.target,
      reference = excluded.reference, available_at = excluded.available_at, generation = jobs_queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs_queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
    DELETE FROM jobs_queue WHERE id = 'image:' || (NEW.file_id) AND status <> 'processing' AND (NEW.status = 'failed');
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_image_update AFTER UPDATE ON jobs_image_analysis BEGIN
INSERT INTO jobs_queue (id, kind, owner, target, reference, available_at, created_at)
    SELECT 'image:' || (NEW.file_id), 'image', NEW.owner_user_id, 'file:' || NEW.file_id, json_object('fileId', NEW.file_id, 'ownerUserId', NEW.owner_user_id, 'model', NEW.model), NEW.available_at, CAST(unixepoch('subsec') * 1000 AS INTEGER)
    WHERE NEW.status = 'pending'
    ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, owner = excluded.owner, target = excluded.target,
      reference = excluded.reference, available_at = excluded.available_at, generation = jobs_queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs_queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
    DELETE FROM jobs_queue WHERE id = 'image:' || (NEW.file_id) AND status <> 'processing' AND (NEW.status = 'failed');
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_image_delete AFTER DELETE ON jobs_image_analysis BEGIN
DELETE FROM jobs_queue WHERE id = 'image:' || (OLD.file_id) AND status <> 'processing';
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_search_insert AFTER INSERT ON jobs_search_index BEGIN
INSERT INTO jobs_queue (id, kind, owner, target, reference, available_at, created_at)
    SELECT 'search:' || (NEW.workspace_id || ':' || NEW.document_id), 'search', NEW.workspace_id, 'document:' || NEW.workspace_id || ':' || NEW.document_id, json_object('workspaceId', NEW.workspace_id, 'documentId', NEW.document_id, 'generation', NEW.generation), NEW.available_at, CAST(unixepoch('subsec') * 1000 AS INTEGER)
    WHERE NEW.status = 'pending'
    ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, owner = excluded.owner, target = excluded.target,
      reference = excluded.reference, available_at = excluded.available_at, generation = jobs_queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs_queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
    DELETE FROM jobs_queue WHERE id = 'search:' || (NEW.workspace_id || ':' || NEW.document_id) AND status <> 'processing' AND (NEW.status = 'failed');
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_search_update AFTER UPDATE ON jobs_search_index BEGIN
INSERT INTO jobs_queue (id, kind, owner, target, reference, available_at, created_at)
    SELECT 'search:' || (NEW.workspace_id || ':' || NEW.document_id), 'search', NEW.workspace_id, 'document:' || NEW.workspace_id || ':' || NEW.document_id, json_object('workspaceId', NEW.workspace_id, 'documentId', NEW.document_id, 'generation', NEW.generation), NEW.available_at, CAST(unixepoch('subsec') * 1000 AS INTEGER)
    WHERE NEW.status = 'pending'
    ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, owner = excluded.owner, target = excluded.target,
      reference = excluded.reference, available_at = excluded.available_at, generation = jobs_queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs_queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
    DELETE FROM jobs_queue WHERE id = 'search:' || (NEW.workspace_id || ':' || NEW.document_id) AND status <> 'processing' AND (NEW.status = 'failed');
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_search_delete AFTER DELETE ON jobs_search_index BEGIN
DELETE FROM jobs_queue WHERE id = 'search:' || (OLD.workspace_id || ':' || OLD.document_id) AND status <> 'processing';
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_storage_delete_insert AFTER INSERT ON jobs_storage_delete BEGIN
INSERT INTO jobs_queue (id, kind, owner, target, reference, available_at, created_at)
    SELECT 'storage-delete:' || (NEW.storage_key), 'storage-delete', '', 'storage:' || NEW.storage_key, json_object('storageKey', NEW.storage_key), NEW.available_at, CAST(unixepoch('subsec') * 1000 AS INTEGER)
    WHERE NEW.status IN ('pending','failed')
    ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, owner = excluded.owner, target = excluded.target,
      reference = excluded.reference, available_at = excluded.available_at, generation = jobs_queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs_queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
    DELETE FROM jobs_queue WHERE id = 'storage-delete:' || (NEW.storage_key) AND status <> 'processing' AND (FALSE);
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_storage_delete_update AFTER UPDATE ON jobs_storage_delete BEGIN
INSERT INTO jobs_queue (id, kind, owner, target, reference, available_at, created_at)
    SELECT 'storage-delete:' || (NEW.storage_key), 'storage-delete', '', 'storage:' || NEW.storage_key, json_object('storageKey', NEW.storage_key), NEW.available_at, CAST(unixepoch('subsec') * 1000 AS INTEGER)
    WHERE NEW.status IN ('pending','failed')
    ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, owner = excluded.owner, target = excluded.target,
      reference = excluded.reference, available_at = excluded.available_at, generation = jobs_queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs_queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
    DELETE FROM jobs_queue WHERE id = 'storage-delete:' || (NEW.storage_key) AND status <> 'processing' AND (FALSE);
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_storage_delete_delete AFTER DELETE ON jobs_storage_delete BEGIN
DELETE FROM jobs_queue WHERE id = 'storage-delete:' || (OLD.storage_key) AND status <> 'processing';
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_workspace_memory_insert AFTER INSERT ON workspace_memory_state BEGIN
INSERT INTO jobs_queue (id, kind, owner, target, reference, available_at, created_at)
    SELECT 'workspace-memory:' || (NEW.workspace_id), 'workspace-memory', NEW.requested_by, 'memory:' || NEW.workspace_id, json_object('scopeId', NEW.workspace_id), NEW.available_at, CAST(unixepoch('subsec') * 1000 AS INTEGER)
    WHERE (NEW.enabled OR NEW.purge)
    ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, owner = excluded.owner, target = excluded.target,
      reference = excluded.reference, available_at = excluded.available_at, generation = jobs_queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs_queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
    DELETE FROM jobs_queue WHERE id = 'workspace-memory:' || (NEW.workspace_id) AND status <> 'processing' AND (NOT NEW.enabled AND NOT NEW.purge);
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_workspace_memory_update AFTER UPDATE OF available_at, generation, enabled, purge ON workspace_memory_state BEGIN
INSERT INTO jobs_queue (id, kind, owner, target, reference, available_at, created_at)
    SELECT 'workspace-memory:' || (NEW.workspace_id), 'workspace-memory', NEW.requested_by, 'memory:' || NEW.workspace_id, json_object('scopeId', NEW.workspace_id), NEW.available_at, CAST(unixepoch('subsec') * 1000 AS INTEGER)
    WHERE (NEW.enabled OR NEW.purge)
    ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, owner = excluded.owner, target = excluded.target,
      reference = excluded.reference, available_at = excluded.available_at, generation = jobs_queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs_queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
    DELETE FROM jobs_queue WHERE id = 'workspace-memory:' || (NEW.workspace_id) AND status <> 'processing' AND (NOT NEW.enabled AND NOT NEW.purge);
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_workspace_memory_delete AFTER DELETE ON workspace_memory_state BEGIN
DELETE FROM jobs_queue WHERE id = 'workspace-memory:' || (OLD.workspace_id) AND status <> 'processing';
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_personal_memory_insert AFTER INSERT ON personal_memory_state BEGIN
INSERT INTO jobs_queue (id, kind, owner, target, reference, available_at, created_at)
    SELECT 'personal-memory:' || (NEW.user_id), 'personal-memory', NEW.requested_by, 'personal-memory:' || NEW.user_id, json_object('scopeId', NEW.user_id), NEW.available_at, CAST(unixepoch('subsec') * 1000 AS INTEGER)
    WHERE (NEW.enabled OR NEW.purge)
    ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, owner = excluded.owner, target = excluded.target,
      reference = excluded.reference, available_at = excluded.available_at, generation = jobs_queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs_queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
    DELETE FROM jobs_queue WHERE id = 'personal-memory:' || (NEW.user_id) AND status <> 'processing' AND (NOT NEW.enabled AND NOT NEW.purge);
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_personal_memory_update AFTER UPDATE OF available_at, generation, enabled, purge ON personal_memory_state BEGIN
INSERT INTO jobs_queue (id, kind, owner, target, reference, available_at, created_at)
    SELECT 'personal-memory:' || (NEW.user_id), 'personal-memory', NEW.requested_by, 'personal-memory:' || NEW.user_id, json_object('scopeId', NEW.user_id), NEW.available_at, CAST(unixepoch('subsec') * 1000 AS INTEGER)
    WHERE (NEW.enabled OR NEW.purge)
    ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, owner = excluded.owner, target = excluded.target,
      reference = excluded.reference, available_at = excluded.available_at, generation = jobs_queue.generation + 1, attempts = 0, last_error = NULL,
      status = CASE WHEN jobs_queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
    DELETE FROM jobs_queue WHERE id = 'personal-memory:' || (NEW.user_id) AND status <> 'processing' AND (NOT NEW.enabled AND NOT NEW.purge);
END;
--> statement-breakpoint
CREATE TRIGGER dispatch_personal_memory_delete AFTER DELETE ON personal_memory_state BEGIN
DELETE FROM jobs_queue WHERE id = 'personal-memory:' || (OLD.user_id) AND status <> 'processing';
END;
