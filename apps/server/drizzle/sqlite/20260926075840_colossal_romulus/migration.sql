CREATE TABLE `screenshot_assessments` (
	`file_id` text PRIMARY KEY,
	`workspace_id` text NOT NULL,
	`model` text NOT NULL,
	`informative` integer NOT NULL,
	`reason` text,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT `fk_screenshot_assessments_file_id_files_file_id_fk` FOREIGN KEY (`file_id`) REFERENCES `files`(`file_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_screenshot_assessments_workspace_id_workspaces_workspace_id_fk` FOREIGN KEY (`workspace_id`) REFERENCES `workspaces`(`workspace_id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE INDEX `screenshot_assessments_workspace_idx` ON `screenshot_assessments` (`workspace_id`);