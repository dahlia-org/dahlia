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
-- Rebuild children against the new parent before dropping the old one. Inside a transaction,
-- foreign_keys=OFF has no effect, and dropping transcripts would otherwise cascade-delete the body.
CREATE TABLE `__new_transcript_segments` (
	`transcript_id` text NOT NULL,
	`segment_id` text NOT NULL,
	`started_at` integer NOT NULL,
	`ended_at` integer,
	`text` text NOT NULL,
	`audio_source` text,
	`speaker_label` text,
	`created_at` integer,
	CONSTRAINT `transcript_segments_pk` PRIMARY KEY(`transcript_id`, `segment_id`),
	CONSTRAINT `fk_transcript_segments_transcript_id_transcripts_id_fk` FOREIGN KEY (`transcript_id`) REFERENCES `__new_transcripts`(`id`) ON DELETE CASCADE
);--> statement-breakpoint
INSERT INTO `__new_transcript_segments` (`transcript_id`, `segment_id`, `started_at`, `ended_at`, `text`, `audio_source`, `speaker_label`, `created_at`)
SELECT `transcript_id`, `segment_id`, `started_at`, `ended_at`, `text`, `audio_source`, `speaker_label`, `created_at` FROM `transcript_segments`;--> statement-breakpoint
DROP TABLE `transcript_segments`;--> statement-breakpoint
DROP TABLE `transcripts`;--> statement-breakpoint
ALTER TABLE `__new_transcripts` RENAME TO `transcripts`;--> statement-breakpoint
ALTER TABLE `__new_transcript_segments` RENAME TO `transcript_segments`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
CREATE INDEX `transcript_segment_start_id_idx` ON `transcript_segments` (`transcript_id`,`started_at`,`segment_id`);--> statement-breakpoint
CREATE INDEX `transcript_segment_created_idx` ON `transcript_segments` (`transcript_id`,`created_at`);--> statement-breakpoint
