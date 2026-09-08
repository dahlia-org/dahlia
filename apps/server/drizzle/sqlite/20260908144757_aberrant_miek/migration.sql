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
-- Existing bodies become version 1. Reuse the globally unique meeting UUID for this initial parent.
-- A positive revision also preserves a previously published empty transcript; generation details are unknown.
INSERT INTO `transcripts` (`id`, `vault_id`, `meeting_id`, `version`, `sync_revision`, `status`, `saved_at`)
SELECT m.meeting_id, m.vault_id, m.meeting_id, 1, m.transcript_revision, 'interrupted', unixepoch() * 1000
FROM meetings m WHERE m.transcript_revision > 0 OR EXISTS (
  SELECT 1 FROM transcript_segments s WHERE s.vault_id = m.vault_id AND s.meeting_id = m.meeting_id
);--> statement-breakpoint
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
INSERT INTO `__new_transcript_segments`(`transcript_id`, `segment_id`, `start_time`, `end_time`, `text`, `is_confirmed`, `audio_source`, `speaker_label`)
SELECT t.id, s.segment_id, s.start_time, s.end_time, s.text, s.is_confirmed, s.audio_source, s.speaker_label
FROM transcript_segments s JOIN transcripts t ON t.vault_id = s.vault_id AND t.meeting_id = s.meeting_id;--> statement-breakpoint
DROP TABLE `transcript_segments`;--> statement-breakpoint
ALTER TABLE `__new_transcript_segments` RENAME TO `transcript_segments`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
DROP INDEX IF EXISTS `synced_transcript_vault_meeting_start_id_idx`;--> statement-breakpoint
CREATE INDEX `transcript_segment_start_id_idx` ON `transcript_segments` (`transcript_id`,`start_time`,`segment_id`);
