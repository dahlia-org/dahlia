ALTER TABLE `transcript_segments` ADD `normalized_character_count` integer;--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_transcript_segments` (
	`encrypted_payload` text,
	`transcript_id` text NOT NULL,
	`segment_id` text NOT NULL,
	`started_at` integer NOT NULL,
	`ended_at` integer,
	`text` text NOT NULL,
	`created_at` integer,
	`audio_source` text,
	`speaker_label` text,
	`normalized_character_count` integer,
	CONSTRAINT `transcript_segments_pk` PRIMARY KEY(`transcript_id`, `segment_id`),
	CONSTRAINT `fk_transcript_segments_transcript_id_transcripts_id_fk` FOREIGN KEY (`transcript_id`) REFERENCES `transcripts`(`id`) ON DELETE CASCADE,
	CONSTRAINT "transcript_segment_normalized_character_count_check" CHECK("normalized_character_count" IS NULL OR "normalized_character_count" >= 0)
);
--> statement-breakpoint
INSERT INTO `__new_transcript_segments`(`encrypted_payload`, `transcript_id`, `segment_id`, `started_at`, `ended_at`, `text`, `created_at`, `audio_source`, `speaker_label`) SELECT `encrypted_payload`, `transcript_id`, `segment_id`, `started_at`, `ended_at`, `text`, `created_at`, `audio_source`, `speaker_label` FROM `transcript_segments`;--> statement-breakpoint
DROP TABLE `transcript_segments`;--> statement-breakpoint
ALTER TABLE `__new_transcript_segments` RENAME TO `transcript_segments`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
CREATE INDEX `transcript_segment_created_idx` ON `transcript_segments` (`transcript_id`,`created_at`);--> statement-breakpoint
CREATE INDEX `transcript_segment_start_id_idx` ON `transcript_segments` (`transcript_id`,`started_at`,`segment_id`);