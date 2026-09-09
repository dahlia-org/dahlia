ALTER TABLE `jobs_summary` ADD `input` text;--> statement-breakpoint
ALTER TABLE `jobs_summary` ADD `stage` text;--> statement-breakpoint
ALTER TABLE `jobs_summary` ADD `transcript_revision` integer;--> statement-breakpoint
ALTER TABLE `jobs_summary` ADD `transcript_result` text;--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_account_settings` (
	`user_id` text PRIMARY KEY,
	`summary` text DEFAULT '{"method":"transcript","detail":"high","methodSettings":{"transcript":{"model":"gpt-5.4","reasoningEffort":"medium"},"audio":{"model":"gemini-3-8-flash","reasoningEffort":"medium"}}}' NOT NULL,
	`revision` integer DEFAULT 1 NOT NULL,
	`output_language` text NOT NULL,
	`analysis_languages` text NOT NULL,
	CONSTRAINT `fk_account_settings_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
INSERT INTO `__new_account_settings`(`user_id`, `summary`, `revision`, `output_language`, `analysis_languages`) SELECT `user_id`, `summary`, `revision`, `output_language`, `analysis_languages` FROM `account_settings`;--> statement-breakpoint
DROP TABLE `account_settings`;--> statement-breakpoint
ALTER TABLE `__new_account_settings` RENAME TO `account_settings`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_jobs_summary` (
	`id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`meeting_id` text NOT NULL,
	`owner_user_id` text NOT NULL,
	`method` text NOT NULL,
	`settings` text NOT NULL,
	`input` text,
	`stage` text,
	`transcript_revision` integer,
	`transcript_result` text,
	`output_language` text NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`attempts` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`available_at` integer NOT NULL,
	`claimed_at` integer,
	`lease_expires_at` integer,
	`last_error_code` text,
	`summary_revision` integer NOT NULL,
	`input_version` text NOT NULL,
	`request_hash` text NOT NULL,
	CONSTRAINT `fk_summary_jobs_vault_id_vaults_vault_id_fk` FOREIGN KEY (`vault_id`) REFERENCES `vaults`(`vault_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_summary_jobs_meeting_id_meetings_meeting_id_fk` FOREIGN KEY (`meeting_id`) REFERENCES `meetings`(`meeting_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_summary_jobs_owner_user_id_user_id_fk` FOREIGN KEY (`owner_user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
	CONSTRAINT "summary_job_status_check" CHECK("status" IN ('pending', 'processing', 'succeeded', 'failed', 'cancelled'))
);
--> statement-breakpoint
INSERT INTO `__new_jobs_summary`(`id`, `vault_id`, `meeting_id`, `owner_user_id`, `method`, `settings`, `output_language`, `status`, `attempts`, `created_at`, `available_at`, `claimed_at`, `lease_expires_at`, `last_error_code`, `summary_revision`, `input_version`, `request_hash`) SELECT `id`, `vault_id`, `meeting_id`, `owner_user_id`, `method`, `settings`, `output_language`, `status`, `attempts`, `created_at`, `available_at`, `claimed_at`, `lease_expires_at`, `last_error_code`, `summary_revision`, `input_version`, `request_hash` FROM `jobs_summary`;--> statement-breakpoint
DROP TABLE `jobs_summary`;--> statement-breakpoint
ALTER TABLE `__new_jobs_summary` RENAME TO `jobs_summary`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
CREATE UNIQUE INDEX `summary_job_active_meeting_idx` ON `jobs_summary` (`meeting_id`) WHERE "jobs_summary"."status" IN ('pending', 'processing');--> statement-breakpoint
CREATE INDEX `summary_job_owner_created_idx` ON `jobs_summary` (`owner_user_id`,`created_at`);