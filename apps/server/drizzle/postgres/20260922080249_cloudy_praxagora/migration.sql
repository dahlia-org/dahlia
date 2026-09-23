CREATE TABLE "jobs"."memory_source_jobs" (
	"workspace_id" uuid,
	"document_id" text,
	"kind" text NOT NULL,
	"source_id" uuid NOT NULL,
	"generation" integer DEFAULT 1 NOT NULL,
	"operation" jsonb,
	CONSTRAINT "memory_source_jobs_pkey" PRIMARY KEY("workspace_id","document_id")
);

--> statement-breakpoint
CREATE TABLE "jobs"."memory_documents" (
	"workspace_id" uuid,
	"document_id" text,
	"source" jsonb NOT NULL,
	"content_hash" text NOT NULL,
	"generation" integer NOT NULL,
	CONSTRAINT "memory_documents_pkey" PRIMARY KEY("workspace_id","document_id")
);
--> statement-breakpoint
CREATE TABLE "app"."shared_memories" (
	"id" uuid PRIMARY KEY,
	"workspace_id" uuid NOT NULL,
	"created_by" uuid NOT NULL,
	"content" text NOT NULL,
	"revision" integer DEFAULT 1 NOT NULL,
	"updated_at" timestamp NOT NULL
);
--> statement-breakpoint
ALTER TABLE "app"."shared_memories" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "jobs"."workspace_memory_state" (
	"workspace_id" uuid PRIMARY KEY,
	"enabled" boolean DEFAULT false NOT NULL,
	"requested_by" uuid NOT NULL,
	"bank_id" text NOT NULL,
	"generation" integer DEFAULT 1 NOT NULL,
	"indexed_generation" integer DEFAULT 0 NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"purge" boolean DEFAULT false NOT NULL,
	"reconcile" boolean DEFAULT true NOT NULL,
	"progress" jsonb,
	"lease" uuid,
	"lease_until" timestamp,
	"available_at" timestamp NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"error_code" text
);
--> statement-breakpoint
CREATE INDEX "shared_memories_workspace_idx" ON "app"."shared_memories" ("workspace_id");--> statement-breakpoint
CREATE INDEX "workspace_memory_due_idx" ON "jobs"."workspace_memory_state" ("available_at");--> statement-breakpoint
ALTER TABLE "app"."shared_memories" ADD CONSTRAINT "shared_memories_workspace_id_workspaces_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "app"."workspaces"("workspace_id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "shared_memory_read" ON "app"."shared_memories" AS PERMISSIVE FOR SELECT TO public USING ("app"."current_identity_can_read_workspace"("app"."shared_memories"."workspace_id"));--> statement-breakpoint
CREATE POLICY "shared_memory_write" ON "app"."shared_memories" AS PERMISSIVE FOR ALL TO public USING ("app"."current_identity_can_write_workspace"("app"."shared_memories"."workspace_id")) WITH CHECK ("app"."current_identity_can_write_workspace"("app"."shared_memories"."workspace_id"));