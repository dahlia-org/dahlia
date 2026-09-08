ALTER TABLE `image_analysis_jobs` RENAME TO `jobs_image_analysis`;--> statement-breakpoint
ALTER TABLE `search_index_jobs` RENAME TO `jobs_search_index`;--> statement-breakpoint
ALTER TABLE `storage_delete_jobs` RENAME TO `jobs_storage_delete`;--> statement-breakpoint
ALTER TABLE `summary_jobs` RENAME TO `jobs_summary`;--> statement-breakpoint
ALTER TABLE `account_settings` RENAME COLUMN `change_version` TO `revision`;--> statement-breakpoint
ALTER TABLE `projects` ADD `icon` text;--> statement-breakpoint
ALTER TABLE `projects` ADD `color` text;--> statement-breakpoint
ALTER TABLE `vaults` ADD `icon` text;--> statement-breakpoint
ALTER TABLE `vaults` ADD `color` text;--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_recordings` (
	`session_id` text PRIMARY KEY,
	`meeting_id` text NOT NULL,
	`number` integer NOT NULL,
	`started_at` integer NOT NULL,
	`ended_at` integer NOT NULL,
	`audio` text NOT NULL,
	`revision` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	CONSTRAINT `fk_recordings_meeting_id_meetings_meeting_id_fk` FOREIGN KEY (`meeting_id`) REFERENCES `meetings`(`meeting_id`) ON DELETE CASCADE,
	CONSTRAINT `recordings_meeting_number_unique` UNIQUE(`meeting_id`,`number`),
	CONSTRAINT "recordings_number_check" CHECK("number" > 0)
);
--> statement-breakpoint
INSERT INTO `__new_recordings`(`session_id`, `meeting_id`, `number`, `started_at`, `ended_at`, `audio`, `revision`, `created_at`, `updated_at`) SELECT `session_id`, `meeting_id`, `number`, `started_at`, `ended_at`, `audio`, `revision`, `created_at`, `updated_at` FROM `recordings`;--> statement-breakpoint
DROP TABLE `recordings`;--> statement-breakpoint
ALTER TABLE `__new_recordings` RENAME TO `recordings`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
DROP INDEX IF EXISTS `recordings_vault_session_idx`;--> statement-breakpoint
CREATE INDEX `recordings_meeting_session_idx` ON `recordings` (`meeting_id`,`session_id`);