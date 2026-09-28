CREATE TABLE `knowledge_pages` (
	`workspace_id` text NOT NULL,
	`id` text NOT NULL,
	`project_id` text,
	`generation` integer DEFAULT 0 NOT NULL,
	`snapshot` text,
	`status` text DEFAULT 'generating' NOT NULL,
	`request_version` integer DEFAULT 0 NOT NULL,
	`completed_version` integer DEFAULT 0 NOT NULL,
	`operation` text,
	CONSTRAINT `knowledge_pages_pk` PRIMARY KEY(`workspace_id`, `id`),
	CONSTRAINT `fk_knowledge_pages_workspace_id_workspaces_workspace_id_fk` FOREIGN KEY (`workspace_id`) REFERENCES `workspaces`(`workspace_id`) ON DELETE CASCADE
);
