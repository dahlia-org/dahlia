CREATE TABLE `summary_jobs` (
	`id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`meeting_id` text NOT NULL,
	`owner_user_id` text NOT NULL,
	`method` text NOT NULL,
	`settings` text NOT NULL,
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
	CONSTRAINT "summary_job_status_check" CHECK("status" IN ('pending', 'processing', 'succeeded', 'failed'))
);
--> statement-breakpoint
ALTER TABLE `account_settings` ADD `summary_method` text DEFAULT 'transcript' NOT NULL;--> statement-breakpoint
ALTER TABLE `account_settings` ADD `transcript_summary` text DEFAULT '{"model":"gpt-5.4","reasoningEffort":"medium","detail":"detailed"}' NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX `summary_job_active_meeting_idx` ON `summary_jobs` (`meeting_id`) WHERE "summary_jobs"."status" IN ('pending', 'processing');--> statement-breakpoint
CREATE INDEX `summary_job_owner_created_idx` ON `summary_jobs` (`owner_user_id`,`created_at`);