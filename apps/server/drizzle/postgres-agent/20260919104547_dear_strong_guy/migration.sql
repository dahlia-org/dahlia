CREATE SCHEMA "agent";
--> statement-breakpoint
CREATE TABLE "agent"."live_contexts" (
	"meeting_id" uuid PRIMARY KEY,
	"snapshot" jsonb,
	"lease" text,
	"lease_until" timestamp with time zone
);
--> statement-breakpoint
ALTER TABLE "agent"."live_contexts" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "agent"."memory_jobs" (
	"id" text PRIMARY KEY,
	"user_id" text NOT NULL,
	"thread_id" text NOT NULL,
	"kind" text NOT NULL,
	"message_id" text,
	"revision" integer NOT NULL,
	"available_at" timestamp with time zone DEFAULT now() NOT NULL,
	"lease" text,
	"lease_until" timestamp with time zone,
	"attempts" integer DEFAULT 0 NOT NULL
);
--> statement-breakpoint
ALTER TABLE "agent"."memory_jobs" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "agent"."mastra_messages" (
	"id" text PRIMARY KEY,
	"thread_id" text NOT NULL,
	"content" text NOT NULL,
	"role" text NOT NULL,
	"type" text NOT NULL,
	"createdAt" timestamp NOT NULL,
	"createdAtZ" timestamp with time zone DEFAULT now(),
	"resourceId" text
);
--> statement-breakpoint
ALTER TABLE "agent"."mastra_messages" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "agent"."mastra_observational_memory" (
	"id" text PRIMARY KEY,
	"lookupKey" text NOT NULL,
	"scope" text NOT NULL,
	"resourceId" text,
	"threadId" text,
	"activeObservations" text NOT NULL,
	"activeObservationsPendingUpdate" text,
	"originType" text NOT NULL,
	"config" text NOT NULL,
	"generationCount" integer NOT NULL,
	"lastObservedAt" timestamp,
	"lastObservedAtZ" timestamp with time zone,
	"lastReflectionAt" timestamp,
	"lastReflectionAtZ" timestamp with time zone,
	"pendingMessageTokens" integer NOT NULL,
	"totalTokensObserved" integer NOT NULL,
	"observationTokenCount" integer NOT NULL,
	"isObserving" boolean NOT NULL,
	"isReflecting" boolean NOT NULL,
	"observedMessageIds" jsonb,
	"observedTimezone" text,
	"bufferedObservations" text,
	"bufferedObservationTokens" integer,
	"bufferedMessageIds" jsonb,
	"bufferedReflection" text,
	"bufferedReflectionTokens" integer,
	"bufferedReflectionInputTokens" integer,
	"reflectedObservationLineCount" integer,
	"bufferedObservationChunks" jsonb,
	"isBufferingObservation" boolean NOT NULL,
	"isBufferingReflection" boolean NOT NULL,
	"lastBufferedAtTokens" integer NOT NULL,
	"lastBufferedAtTime" timestamp,
	"lastBufferedAtTimeZ" timestamp with time zone,
	"metadata" jsonb,
	"createdAt" timestamp NOT NULL,
	"createdAtZ" timestamp with time zone,
	"updatedAt" timestamp NOT NULL,
	"updatedAtZ" timestamp with time zone
);
--> statement-breakpoint
ALTER TABLE "agent"."mastra_observational_memory" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "agent"."mastra_resources" (
	"id" text PRIMARY KEY,
	"workingMemory" text,
	"metadata" jsonb,
	"createdAt" timestamp NOT NULL,
	"createdAtZ" timestamp with time zone DEFAULT now(),
	"updatedAt" timestamp NOT NULL,
	"updatedAtZ" timestamp with time zone DEFAULT now()
);
--> statement-breakpoint
ALTER TABLE "agent"."mastra_resources" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "agent"."mastra_threads" (
	"id" text PRIMARY KEY,
	"resourceId" text NOT NULL,
	"title" text NOT NULL,
	"metadata" jsonb,
	"createdAt" timestamp NOT NULL,
	"createdAtZ" timestamp with time zone DEFAULT now(),
	"updatedAt" timestamp NOT NULL,
	"updatedAtZ" timestamp with time zone DEFAULT now()
);
--> statement-breakpoint
ALTER TABLE "agent"."mastra_threads" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "agent"."ai_thread_runs" (
	"thread_id" text PRIMARY KEY,
	"run_id" text NOT NULL,
	"resource_id" text NOT NULL,
	"started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
ALTER TABLE "agent"."ai_thread_runs" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE INDEX "agent_memory_due_idx" ON "agent"."memory_jobs" ("available_at");--> statement-breakpoint
CREATE INDEX "agent_mastra_messages_thread_id_createdat_idx" ON "agent"."mastra_messages" ("thread_id","createdAt" DESC NULLS LAST);--> statement-breakpoint
CREATE INDEX "agent_om_lookup_idx" ON "agent"."mastra_observational_memory" ("lookupKey");--> statement-breakpoint
CREATE INDEX "agent_mastra_threads_resourceid_createdat_idx" ON "agent"."mastra_threads" ("resourceId","createdAt" DESC NULLS LAST);--> statement-breakpoint
ALTER TABLE "agent"."live_contexts" ADD CONSTRAINT "live_contexts_meeting_id_meetings_meeting_id_fkey" FOREIGN KEY ("meeting_id") REFERENCES "app"."meetings"("meeting_id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "agent"."memory_jobs" ADD CONSTRAINT "memory_jobs_thread_id_mastra_threads_id_fkey" FOREIGN KEY ("thread_id") REFERENCES "agent"."mastra_threads"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "agent"."mastra_observational_memory" ADD CONSTRAINT "mastra_observational_memory_threadId_mastra_threads_id_fkey" FOREIGN KEY ("threadId") REFERENCES "agent"."mastra_threads"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "agent"."ai_thread_runs" ADD CONSTRAINT "ai_thread_runs_thread_id_mastra_threads_id_fkey" FOREIGN KEY ("thread_id") REFERENCES "agent"."mastra_threads"("id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "agent_live_reader" ON "agent"."live_contexts" AS PERMISSIVE FOR ALL TO public USING (EXISTS (SELECT 1 FROM app.meetings m WHERE m.meeting_id = "agent"."live_contexts"."meeting_id" AND m.deleted_at IS NULL AND m.deleting_at IS NULL AND app.current_identity_can_read_workspace(m.workspace_id))) WITH CHECK (EXISTS (SELECT 1 FROM app.meetings m WHERE m.meeting_id = "agent"."live_contexts"."meeting_id" AND m.deleted_at IS NULL AND m.deleting_at IS NULL AND app.current_identity_can_read_workspace(m.workspace_id)));--> statement-breakpoint
CREATE POLICY "agent_memory_job_owner" ON "agent"."memory_jobs" AS PERMISSIVE FOR ALL TO public USING ("agent"."memory_jobs"."user_id" = nullif(current_setting('app.user_id', true), '') AND EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."memory_jobs"."thread_id" AND owner_thread."resourceId" = nullif(current_setting('app.user_id', true), '')
)) WITH CHECK ("agent"."memory_jobs"."user_id" = nullif(current_setting('app.user_id', true), '') AND EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."memory_jobs"."thread_id" AND owner_thread."resourceId" = nullif(current_setting('app.user_id', true), '')
));--> statement-breakpoint
CREATE POLICY "agent_memory_job_dispatch" ON "agent"."memory_jobs" AS PERMISSIVE FOR SELECT TO public USING (current_setting('app.maintenance', true) = 'agent-memory');--> statement-breakpoint
CREATE POLICY "agent_message_owner" ON "agent"."mastra_messages" AS PERMISSIVE FOR ALL TO public USING (EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."mastra_messages"."thread_id" AND owner_thread."resourceId" = nullif(current_setting('app.user_id', true), '')
) AND ("agent"."mastra_messages"."resourceId" IS NULL OR "agent"."mastra_messages"."resourceId" = nullif(current_setting('app.user_id', true), ''))) WITH CHECK (EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."mastra_messages"."thread_id" AND owner_thread."resourceId" = nullif(current_setting('app.user_id', true), '')
) AND ("agent"."mastra_messages"."resourceId" IS NULL OR "agent"."mastra_messages"."resourceId" = nullif(current_setting('app.user_id', true), '')));--> statement-breakpoint
CREATE POLICY "agent_observation_owner" ON "agent"."mastra_observational_memory" AS PERMISSIVE FOR ALL TO public USING ("agent"."mastra_observational_memory"."scope" = 'thread' AND "agent"."mastra_observational_memory"."resourceId" = nullif(current_setting('app.user_id', true), '') AND EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."mastra_observational_memory"."threadId" AND owner_thread."resourceId" = nullif(current_setting('app.user_id', true), '')
)) WITH CHECK ("agent"."mastra_observational_memory"."scope" = 'thread' AND "agent"."mastra_observational_memory"."resourceId" = nullif(current_setting('app.user_id', true), '') AND EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."mastra_observational_memory"."threadId" AND owner_thread."resourceId" = nullif(current_setting('app.user_id', true), '')
));--> statement-breakpoint
CREATE POLICY "agent_resource_owner" ON "agent"."mastra_resources" AS PERMISSIVE FOR ALL TO public USING ("agent"."mastra_resources"."id" = nullif(current_setting('app.user_id', true), '')) WITH CHECK ("agent"."mastra_resources"."id" = nullif(current_setting('app.user_id', true), ''));--> statement-breakpoint
CREATE POLICY "agent_thread_owner" ON "agent"."mastra_threads" AS PERMISSIVE FOR ALL TO public USING ("agent"."mastra_threads"."resourceId" = nullif(current_setting('app.user_id', true), '')) WITH CHECK ("agent"."mastra_threads"."resourceId" = nullif(current_setting('app.user_id', true), ''));--> statement-breakpoint
CREATE POLICY "ai_thread_run_owner" ON "agent"."ai_thread_runs" AS PERMISSIVE FOR ALL TO public USING ("agent"."ai_thread_runs"."resource_id" = nullif(current_setting('app.user_id', true), '') AND EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."ai_thread_runs"."thread_id" AND owner_thread."resourceId" = nullif(current_setting('app.user_id', true), '')
)) WITH CHECK ("agent"."ai_thread_runs"."resource_id" = nullif(current_setting('app.user_id', true), '') AND EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."ai_thread_runs"."thread_id" AND owner_thread."resourceId" = nullif(current_setting('app.user_id', true), '')
));