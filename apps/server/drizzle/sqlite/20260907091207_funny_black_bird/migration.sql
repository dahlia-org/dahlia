CREATE TABLE `account_settings` (
	`user_id` text PRIMARY KEY,
	`output_language` text NOT NULL,
	`analysis_languages` text NOT NULL,
	CONSTRAINT `fk_account_settings_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `image_analysis_jobs` (
	`file_id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`owner_user_id` text NOT NULL,
	`model` text NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`attempts` integer DEFAULT 0 NOT NULL,
	`available_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`claimed_at` integer,
	`lease_expires_at` integer,
	`last_error_code` text,
	CONSTRAINT `fk_image_analysis_jobs_file_id_files_file_id_fk` FOREIGN KEY (`file_id`) REFERENCES `files`(`file_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_image_analysis_jobs_vault_id_vaults_vault_id_fk` FOREIGN KEY (`vault_id`) REFERENCES `vaults`(`vault_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_image_analysis_jobs_owner_user_id_user_id_fk` FOREIGN KEY (`owner_user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
	CONSTRAINT "image_analysis_job_status_check" CHECK("status" IN ('pending', 'processing', 'failed'))
);
--> statement-breakpoint
CREATE INDEX `image_analysis_job_claim_idx` ON `image_analysis_jobs` (`status`,`available_at`,`lease_expires_at`);