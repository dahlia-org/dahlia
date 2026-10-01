ALTER TABLE "agent"."mastra_threads" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "agent"."mastra_messages" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "agent"."mastra_resources" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "agent"."ai_thread_runs" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE agent.mastra_observational_memory FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE agent.memory_jobs FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE agent.live_contexts FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
CREATE FUNCTION jobs.dispatch_chat_memory() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM jobs.queue WHERE id = 'chat-memory:' || (OLD.id) AND status <> 'processing';
    RETURN OLD;
  END IF;
  INSERT INTO jobs.queue (id, kind, owner, target, reference, available_at, created_at)
  VALUES ('chat-memory:' || (NEW.id), 'chat-memory', NEW.user_id, 'chat:' || NEW.thread_id, jsonb_build_object('id', NEW.id, 'ownerUserId', NEW.user_id), NEW.available_at, now())
  ON CONFLICT (id) DO UPDATE SET kind = EXCLUDED.kind, owner = EXCLUDED.owner, target = EXCLUDED.target,
    reference = EXCLUDED.reference, available_at = EXCLUDED.available_at, generation = jobs.queue.generation + 1, attempts = 0, last_error = NULL,
    status = CASE WHEN jobs.queue.status = 'processing' THEN 'processing' ELSE 'pending' END;
  RETURN NEW;
END $$;
--> statement-breakpoint
CREATE TRIGGER dispatch_chat_memory AFTER INSERT OR UPDATE OF available_at, revision OR DELETE ON agent.memory_jobs
FOR EACH ROW EXECUTE FUNCTION jobs.dispatch_chat_memory();
