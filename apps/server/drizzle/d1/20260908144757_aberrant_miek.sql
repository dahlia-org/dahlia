CREATE TABLE `transcripts` (
	`id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`meeting_id` text NOT NULL,
	`version` integer NOT NULL,
	`sync_revision` integer NOT NULL,
	`status` text NOT NULL,
	`started_at` integer,
	`completed_at` integer,
	`saved_at` integer NOT NULL,
	`metadata` text,
	CONSTRAINT `fk_transcripts_vault_id_meeting_id_meetings_vault_id_meeting_id_fk` FOREIGN KEY (`vault_id`,`meeting_id`) REFERENCES `meetings`(`vault_id`,`meeting_id`) ON DELETE CASCADE,
	CONSTRAINT `transcript_meeting_version_unique` UNIQUE(`vault_id`,`meeting_id`,`version`),
	CONSTRAINT "transcript_version_check" CHECK("version" >= 1),
	CONSTRAINT "transcript_status_check" CHECK("status" IN ('live', 'completed', 'interrupted'))
);
--> statement-breakpoint
ALTER TABLE `transcript_segments` ADD `transcript_id` text NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE;--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_transcript_segments` (
	`transcript_id` text NOT NULL,
	`segment_id` text NOT NULL,
	`start_time` integer NOT NULL,
	`end_time` integer,
	`text` text NOT NULL,
	`is_confirmed` integer NOT NULL,
	`audio_source` text,
	`speaker_label` text,
	CONSTRAINT `transcript_segments_pk` PRIMARY KEY(`transcript_id`, `segment_id`),
	CONSTRAINT `fk_transcript_segments_transcript_id_transcripts_id_fk` FOREIGN KEY (`transcript_id`) REFERENCES `transcripts`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
INSERT INTO `__new_transcript_segments`(`segment_id`, `start_time`, `end_time`, `text`, `is_confirmed`, `audio_source`, `speaker_label`) SELECT `segment_id`, `start_time`, `end_time`, `text`, `is_confirmed`, `audio_source`, `speaker_label` FROM `transcript_segments`;--> statement-breakpoint
DROP TABLE `transcript_segments`;--> statement-breakpoint
ALTER TABLE `__new_transcript_segments` RENAME TO `transcript_segments`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
DROP INDEX IF EXISTS `synced_transcript_vault_meeting_start_id_idx`;--> statement-breakpoint
CREATE INDEX `transcript_segment_start_id_idx` ON `transcript_segments` (`transcript_id`,`start_time`,`segment_id`);