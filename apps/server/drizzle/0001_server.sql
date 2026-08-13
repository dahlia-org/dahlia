CREATE TABLE "model_alias" (
	"alias" text PRIMARY KEY NOT NULL,
	"upstream_model" text NOT NULL,
	"display_name" text,
	"enabled" boolean DEFAULT true NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "platform_admin" (
	"email" text PRIMARY KEY NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL
);
