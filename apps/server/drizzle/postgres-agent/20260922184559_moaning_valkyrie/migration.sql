CREATE TABLE "agent"."live_contexts" (
	"meeting_id" uuid PRIMARY KEY,
	"workspace_id" uuid NOT NULL,
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
CREATE INDEX "agent_memory_due_idx" ON "agent"."memory_jobs" ("available_at");--> statement-breakpoint
CREATE INDEX "agent_om_lookup_idx" ON "agent"."mastra_observational_memory" ("lookupKey");--> statement-breakpoint
ALTER TABLE "agent"."memory_jobs" ADD CONSTRAINT "memory_jobs_thread_id_mastra_threads_id_fkey" FOREIGN KEY ("thread_id") REFERENCES "agent"."mastra_threads"("id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "agent_live_reader" ON "agent"."live_contexts" AS PERMISSIVE FOR ALL TO public USING (EXISTS (SELECT 1 FROM app.meetings m WHERE m.meeting_id = "agent"."live_contexts"."meeting_id" AND m.workspace_id = "agent"."live_contexts"."workspace_id" AND app.current_identity_can_read_workspace(m.workspace_id))) WITH CHECK (EXISTS (SELECT 1 FROM app.meetings m WHERE m.meeting_id = "agent"."live_contexts"."meeting_id" AND m.workspace_id = "agent"."live_contexts"."workspace_id" AND app.current_identity_can_read_workspace(m.workspace_id)));--> statement-breakpoint
CREATE POLICY "agent_memory_job_owner" ON "agent"."memory_jobs" AS PERMISSIVE FOR ALL TO public USING ("agent"."memory_jobs"."user_id" = nullif(current_setting('app.user_id', true), '') AND EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."memory_jobs"."thread_id" AND owner_thread."resourceId" = nullif(current_setting('app.user_id', true), '')
)) WITH CHECK ("agent"."memory_jobs"."user_id" = nullif(current_setting('app.user_id', true), '') AND EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."memory_jobs"."thread_id" AND owner_thread."resourceId" = nullif(current_setting('app.user_id', true), '')
));--> statement-breakpoint
CREATE POLICY "agent_memory_job_dispatch" ON "agent"."memory_jobs" AS PERMISSIVE FOR SELECT TO public USING (current_setting('app.maintenance', true) = 'agent-memory');--> statement-breakpoint
CREATE POLICY "agent_observation_owner" ON "agent"."mastra_observational_memory" AS PERMISSIVE FOR ALL TO public USING ("agent"."mastra_observational_memory"."scope" = 'thread' AND "agent"."mastra_observational_memory"."resourceId" = nullif(current_setting('app.user_id', true), '') AND EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."mastra_observational_memory"."threadId" AND owner_thread."resourceId" = nullif(current_setting('app.user_id', true), '')
)) WITH CHECK ("agent"."mastra_observational_memory"."scope" = 'thread' AND "agent"."mastra_observational_memory"."resourceId" = nullif(current_setting('app.user_id', true), '') AND EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."mastra_observational_memory"."threadId" AND owner_thread."resourceId" = nullif(current_setting('app.user_id', true), '')
));