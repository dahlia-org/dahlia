ALTER TABLE `transcript_segments` RENAME COLUMN `start_time` TO `started_at`;--> statement-breakpoint
ALTER TABLE `transcript_segments` RENAME COLUMN `end_time` TO `ended_at`;--> statement-breakpoint
ALTER TABLE `transcripts` RENAME COLUMN `completed_at` TO `ended_at`;--> statement-breakpoint
ALTER TABLE `transcripts` RENAME COLUMN `saved_at` TO `created_at`;--> statement-breakpoint
ALTER TABLE `transcript_segments` ADD `created_at` integer;--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_transcripts` (
	`id` text PRIMARY KEY,
	`meeting_id` text NOT NULL,
	`version` integer NOT NULL,
	`sync_revision` integer NOT NULL,
	`started_at` integer,
	`ended_at` integer,
	`created_at` integer NOT NULL,
	`metadata` text,
	CONSTRAINT `fk_transcripts_meeting_id_meetings_meeting_id_fk` FOREIGN KEY (`meeting_id`) REFERENCES `meetings`(`meeting_id`) ON DELETE CASCADE,
	CONSTRAINT `transcript_meeting_version_unique` UNIQUE(`meeting_id`,`version`),
	CONSTRAINT "transcript_version_check" CHECK("version" >= 1)
);
--> statement-breakpoint
INSERT INTO `__new_transcripts`(`id`, `meeting_id`, `version`, `sync_revision`, `started_at`, `ended_at`, `created_at`, `metadata`) SELECT `id`, `meeting_id`, `version`, `sync_revision`, `started_at`, `ended_at`, `created_at`, `metadata` FROM `transcripts`;--> statement-breakpoint
DROP TABLE `transcripts`;--> statement-breakpoint
ALTER TABLE `__new_transcripts` RENAME TO `transcripts`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
CREATE INDEX `transcript_segment_created_idx` ON `transcript_segments` (`transcript_id`,`created_at`);--> statement-breakpoint
ALTER TABLE `transcript_segments` DROP COLUMN `is_confirmed`;