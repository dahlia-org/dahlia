CREATE TABLE `__new_workspaces` (
	`encryption` text DEFAULT 'none' NOT NULL,
	`encrypted_payload` text,
	`workspace_id` text PRIMARY KEY,
	`organization_id` text NOT NULL,
	`created_by` text NOT NULL,
	`generation_settings` text DEFAULT '{"outputLanguage":"ja","processing":{"location":"local","remote":{"workflow":"combined"}},"summary":{"style":"detailed"},"local":{"model":"gpt-5.6-luna","reasoningEffort":"high"},"automaticProcessing":true}' NOT NULL,
	`name` text NOT NULL,
	`icon` text,
	`color` text,
	`revision` integer DEFAULT 1 NOT NULL,
	`meeting_deletion_grace_days` integer DEFAULT 7 NOT NULL,
	`deleting_at` integer,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT `fk_workspaces_organization_id_organization_id_fk` FOREIGN KEY (`organization_id`) REFERENCES `organization`(`id`) ON DELETE RESTRICT,
	CONSTRAINT "workspace_meeting_deletion_grace_check" CHECK("meeting_deletion_grace_days" BETWEEN 1 AND 90)
);
--> statement-breakpoint
INSERT INTO `__new_workspaces`(`encryption`, `encrypted_payload`, `workspace_id`, `organization_id`, `created_by`, `generation_settings`, `name`, `icon`, `color`, `revision`, `meeting_deletion_grace_days`, `deleting_at`, `created_at`, `updated_at`) SELECT `encryption`, `encrypted_payload`, `workspace_id`, `organization_id`, `created_by`, `generation_settings`, `name`, `icon`, `color`, `revision`, `meeting_deletion_grace_days`, `deleting_at`, `created_at`, `updated_at` FROM `workspaces`;--> statement-breakpoint
DROP TABLE `workspaces`;--> statement-breakpoint
ALTER TABLE `__new_workspaces` RENAME TO `workspaces`;--> statement-breakpoint
UPDATE `workspaces`
SET `generation_settings` = json_remove(`generation_settings`, '$.processing.remote.transcriptionModel', '$.transcription')
WHERE json_type(`generation_settings`, '$.processing.remote.transcriptionModel') IS NOT NULL
   OR json_type(`generation_settings`, '$.transcription') IS NOT NULL;
