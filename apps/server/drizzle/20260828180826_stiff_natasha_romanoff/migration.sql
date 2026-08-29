CREATE TABLE "dahlia"."artifact" (
	"id" text PRIMARY KEY,
	"owner_workspace_id" text NOT NULL,
	"content_type" text NOT NULL,
	"visibility" text DEFAULT 'private' NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "artifact_visibility_check" CHECK ("visibility" IN ('private', 'public'))
);
