CREATE TABLE "search"."personal_memory_chunks" (
	"memory_id" uuid,
	"chunk_no" integer,
	"user_id" uuid NOT NULL,
	"chunk_text" text NOT NULL,
	"search_text" text DEFAULT '' NOT NULL,
	"search_vector" tsvector,
	"analyzer" text NOT NULL,
	"content_hash" text NOT NULL,
	"embedding" real[],
	"embedding_model" text,
	CONSTRAINT "personal_memory_chunks_pkey" PRIMARY KEY("memory_id","chunk_no"),
	CONSTRAINT "personal_memory_chunks_embedding_check" CHECK ("embedding" IS NULL OR cardinality("embedding") BETWEEN 32 AND 1024)
);
--> statement-breakpoint
ALTER TABLE "search"."personal_memory_chunks" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "search"."shared_memory_chunks" (
	"memory_id" uuid,
	"chunk_no" integer,
	"workspace_id" uuid NOT NULL,
	"chunk_text" text NOT NULL,
	"search_text" text DEFAULT '' NOT NULL,
	"search_vector" tsvector,
	"analyzer" text NOT NULL,
	"content_hash" text NOT NULL,
	"embedding" real[],
	"embedding_model" text,
	CONSTRAINT "shared_memory_chunks_pkey" PRIMARY KEY("memory_id","chunk_no"),
	CONSTRAINT "shared_memory_chunks_embedding_check" CHECK ("embedding" IS NULL OR cardinality("embedding") BETWEEN 32 AND 1024)
);
--> statement-breakpoint
ALTER TABLE "search"."shared_memory_chunks" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE INDEX "personal_memory_chunks_user_idx" ON "search"."personal_memory_chunks" ("user_id");--> statement-breakpoint
CREATE INDEX "shared_memory_chunks_workspace_idx" ON "search"."shared_memory_chunks" ("workspace_id");--> statement-breakpoint
ALTER TABLE "search"."personal_memory_chunks" ADD CONSTRAINT "personal_memory_chunks_memory_id_personal_memories_id_fkey" FOREIGN KEY ("memory_id") REFERENCES "app"."personal_memories"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "search"."shared_memory_chunks" ADD CONSTRAINT "shared_memory_chunks_memory_id_shared_memories_id_fkey" FOREIGN KEY ("memory_id") REFERENCES "app"."shared_memories"("id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "personal_memory_chunk_owner" ON "search"."personal_memory_chunks" AS PERMISSIVE FOR ALL TO public USING ("search"."personal_memory_chunks"."user_id" = nullif(current_setting('app.user_id', true), '')::uuid) WITH CHECK ("search"."personal_memory_chunks"."user_id" = nullif(current_setting('app.user_id', true), '')::uuid);--> statement-breakpoint
CREATE POLICY "shared_memory_chunk_read" ON "search"."shared_memory_chunks" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_workspace"("search"."shared_memory_chunks"."workspace_id") OR (current_setting('app.maintenance', true) = 'search' AND "search"."shared_memory_chunks"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));--> statement-breakpoint
CREATE POLICY "shared_memory_chunk_write" ON "search"."shared_memory_chunks" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_can_write_workspace"("search"."shared_memory_chunks"."workspace_id") OR (current_setting('app.maintenance', true) = 'search' AND "search"."shared_memory_chunks"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid)) WITH CHECK ("app"."current_identity_can_write_workspace"("search"."shared_memory_chunks"."workspace_id") OR (current_setting('app.maintenance', true) = 'search' AND "search"."shared_memory_chunks"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));--> statement-breakpoint
ALTER POLICY "shared_memory_read" ON "app"."shared_memories" TO public USING ("app"."current_identity_can_read_workspace"("app"."shared_memories"."workspace_id") OR (current_setting('app.maintenance', true) = 'search' AND "app"."shared_memories"."workspace_id" = nullif(current_setting('app.maintenance_workspace_id', true), '')::uuid));