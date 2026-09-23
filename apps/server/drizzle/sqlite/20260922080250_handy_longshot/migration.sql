CREATE TABLE `memory_source_jobs` (
	`workspace_id` text NOT NULL,
	`document_id` text NOT NULL,
	`kind` text NOT NULL,
	`source_id` text NOT NULL,
	`generation` integer DEFAULT 1 NOT NULL,
	`operation` text,
	CONSTRAINT `memory_source_jobs_pk` PRIMARY KEY(`workspace_id`, `document_id`)
);

--> statement-breakpoint
CREATE TABLE `memory_documents` (
	`workspace_id` text NOT NULL,
	`document_id` text NOT NULL,
	`source` text NOT NULL,
	`content_hash` text NOT NULL,
	`generation` integer NOT NULL,
	CONSTRAINT `memory_documents_pk` PRIMARY KEY(`workspace_id`, `document_id`)
);
--> statement-breakpoint
CREATE TABLE `shared_memories` (
	`id` text PRIMARY KEY,
	`workspace_id` text NOT NULL,
	`created_by` text NOT NULL,
	`content` text NOT NULL,
	`revision` integer DEFAULT 1 NOT NULL,
	`updated_at` integer NOT NULL,
	CONSTRAINT `fk_shared_memories_workspace_id_workspaces_workspace_id_fk` FOREIGN KEY (`workspace_id`) REFERENCES `workspaces`(`workspace_id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `workspace_memory_state` (
	`workspace_id` text PRIMARY KEY,
	`enabled` integer DEFAULT false NOT NULL,
	`requested_by` text NOT NULL,
	`bank_id` text NOT NULL,
	`generation` integer DEFAULT 1 NOT NULL,
	`indexed_generation` integer DEFAULT 0 NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`purge` integer DEFAULT false NOT NULL,
	`reconcile` integer DEFAULT true NOT NULL,
	`progress` text,
	`lease` text,
	`lease_until` integer,
	`available_at` integer NOT NULL,
	`attempts` integer DEFAULT 0 NOT NULL,
	`error_code` text
);
--> statement-breakpoint
CREATE INDEX `shared_memories_workspace_idx` ON `shared_memories` (`workspace_id`);--> statement-breakpoint
CREATE INDEX `workspace_memory_due_idx` ON `workspace_memory_state` (`available_at`);