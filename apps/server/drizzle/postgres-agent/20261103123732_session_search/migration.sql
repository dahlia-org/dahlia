CREATE TABLE "agent"."session_search_chunks" (
	"message_id" text,
	"chunk_no" integer,
	"thread_id" text NOT NULL,
	"user_id" text NOT NULL,
	"workspace_id" uuid NOT NULL,
	"role" text NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"chunk_text" text NOT NULL,
	"search_text" text DEFAULT '' NOT NULL,
	"search_vector" tsvector,
	"analyzer" text NOT NULL,
	"content_hash" text NOT NULL,
	"embedding" real[],
	"embedding_model" text,
	CONSTRAINT "session_search_chunks_pkey" PRIMARY KEY("message_id","chunk_no"),
	CONSTRAINT "agent_session_search_chunks_embedding_check" CHECK ("embedding" IS NULL OR cardinality("embedding") BETWEEN 32 AND 1024)
);
--> statement-breakpoint
ALTER TABLE "agent"."session_search_chunks" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE INDEX "agent_session_search_chunks_user_idx" ON "agent"."session_search_chunks" ("user_id","workspace_id");--> statement-breakpoint
CREATE INDEX "agent_session_search_chunks_thread_idx" ON "agent"."session_search_chunks" ("thread_id");--> statement-breakpoint
ALTER TABLE "agent"."session_search_chunks" ADD CONSTRAINT "session_search_chunks_message_id_mastra_messages_id_fkey" FOREIGN KEY ("message_id") REFERENCES "agent"."mastra_messages"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "agent"."session_search_chunks" ADD CONSTRAINT "session_search_chunks_thread_id_mastra_threads_id_fkey" FOREIGN KEY ("thread_id") REFERENCES "agent"."mastra_threads"("id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "agent_session_search_owner" ON "agent"."session_search_chunks" AS PERMISSIVE FOR ALL TO public USING ("agent"."session_search_chunks"."user_id" = nullif(current_setting('app.user_id', true), '') AND EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."session_search_chunks"."thread_id" AND owner_thread."resourceId" = nullif(current_setting('app.user_id', true), '')
)) WITH CHECK ("agent"."session_search_chunks"."user_id" = nullif(current_setting('app.user_id', true), '') AND EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."session_search_chunks"."thread_id" AND owner_thread."resourceId" = nullif(current_setting('app.user_id', true), '')
));