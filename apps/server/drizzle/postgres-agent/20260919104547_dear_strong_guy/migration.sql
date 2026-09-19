CREATE SCHEMA "agent";
--> statement-breakpoint
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
CREATE INDEX "agent_mastra_messages_thread_id_createdat_idx" ON "agent"."mastra_messages" ("thread_id","createdAt" DESC NULLS LAST);--> statement-breakpoint
CREATE INDEX "agent_mastra_threads_resourceid_createdat_idx" ON "agent"."mastra_threads" ("resourceId","createdAt" DESC NULLS LAST);--> statement-breakpoint
ALTER TABLE "agent"."ai_thread_runs" ADD CONSTRAINT "ai_thread_runs_thread_id_mastra_threads_id_fkey" FOREIGN KEY ("thread_id") REFERENCES "agent"."mastra_threads"("id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "agent_message_owner" ON "agent"."mastra_messages" AS PERMISSIVE FOR ALL TO public USING (EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."mastra_messages"."thread_id" AND owner_thread."resourceId" = nullif(current_setting('app.resource_id', true), '')
)) WITH CHECK (EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."mastra_messages"."thread_id" AND owner_thread."resourceId" = nullif(current_setting('app.resource_id', true), '')
));--> statement-breakpoint
CREATE POLICY "agent_resource_owner" ON "agent"."mastra_resources" AS PERMISSIVE FOR ALL TO public USING ("agent"."mastra_resources"."id" = nullif(current_setting('app.resource_id', true), '')) WITH CHECK ("agent"."mastra_resources"."id" = nullif(current_setting('app.resource_id', true), ''));--> statement-breakpoint
CREATE POLICY "agent_thread_owner" ON "agent"."mastra_threads" AS PERMISSIVE FOR ALL TO public USING ("agent"."mastra_threads"."resourceId" = nullif(current_setting('app.resource_id', true), '')) WITH CHECK ("agent"."mastra_threads"."resourceId" = nullif(current_setting('app.resource_id', true), ''));--> statement-breakpoint
CREATE POLICY "ai_thread_run_owner" ON "agent"."ai_thread_runs" AS PERMISSIVE FOR ALL TO public USING ("agent"."ai_thread_runs"."resource_id" = nullif(current_setting('app.resource_id', true), '')) WITH CHECK ("agent"."ai_thread_runs"."resource_id" = nullif(current_setting('app.resource_id', true), ''));